# `System.Linux.Uring`

Idris2 bindings to Linux's `io_uring` async I/O interface, via
[liburing](https://github.com/axboe/liburing) rather than the raw
`io_uring_setup`/`io_uring_enter` syscalls directly. `idris2-rc-cg`'s
own `rc2` backend only. Part of `rc2base`.

## Why liburing, not the raw syscalls

`io_uring_setup`/`io_uring_enter`/`io_uring_register` themselves are a
real but low-level ABI -- the caller owns mmap'ing the submission/
completion ring buffers, computing memory-ordering-correct producer/
consumer index updates by hand, and tracking `IORING_FEAT_*` flags to
know which shortcuts the running kernel actually supports. liburing is
the reference C implementation of exactly that bookkeeping, already
depended on transitively by most real-world io_uring users (`glib`,
`.NET`, Rust's `tokio-uring`, ...). Reimplementing the ring protocol
directly on top of the syscalls, in Idris, would
buy nothing this package's own scope needs and would need to be kept
correct against every future kernel `IORING_FEAT_*` addition by hand.

## How it is bound, with no C shim

`Compiler.RC2.Emit` `#include`s every `%foreign` declaration's header into
the *consumer's* generated `.c` file, so the `static inline` functions of
`<liburing.h>` (`io_uring_get_sqe`, every `io_uring_prep_*`,
`io_uring_sqe_set_data64`, `io_uring_submit(_and_wait)`,
`io_uring_cqe_seen`) bind directly with `"C:fn, liburing, liburing.h"`.
The bindings that need more than a function name are `CExpr:` (see
`rc2/doc/ffi-cexpr.md`), so `rc2base` builds with `gcc` and `ar` only and
needs liburing's headers and library only where a program uses
`System.Linux.Uring`:

1. **`io_uring_queue_init`/`_exit`** want the caller to own the `struct
   io_uring`. `prim__queueInit` is a statement expression that `malloc`s one,
   initialises it, and yields `NULL` after freeing it on failure;
   `prim__queueExit` unregisters the ring and frees it.
2. **`io_uring_wait_cqe`/`io_uring_peek_cqe`** return the completion through
   a `struct io_uring_cqe **`. `prim__waitCqe`/`prim__peekCqe` collapse
   `(return code, out-parameter)` into one pointer, `NULL` meaning failed or
   not ready yet. A successful call never yields a `NULL` completion.
3. **`io_uring_prep_accept`'s `addr`/`addrlen`** are passed as `NULL`: the
   peer's address is not exposed (`getpeername` on the resulting descriptor
   gives it).
4. **`io_uring_prep_connect`'s `addr`** is built by `getaddrinfo`
   (`prim__resolve`, with `AI_NUMERICSERV`, so the port is a decimal string)
   and read through `ai_addr`/`ai_addrlen`. The `addrinfo` list itself is the
   thing kept alive in `URing.pendingAddrs` and released with `freeaddrinfo`.
5. **The `io_uring_cqe` fields** `res`, `user_data` and `flags` have no
   accessor in liburing.h (`io_uring_cqe_get_data64` covers `user_data`
   only); they are `CExpr:` field reads.

`liburing.h` needs no feature-test macro a consumer would not already have.

## Design choices

- **`URing.pending`/`pendingAddrs` keep every in-flight buffer/sockaddr
  alive until its own completion is consumed.** Confirmed as *real* bugs
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
     after `io_uring_prep_connect`, reasoning (wrongly) that the kernel
     copies the address at prep time -- a genuine loopback TCP test
     failed every connect with `-EAFNOSUPPORT` (the kernel reading
     already-`free`d memory as the sockaddr). Exact same shape of bug
     as (1), just on `malloc`'d memory this package owns directly
     instead of an rc2-refcounted `Buffer`.

  Fixed both the same way: every `prep*` function that hands the
  kernel a pointer for later additionally requires the owning `URing`
  and stashes what it just handed over into one of `URing`'s own
  `IORef`s (`pending : IORef (SortedMap Bits64 Buffer)` for buffers,
  `pendingAddrs : IORef (SortedMap Bits64 (Ptr RawAddrInfo))` for sockaddrs) -- a
  second, library-held reference (a live `Buffer` reference, or
  literally deferring the `free`) that survives regardless of what the
  caller's own code does afterward (the earlier, broken design for (1)
  *did* have a fix available -- keep some later reference to `buf`
  yourself, so rc2's usual "first occurrence moves, later ones dup"
  ownership rule protects it -- but that's an easy-to-forget footgun
  for a caller to have to remember, not something this package should
  rely on silently; (2) has no equivalent caller-side fix at all, since
  a raw `malloc`'d pointer isn't rc2-refcounted to begin with).

  First cut, each map was a flat `List` with no key at all -- correct,
  but every entry sat there unreclaimed until the whole `URing` was
  (`exit`), which for a long-running caller (a server issuing many
  reads/writes/sends/recvs/connects over its own lifetime, never
  calling `exit` until shutdown) meant both lists only ever grew.
  Fixed by keying each map on the exact `userData`
  `prepRead`/`prepWrite`/`prepSend`/`prepRecv`/`prepConnect` now
  require as a mandatory parameter (not set afterward via
  `setUserData`, unlike every other `prep*` -- the key has to be known
  at insertion time) and having `waitCompletion`/`pollCompletion`
  release the matching entry the moment its own `Completion` comes
  back; `exit` is now only a backstop for whatever never got a
  completion consumed at all. The one caveat this trade brought in:
  two of these five calls in flight *concurrently* on the same ring
  must use distinct `userData`, or the second's insert silently
  overwrites the first's map entry -- unlike a tag collision anywhere
  else in this package (merely inconvenient for telling completions
  apart), here it drops the protective reference on the first
  `Buffer`/`sockaddr` while the kernel may still be about to touch it,
  reintroducing the exact bug this whole mechanism exists to prevent.
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
  which do support one via their own `data + off` pointer
  arithmetic) -- deferred, not fundamental; add an offset parameter
  the same way if a future consumer needs to read/write into the middle
  of a larger accumulator buffer.
- **Socket creation/bind/listen stay synchronous**, via upstream
  `Network.Socket` (not reimplemented here) -- `prepAccept`/`prepConnect`/
  `prepSend`/`prepRecv` only cover the steady-state, per-connection
  operations io_uring actually speeds up. Every `prep*` function takes a
  `System.Posix.FileDesc`; a `Socket`'s own `.descriptor : Int` becomes one
  with `mkFileDesc (cast sock.descriptor)`.
- **Errors are `Either Errno`, as in the rest of `rc2base`.** `init`,
  `submit`, `submitAndWait` and `waitCompletion` return `Left errno` on
  failure; `pollCompletion` returns `Right Nothing` when nothing is ready.
  A request's own `res` is read with `result` (a count) or `fdResult` (the
  descriptor `prepAccept` and `prepOpenat` produce), which turn a negative
  `-errno` into `Left`. `getSqe` stays `Maybe`: a full queue is not an
  `errno`. `prepOpenat` takes `Maybe DirDesc` (`Nothing` is `AT_FDCWD`) and
  the `O_*` flags of `System.Posix.File`.
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
  ring, exactly how `tests/TestUringSocket` itself uses one) through a
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
  for `epoll`) -- `System.Linux.Epoll` already covers this project's own
  event-loop needs (`Network.HTTP.Server`); not duplicated here.
- **`IORING_SETUP_SQPOLL`/advanced setup flags** -- `init`'s own
  `queueDepth` is the only knob exposed; every `io_uring_setup` flag
  beyond the default is out of scope for this first cut.

## Verification

`tests/verify.sh` (`TestUringNop`, `TestUringFile`, `TestUringSocket`; skipped
with a `SKIP` line when gcc cannot find `liburing.h`): unlike `libs/notcurses`
(needs a real terminal, mostly unautomatable), every operation covered is fully
headless -- file I/O against a real temp file, and a real loopback TCP
accept/connect/send/recv pair, both driven end to end through actual
`io_uring_submit`/`waitCompletion` round-trips, no mocking. See
`TestUringSocket` covers both `prepAccept` (`singleShotTest`) and
`prepMultishotAccept` (`multishotTest`: two connections accepted from
one registration, then a `prepCancel64` to reach its terminal,
`hasMore = False` completion).
