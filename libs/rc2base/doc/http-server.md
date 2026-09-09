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

## Architecture

Two modules, layered:

- `System.Net.Epoll` -- a thin FFI wrapper around Linux `epoll` plus
  the two socket options an event-driven server needs that the
  standard `network` package doesn't expose: non-blocking mode
  (`setNonBlocking`, via `fcntl`/`O_NONBLOCK`) and `SO_REUSEADDR`
  (`setReuseAddr`, so a restarted server can rebind immediately). Its
  C side (`support/c/event_util.c`) caches one `epoll_wait` call's
  results in a single static buffer -- fine for this library's
  one-`EPoll`-per-process design, but means two `EPoll`s must never
  have `wait` calls in flight at the same time.
- `Network.HTTP.Server` -- the HTTP logic itself: request/response
  types, a minimal HTTP/1.1 parser, per-connection read/write
  buffering, and the event loop that ties it all to `System.Net.Epoll`.
  All state lives in two records threaded through plain function
  arguments (`ServerState` for the shared epoll handle + connection
  table, `Conn` for one connection's buffers) -- no global/`IORef`
  CAF anywhere in the module (see "CAFs with side effects" below for
  why that matters).

Every function in `Network.HTTP.Server`'s event loop (`closeConn` ->
`finishWrite` -> `flushWrite` -> `respond`/`tryDispatch` ->
`handleReadable`/`handleClientEvent`/`acceptLoop` -> `loop`) is defined
in that dependency order with no cycles, so no `mutual` block is
needed despite how tangled a hand-rolled event loop can look.

## Wire format: what's actually supported

A deliberately small HTTP/1.1 subset:

- Request line + headers + an optional `Content-Length`-delimited
  body. Header parsing is case-insensitive on the name, whitespace-
  trimmed on the value.
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
- Any request size limit -- an unbounded `Content-Length` (or an
  attacker who never sends a terminating `\r\n\r\n`) grows `readBuf`
  without bound. Fine for a trusted-client / internal-tool use case,
  not for anything internet-facing without a proxy in front of it.

## Platform: Linux only

`epoll` is Linux-specific; there's no `kqueue` (BSD/macOS) or IOCP
(Windows) backend. Not attempted, since this project's own development
and deployment target is Linux (see the top-level `AGENT.md`).

## Using it

```idris2
import Network.HTTP.Server

handler : Handler
handler req respond =
  case req.path of
    "/hello" => respond (MkResponse 200 [] "hello\n")
    _        => respond (MkResponse 404 [] "not found\n")

main : IO ()
main = serve 8080 handler   -- binds 127.0.0.1:8080, blocks forever
```

`respond` can also be stashed and called later -- from inside a
different request's handler, from a `forkJoin`ed thread, from
anywhere that's still `IO` -- to answer asynchronously:

```idris2
handler : IORef (Maybe (Response -> IO ())) -> Handler
handler pending req respond =
  case req.path of
    "/wait"    => writeIORef pending (Just respond)   -- don't respond yet
    "/release" => do Just held <- readIORef pending
                        | Nothing => respond (MkResponse 200 [] "nothing waiting\n")
                      held (MkResponse 200 [] "released\n")
                      respond (MkResponse 200 [] "ok\n")
    _          => respond (MkResponse 404 [] "not found\n")
```

To bind somewhere other than `localhost`, pass `bindAddr` explicitly:
`serve {bindAddr = IPv4Addr 0 0 0 0} 8080 handler` listens on every
interface.

Verified end-to-end (compiled with `--cg rc2`, exercised with `curl`):
a synchronous handler, an asynchronous one exactly like the sketch
above (one connection held open while a second request releases it),
and keep-alive reuse across several requests on the same connection.

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
