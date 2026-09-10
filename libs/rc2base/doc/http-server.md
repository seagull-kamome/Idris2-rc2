# `Network.HTTP.Server`: a minimal event-driven HTTP server

## Motivation

rc2base needed a way to stand up an HTTP endpoint without pulling in a
thread pool or a full async runtime: something that starts with one
function call, runs on a single OS thread, and lets each request
answer either immediately or later (once some other event -- a
timer, another request, a stashed callback from elsewhere -- makes the
answer available). `Network.HTTP.Server.serve` plus its `Handler`
continuation-passing API is that: one `epoll` loop drives everything,
and a `Handler` gets its response back not as a return value but as a
`Response -> IO ()` continuation it can call whenever it likes.

Two things beyond the bare minimum are still in scope, because doing
them by hand on top of a single-threaded loop is error-prone:

- **the `respond` continuation is safe to call from any thread**, not
  just the loop's -- a `forkJoin`ed worker can compute a reply and
  hand it back directly;
- **a handler (or a thread it spawned) can stop the loop**, via a
  `stop` action, so `serve` returns instead of blocking forever.

Both are implemented the same way: the off-loop call doesn't touch a
socket or the epoll set itself (that would race the loop). It appends a
closure to a mutex-guarded queue and writes an `eventfd` that the loop
also waits on; the loop wakes, drains the queue, and runs those
closures itself. The loop stays single-threaded; only the hand-off is
shared state.

Request and response bodies are raw bytes (`Data.Buffer`), not
`String` -- see "Bodies are bytes" below.

## Architecture

Three modules, layered:

- `System.Net.Epoll` -- a thin FFI wrapper around Linux `epoll` plus
  the socket options an event-driven server needs that the standard
  `network` package doesn't expose: non-blocking mode
  (`setNonBlocking`, via `fcntl`/`O_NONBLOCK`) and `SO_REUSEADDR`
  (`setReuseAddr`, so a restarted server can rebind immediately). It
  also wraps `eventfd` (`createEventFd`/`signalEventFd`/`drainEventFd`)
  -- a descriptor the loop registers alongside its sockets so any
  thread can break it out of `wait` -- and `closeEpoll`/`closeFd` for
  tearing the loop's own descriptors down. Its C side
  (`support/c/event_util.c`) caches one `epoll_wait` call's results in
  a single static buffer -- fine for this library's
  one-`EPoll`-per-process design, but means two `EPoll`s must never
  have `wait` calls in flight at the same time.
- `Network.RC2` -- offset+length socket IO straight into and out of a
  `Data.Buffer` (`sendBuf`/`recvBuf`), plus `isWouldBlock`. The
  standard `network` package only moves bytes through a `String`
  (`send`/`recv` -- truncates at the first NUL) or a `List Bits8`
  (`sendBytes`/`recvBytes` -- one cons cell per byte); neither is
  usable for a server shuffling binary payloads through a reused
  accumulator. Its C side (`support/c/net_util.c`) is a two-function
  shim over plain `send`/`recv` that does `data + off`; `errno` on a
  failed call is read with `Network.Socket.Data.getErrno` (what
  `network`'s own `send`/`recv` use), not a shim of its own.
- `Network.HTTP.Server` -- the HTTP logic itself: request/response
  types, a byte-scanning HTTP/1.1 parser, per-connection read/write
  buffering, and the event loop that ties it all to `System.Net.Epoll`
  and `Network.RC2`. All state lives in records threaded through plain
  function arguments (`ServerState` for the epoll handle, connection
  table, a `ServerCtx`, and `maxReq`; `ServerCtx` for the cross-thread
  hand-off -- mutex, task queue, stop flag, wakeup `eventfd`, and the
  loop thread's id; `Conn` for one connection's read/write byte
  accumulators) -- no global/`IORef` CAF anywhere in the module (see
  "CAFs with side effects" below for why that matters).

Every function in `Network.HTTP.Server`'s event loop (`closeConn` ->
`finishWrite` -> `flushWrite` -> `appendResponse` ->
`deliver`/`respond`/`dropFront`/`tryDispatch` ->
`handleReadable`/`handleClientEvent`/`acceptLoop` ->
`drainTasks`/`shutdown` -> `loop`) is defined in that dependency order
with no cycles, so no `mutual` block is needed despite how tangled a
hand-rolled event loop can look.

### Bodies are bytes

`Request.body` and `Response.body` are `Data.Buffer` -- exactly the
bytes on the wire, no NUL or encoding assumptions. `String` was the
original choice and is wrong for binary: the `network` package's
`send`/`recv` marshal through a C `char*` (so a body with an embedded
`\0` is truncated on both send and receive), and `strLength`/`strSubstr`
are codepoint-based under `--cg chez` but byte-based under
`--cg rc2`/`refc`, so `Content-Length` arithmetic and slicing disagree
across backends.

Helpers on `Network.HTTP.Server`:

- `byteLength : Buffer -> Int` -- pure, reads the buffer's size header.
  A body carries no separate length field; this *is* its length, so
  there is nothing to keep in sync.
- `fromString : String -> IO Buffer` -- UTF-8-encode; the string must be
  NUL-free (length via `strlen`). `toString : Buffer -> IO String`
  decodes a whole buffer the other way, for a body known to be text.
- `Response.*` constructors, under the `Response` namespace (call them
  bare when unambiguous, `Response.text` etc. otherwise), each with an
  optional leading implicit `headers : List (String, String)` (default
  `[]`):
  - `text`, `html` (`status -> body -> IO Response`) -- set
    `Content-Type: text/plain`/`text/html; charset=utf-8`.
  - `ok` / `created` / `badRequest` / `notFound` / `serverError`
    (`body -> IO Response`) -- `text` at 200 / 201 / 400 / 404 / 500.
  - `bytes` (`status -> contentType -> Buffer -> Response`) -- pure;
    for a body you already hold.
  - `noBody` (`status -> IO Response`) -- empty body, no `Content-Type`
    (204, a 3xx with a `Location` header, ...).

The read and write accumulators are reused `Buffer`s that grow by
reallocation (roughly doubling), each capped: the read side at
`maxRequestBytes` (a `serve` argument, default 8 MiB), the write side
at a fixed 64 MiB backstop. `Network.RC2.recvBuf`/`sendBuf` read and
write in place at the accumulator's cursor -- no per-syscall copy.

### The cross-thread hand-off

`ServerCtx` is threaded to every `Handler` as an **auto-implicit**, so
handler code writes a bare `stop` and the enclosing `Handler`'s own
implicit satisfies the search -- there's never more than one server per
`serve` call, so nothing to disambiguate. `serve` supplies the implicit
once, up front; internally the loop threads the already-applied
`BoundHandler` (`Request -> (Response -> IO ()) -> IO ()`) so the
implicit is never re-solved at each call site.

- `respond` checks `getThreadId` against the loop thread's. On the loop
  thread (an ordinary synchronous handler) it calls `deliver`
  immediately -- identical to the old behaviour, no queue, no syscall.
  Off the loop thread it appends `deliver` to `ServerCtx.tasks` and
  signals the `eventfd`.
- `stop` (and the internal `requestStop`) sets `ServerCtx.stopReq` and
  signals the `eventfd`, from any thread.
- `loop`, each iteration: `wait`; process ready events (a ready wakeup
  `eventfd` is just drained); `drainTasks` (swap the task list out under
  the lock, run the closures with the lock released, oldest first);
  then check `stopReq` and either `shutdown` or recurse. `drainTasks`
  every iteration plus a level-triggered `eventfd` means a signal that
  races in during draining is never lost -- worst case it costs one
  extra no-op wakeup.
- `shutdown` closes every connection, the listener, the wakeup
  `eventfd`, and the epoll fd, then `loop` and `serve` return.

The mutex is held only around the list/flag swaps, never while running a
task or doing socket I/O, so a task that itself calls `stop` or hands
back another `respond` doesn't deadlock (the pthread mutex isn't
recursive under `--cg rc2`).

## Wire format: what's actually supported

A deliberately small HTTP/1.1 subset:

- Request line + headers + an optional `Content-Length`-delimited
  body. The parser scans the accumulator's bytes directly for the
  `\r\n\r\n` terminator, line breaks, spaces and colons; only the
  method, path, and each header key/value are lifted out to `String`
  (each on its own `getString` of its byte range), never one big head
  string. Header key match is case-insensitive; the value is SP/HTAB-
  trimmed. The body is handed over as raw `Buffer` bytes.
- Keep-alive by default (HTTP/1.1's own default); an explicit
  `Connection: close` request header closes the connection after that
  response.
- One request dispatched per parser pass, but the parser reruns
  against whatever's left in the read buffer after each dispatch
  (`tryDispatch`'s own tail call) -- so if a `recv` happens to land two
  full requests in one read (pipelining, or just two requests that
  arrive close together), both get processed without waiting for a
  third read event that might not come.

Explicitly **not** supported, all considered genuinely out of scope
rather than deferred:

- `chunked` transfer encoding (request or response) -- only
  `Content-Length` bodies.
- HTTP/1.0 (its default is connection-per-request, the opposite of
  HTTP/1.1's default this parser assumes).
- Response ordering guarantees under pipelining -- if two pipelined
  requests both answer asynchronously, nothing stops the second one's
  `respond` from being called (and its bytes hitting the wire) before
  the first one's, which is a protocol violation a real pipelining
  client would notice. Fine for the common case (no pipelining, or a
  synchronous handler), a real problem only for an async handler under
  a pipelining client -- not attempted here.
- TLS. Plain TCP only.
- A polite response to an over-large request. The read accumulator is
  capped at `maxRequestBytes` (default 8 MiB); a request whose
  header+body would exceed it -- including an attacker who never sends
  a terminating `\r\n\r\n` -- has its **connection dropped with no
  response**, not a `413`. Fine for a trusted-client / internal-tool
  use case; put a proxy in front for anything internet-facing.
- Graceful drain on `stop`. The loop finishes its current iteration --
  so responses already queued (including cross-thread `respond`s that
  have been enqueued) are flushed -- but a `respond` that only reaches
  the queue *after* `shutdown` has run is silently dropped: its
  `signalEventFd` write hits a closed fd (harmless `EBADF`), and its
  closure is never run. Call `stop` when the async work you care about
  has already handed its response back, or not at all.

## Platform: Linux only

`epoll` is Linux-specific; there's no `kqueue` (BSD/macOS) or IOCP
(Windows) backend. Not attempted, since this project's own development
and deployment target is Linux (see the top-level `AGENT.md`).

## Using it

A body is a `Buffer`. `Response.text` (and friends) build a text
response; `MkResponse` takes a `Buffer` directly for binary.

```idris2
import Network.HTTP.Server

handler : Handler
handler req respond =
  case req.path of
    "/hello" => respond !(text 200 "hello\n")
    "/echo"  => respond (MkResponse 200 [] req.body)   -- binary passthrough
    "/img"   => respond (bytes 200 "image/png" pngBuf)
    _        => respond !(notFound "not found\n")

main : IO ()
main = serve 8080 handler   -- binds 127.0.0.1:8080, runs until `stop`
```

Add response headers with the leading implicit:
`respond !(ok {headers = [("Cache-Control", "no-store")]} "done")`.

`respond` can also be stashed and called later -- from inside a
different request's handler, from a `forkJoin`ed thread, from
anywhere that's still `IO` -- to answer asynchronously:

```idris2
handler : IORef (Maybe (Response -> IO ())) -> Handler
handler pending req respond =
  case req.path of
    "/wait"    => writeIORef pending (Just respond)   -- don't respond yet
    "/release" => do Just held <- readIORef pending
                        | Nothing => respond !(text 200 "nothing waiting\n")
                      held !(text 200 "released\n")
                      respond !(text 200 "ok\n")
    _          => respond !(notFound "not found\n")
```

Computing the reply on another thread and handing it back is fine too
-- `respond` marshals itself onto the loop thread:

```idris2
handler : Handler
handler req respond =
  case req.path of
    "/slow" => do ignore $ forkJoin {a = ()} $ do
                    body <- expensive req          -- off the event loop, : IO Buffer
                    respond (MkResponse 200 [] body)
    _       => respond !(notFound "not found\n")
```

To stop the loop, call `stop` (its `ServerCtx` comes from the
`Handler`'s auto-implicit, so no argument needed) -- from the handler,
or from a thread it hands `stop` to. `serve` returns once the loop
unwinds:

```idris2
handler : Handler
handler req respond =
  case req.path of
    "/shutdown" => do stop
                      respond !(text 200 "bye\n")   -- flushed before exit
    _           => respond !(notFound "not found\n")

main : IO ()
main = do serve 8080 handler
          putStrLn "server stopped"
```

To cap request size differently, pass `maxRequestBytes`:
`serve {maxRequestBytes = 65536} 8080 handler`.

To bind somewhere other than `localhost`, pass `bindAddr` explicitly:
`serve {bindAddr = IPv4Addr 0 0 0 0} 8080 handler` listens on every
interface.

Verified end-to-end under `--cg rc2` (`tests/TestHTTPServer.idr`, in
`tests/verify.sh`): a synchronous handler, an async one that answers
from a `forkJoin`ed thread, `stop` called synchronously from a handler,
`stop` called from a forked thread (with the response still flushed
first), a second `serve` rebinding the same port after the first one's
`shutdown` released it, and -- for binary safety -- a POST body of 259
bytes including four NUL bytes reported back whole by the handler, plus
a response body containing NULs read back byte-for-byte by the client.
The earlier hand-run `curl` checks (async hold/release across two
connections, keep-alive reuse) still stand.

## Known limitation: CAFs with side effects aren't memoized under `--cg rc2` (or upstream `--cg refc`)

Found while writing this module's own test program: a top-level
`unsafePerformIO`'d value --

```idris2
counter : IORef Int
counter = unsafePerformIO (newIORef 0)
```

-- is **not** evaluated once and cached the way it is under `--cg
chez` (confirmed: Chez prints `0 1 2` for three successive reads/
increments of such a counter). Both `--cg rc2` and upstream's own `--cg
refc` instead compile the CAF as an ordinary zero-argument function
and call it fresh every time it's referenced, printing `0 0 0` --
three unrelated `IORef`s, not one shared one. Confirmed side-by-side
with a throwaway test program under all three backends before writing
this up, specifically to rule out an rc2-specific bug: RefC has the
exact same behavior, so this is an upstream C-backend characteristic
`Network.HTTP.Server` has to live with, not something this module (or
rc2) could fix on its own.

Practical effect: **never** create an `IORef` (or anything else with
`newIORef`-like once-only semantics) via a top-level `unsafePerformIO`
to share state across a `Handler` (e.g. the "hold one request, release
it from another" pattern above) when targeting `--cg rc2`/`--cg refc`
-- it silently gives every call site its own `IORef` instead of one
shared one, with no error or warning, and the resulting bug (state
that never appears to persist) has no obvious connection to its actual
cause at the call site. Create the `IORef` in `main` (or anywhere else
that runs once, in `IO`, before `serve` is called) and pass or
partially-apply it into the `Handler` instead, same as this doc's own
async example does -- this is the only correct pattern under this
module, not a preference.
