# `System.IO.Uring`

Idris2 bindings to Linux's `io_uring` async I/O interface, via
[liburing](https://github.com/axboe/liburing) rather than the raw
`io_uring_setup`/`io_uring_enter` syscalls directly. `idris2-rc-cg`'s
own `rc2` backend only.

## Why liburing, not the raw syscalls

`io_uring_setup`/`io_uring_enter`/`io_uring_register` themselves are a
real but low-level ABI -- the caller owns mmap'ing the submission/
completion ring buffers, computing memory-ordering-correct producer/
consumer index updates by hand, and tracking `IORING_FEAT_*` flags to
know which shortcuts the running kernel actually supports. liburing is
the reference C implementation of exactly that bookkeeping, already
depended on transitively by most real-world io_uring users (`glib`,
`.NET`, Rust's `tokio-uring`, ...). Reimplementing the ring protocol
directly on top of the syscalls, in a from-scratch Idris shim, would
buy nothing this package's own scope needs and would need to be kept
correct against every future kernel `IORING_FEAT_*` addition by hand.

## Why most of this binds straight onto `liburing.h`, no shim needed

Confirmed empirically (`nix-shell -p liburing gcc --run 'gcc test.c
-luring'`, a real ring init/submit/wait round-trip) before writing any
of this package, and again via the actual `%foreign` bindings below:
almost the entirety of liburing's own convenience API
(`io_uring_get_sqe`, every `io_uring_prep_*`, `io_uring_sqe_set_data64`,
`io_uring_submit(_and_wait)`, `io_uring_{wait,peek}_cqe`,
`io_uring_cqe_get_data64`) is declared `static inline` directly in
`<liburing.h>`, with no linkable symbol in `liburing.a`/`.so` at all.
`Compiler.RC2.Emit` already `#include`s every `%foreign` declaration's
own header directly into the *consumer's* generated `.c` file (see
that module's own `emitHeaderFiles`-adjacent doc comment) -- not a
separate translation unit the way a genuine cross-library call would
need -- so a `static inline` function's body is simply visible, and
the C compiler inlines the call right there. No shim wrapper, no
`.o`/`.a` involvement, for any of these.

This is the same reasoning `libs/notcurses/doc/notcurses.md` works
through in detail for `notcurses.h`'s own `static inline` functions
*before* concluding a shim is still needed there -- the difference is
what notcurses' shim ended up needing one *for*: mostly struct-by-
pointer construction (`notcurses_options`, `ncplane_options`) and
private-macro-derived constants (`NCKEY_*`). `liburing.h`'s own prep
functions take their arguments as plain scalars (`int fd`, `void *buf`,
`unsigned len`, ...) directly on the SQE, with no analogous
options-struct step -- so this package's shim ends up much smaller,
needed only for what's below.

## Why a (small) shim still exists

1. **`io_uring_queue_init(entries, struct io_uring *ring, flags)`**
   wants the *caller* to already own the storage for a non-trivial-size
   `struct io_uring` (the mmap'd ring bookkeeping struct itself) --
   Idris has nowhere to put that on its own. `idris2rc2_iouring_queue_init`
   -- a real compiled function, `iouring_util.c` -- heap-allocates one
   and returns the pointer (`NULL` on failure, same `Maybe`-shaped
   contract as `libs/notcurses`'s own `init`); paired with
   `idris2rc2_iouring_queue_exit` to unregister the ring from the
   kernel and free that allocation (`System.FFI.free`, idris2-src's
   own base library -- `idris2rc2_iouring_make_sockaddr`'s own return
   value, a bare `malloc`'d block with nothing else to unregister,
   frees the same way, straight from `System.IO.Uring`'s own `exit`;
   no shim function of its own for that half).
2. **`io_uring_wait_cqe`/`io_uring_peek_cqe`** write their result
   through a `struct io_uring_cqe **` out-parameter -- the same
   "nowhere to put the address of a local pointer" problem `%foreign`
   has no answer for. Since a genuinely successful call never yields a
   NULL cqe, `idris2rc2_iouring_wait_cqe`/`_peek_cqe` collapse
   `(return code, out-param)` into a single "`NULL` means failed/not
   ready yet" return -- both still `static inline` in this package's
   own header, no `.o` involved, just restructuring liburing's own
   already-inline bodies.
3. **`io_uring_prep_accept`'s `addr`/`addrlen` out-parameters** (the
   peer's address) have the same shape of problem;
   `idris2rc2_iouring_prep_accept_simple` always passes `NULL`/`NULL` --
   this package doesn't expose the peer address at all (a caller who
   needs it can `getpeername` the resulting fd afterward).
4. **`io_uring_prep_connect`'s `addr` parameter** needs a real
   `struct sockaddr` built from a host/port pair -- genuine work
   (`getaddrinfo`, resolving a hostname or numeric address, IPv4 or
   IPv6), not something a bare inline wrapper can do.
   `idris2rc2_iouring_make_sockaddr` is a real compiled function too
   (`iouring_util.c`, alongside `queue_init`/`_exit` above -- the only
   two genuinely non-inline pieces of this whole shim);
   `idris2rc2_iouring_sockaddr_family`/`_len` (both
   `static inline`, reading `sockaddr`'s own `sa_family` field) let the
   Idris side compute the `addrlen` `io_uring_prep_connect` needs
   without a second out-parameter.
5. **`io_uring_cqe`'s own `res`/`user_data`/`flags` fields** have no
   dedicated accessor of their own in liburing.h (only
   `io_uring_cqe_get_data64`, for `user_data` specifically, already
   used directly) -- `idris2rc2_iouring_cqe_res`/`_flags` are one-line
   `static inline` field reads, same shape as `res`.

None of the above needed to be resolved through a genuine
out-of-line-call shim (`libs/notcurses`'s own `idris2rc2_nc_get_blocking`/
`_get_nonblock`, which share one file-scope `static` cache and would
silently break if duplicated per translation unit) -- every function
here is either a pure field read/constant, or (the sockaddr builder)
has no shared mutable state to worry about, so `static inline` in this
package's own header is safe and avoids the `.o`/`.a` link step
entirely for everything except `queue_init`/`_exit` and the sockaddr
builder.

## Why `iouring_util.h` still only needs a plain `#include <liburing.h>`

Unlike `notcurses.h` (`libs/notcurses/doc/notcurses.md`'s own "Why
`nc_util.h` never includes the real header" section), `liburing.h` was
not found to need any glibc feature-test macro a consumer wouldn't
already have -- confirmed by this package's own `tests/verify.sh`
actually compiling and linking a program against it with no extra
`IDRIS2_CFLAGS`. If a future liburing version changes that, the fix is
the same one documented there: stop giving consumers the real header,
hand-declare only what's needed, and confine the full `#include` to
this shim's own `.c` file.

## Design choices

- **`URing.pending`/`pendingAddrs` keep every in-flight buffer/sockaddr
  alive, for the ring's own whole lifetime.** Confirmed as *real* bugs
  while writing this package, not hypotheticals -- the same root cause
  bit twice, in two different guises:
  1. `prepWrite`'s first version took no `URing` argument and didn't
     retain anything; a genuine `openat`+`write`+`read`-back test
     produced a truncated/garbled file every time. Root cause --
     `io_uring_prep_write` only *stores* the buffer pointer on the SQE
     for the kernel to read from *later* (during `submit`'s own
     `io_uring_enter` syscall, and in general the kernel may still be
     reading/writing it for a while after that, until the operation's
     completion actually appears) -- but rc2's own ownership analysis
     has no way to know that a `void`-returning, fully opaque foreign
     call "keeps using" its argument after returning, so it treated
     `prepWrite`'s `Buffer` argument as fully consumed and freed it
     right away, well before the kernel ever got to it.
  2. `prepConnect`'s first version freed its own `sockaddr` immediately
     after `io_uring_prep_connect`, reasoning (wrongly, see
     `iouring_util.h`'s own since-corrected comment) that the kernel
     copies the address at prep time -- a genuine loopback TCP test
     failed every connect with `-EAFNOSUPPORT` (the kernel reading
     already-`free`d memory as the sockaddr). Exact same shape of bug
     as (1), just on `malloc`'d memory this package owns directly
     instead of an rc2-refcounted `Buffer`.

  Fixed both the same way: every `prep*` function that hands the
  kernel a pointer for later additionally requires the owning `URing`
  and stashes what it just handed over into one of `URing`'s own
  `IORef`s (`pending : IORef (List Buffer)` for buffers, `pendingAddrs
  : IORef (List AnyPtr)` for sockaddrs) -- a second, library-held
  reference (a live `Buffer` reference, or literally deferring the
  `free`) that survives regardless of what the caller's own code does
  afterward. Trade-off: neither is reclaimed until the whole `URing`
  is (`exit` drops/frees both lists) -- imprecise, but correct, and
  needs zero cooperation from API consumers (the earlier, broken
  design for (1) *did* have a fix available -- keep some later
  reference to `buf` yourself, so rc2's usual "first occurrence moves,
  later ones dup" ownership rule protects it -- but that's an
  easy-to-forget footgun for a caller to have to remember, not
  something this package should rely on silently; (2) has no
  equivalent caller-side fix at all, since a raw `malloc`'d pointer
  isn't rc2-refcounted to begin with).
- **One completion, fully consumed, at a time.** `waitCompletion`/
  `pollCompletion` each combine `io_uring_wait_cqe`/`_peek_cqe` +
  reading every field + `io_uring_cqe_seen` into one atomic Idris call,
  rather than exposing the raw `struct io_uring_cqe *` and a separate
  `cqeSeen` for the caller to remember. Trades a little flexibility
  (can't inspect several outstanding completions before marking any of
  them seen) for making the single most consequential liburing misuse
  bug -- forgetting `io_uring_cqe_seen`, which never reclaims that
  completion-queue slot and eventually wedges the ring once it fills up
  -- structurally impossible from this package's own API.
- **Buffers always start at byte 0.** `prepRead`/`prepWrite`/`prepSend`/
  `prepRecv` all take a plain `Data.Buffer` with no separate byte-offset
  parameter (unlike `libs/rc2base`'s own `Network.RC2.sendBuf`/`recvBuf`,
  which do support one via their own shim's `data + off` pointer
  arithmetic) -- deferred, not fundamental; add an offset parameter
  the same way if a future consumer needs to read/write into the middle
  of a larger accumulator buffer.
- **Socket creation/bind/listen stay synchronous**, via upstream
  `Network.Socket` (not reimplemented here) -- `prepAccept`/`prepConnect`/
  `prepSend`/`prepRecv` only cover the steady-state, per-connection
  operations io_uring actually speeds up. A `Socket`'s own
  `.descriptor : Int` is what every `prep*` function here expects for
  `fd`.
- **`MultishotAccept` is a documented discipline, not a compiler-enforced
  linear resource** -- a real attempt was made at the latter (marking
  `readMultishotAccept`'s own argument multiplicity 1, so reusing an
  already-consumed registration or ignoring a fresh one would be a type
  error), and it does not work here: a value obtained from an ordinary
  `IO` action via `x <- action` is bound at unrestricted multiplicity by
  `Prelude.Monad`'s own generic bind, regardless of what multiplicity
  any *later* function declares for its own parameter -- confirmed
  directly with standalone repros (a `(1 t : Token) -> ...`-consuming
  function called twice on the same do-bound `t` type-checks clean
  under plain `IO`, and so does never consuming an `(1 x : Int)`
  pattern-matched out of a wrapper type at all). Genuine protection
  needs the whole call chain run under `Control.Linear.LIO`'s own
  `L`/`L1` -- exactly the second layer the sibling `network` package's
  own `Control.Linear.Network` already adds on top of plain
  `Network.Socket` -- but that does not compose with waiting on a
  registration's own completions *together* with unrelated ones
  (`prepConnect`/`prepSend`/`prepRecv` completions on the very same
  ring, exactly how `tests/TestSocket.idr` itself uses one) through a
  single shared `waitCompletion` loop, without dedicating an entire
  separate ring to multishot accept alone. So `MultishotAccept` ended
  up the same kind of caller obligation `SQE`'s own single-use
  discipline already is: documented (`hasMore`, checked via
  `readMultishotAccept`), not type-checked.

## Scope (deliberately deferred)

- **Fixed files/buffers** (`IORING_SETUP_SQPOLL`,
  `io_uring_register_files`/`_buffers`, `IOSQE_FIXED_FILE`) -- the
  registration-heavy, highest-throughput end of io_uring's own API;
  real design work of its own (buffer/file-slot lifetime management),
  not attempted here.
- **Multishot recv/poll** (`prepMultishotAccept` is this package's only
  multishot operation so far) -- `IORING_RECV_MULTISHOT` additionally
  needs provided buffers (`io_uring_register_buf_ring`) to be workable,
  which is its own registration-lifetime design work, not attempted
  yet.
- **Linked SQEs** (`IOSQE_IO_LINK`, chaining several operations so the
  kernel only starts the next once the previous succeeds) -- each
  `prep*` function here is independent; no linking flag is exposed.
- **Poll operations** (`io_uring_prep_poll_add`, io_uring standing in
  for `epoll`) -- `System.Net.Epoll` already covers this project's own
  event-loop needs (`Network.HTTP.Server`); not duplicated here.
- **`IORING_SETUP_SQPOLL`/advanced setup flags** -- `init`'s own
  `queueDepth` is the only knob exposed; every `io_uring_setup` flag
  beyond the default is out of scope for this first cut.

## Verification

`tests/verify.sh`: unlike `libs/notcurses` (needs a real terminal,
mostly unautomatable), every operation this package covers is fully
headless -- file I/O against a real temp file, and a real loopback TCP
accept/connect/send/recv pair, both driven end to end through actual
`io_uring_submit`/`waitCompletion` round-trips, no mocking. See
`tests/`'s own `TestNop.idr`/`TestFile.idr`/`TestSocket.idr` --
the latter covers both `prepAccept` (`singleShotTest`) and
`prepMultishotAccept` (`multishotTest`: two connections accepted from
one registration, then a `prepCancel64` to reach its terminal,
`hasMore = False` completion).
