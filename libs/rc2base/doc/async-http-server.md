# `Network.Async` and `Network.Async.HTTP.Server`: an HTTP server made of tasks

## Why a second server

`Network.HTTP.Server` is one `epoll` loop; a `Handler` answers through a
`respond` continuation, and work on other threads is handed back through a queue
and an eventfd. `Network.Async.HTTP.Server` does the same job on `Control.Task`
(see `task.md`): the scheduler is the loop, and every connection is a task. The
old server stays until the two have been measured against each other.

## `Network.Async`

Sockets whose calls are tasks. A `Sock` is non-blocking; a call that would block
waits for the descriptor on the scheduler's epoll (`awaitReadable`,
`awaitWritable`) and tries again.

| | |
| --- | --- |
| `listen : Port -> IO (Either Errno Sock)` | bind (loopback unless `bindAddr` is given) and listen, with `SO_REUSEADDR` |
| `accept : Sock -> Task (Either Errno Sock)` | the next connection, non-blocking |
| `connect : SocketAddress -> Port -> Task (Either Errno Sock)` | connect to an IPv4 address and wait until it is made; a host name or IPv6 is `EAFNOSUPPORT` (the lookup would block); the socket is handed over like `accept`'s, and closed if the connect is given up |
| `recv : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno Int)` | into `buf[off ..]`; `Right 0` is end of input |
| `send`, `sendAll` | `send` writes some bytes, `sendAll` all of them |
| `shutdownWrite`, `discard` | `shutdown(SHUT_WR)`, and reading and throwing away what the peer sends (until it closes, an error or a byte limit; the time limit is the caller's, with `timeoutAt`): with `close`, a lingering close |

`recv` and `send` refuse (`EINVAL`) a range that is empty or reaches outside the
buffer, before any system call.

| | |
| --- | --- |
| `close : Sock -> IO ()` | idempotent; not for two threads at once, see below |
| `withSock : Sock -> Task a -> Task a` | closes the socket when the task ends *or is given up* |

`send` uses `MSG_NOSIGNAL`: a peer that went away is `EPIPE`, not SIGPIPE.

`withSock` is how a cancelled scope (a `race` that was lost, say) closes the
descriptors of the tasks in it: it is `finally (\_ => close s)`. `accept` hands the
new socket over with `handoff`, and the server starts each connection with
`spawnOwning (close conn)`, so a connection is closed also when the scope is
cancelled between its being accepted and its task starting (see `task.md`, "Not
losing what is handed over").

No liburing is involved. `Network.Async` does not import `Control.Task.Uring`,
and io_uring operations can still be used in the same program.

## `Network.Async.HTTP.Server`

```idris2
handler : Handler            -- Request -> Task Response
handler req = case req.path of
  "/hello" => liftIO (ok "hello\n")
  "/slow"  => sleepFor 100 *> liftIO (ok "slow\n")
  _        => liftIO (notFound "no\n")

main : IO ()
main = ignore (runTaskWith 4 (serve 8080 handler))
```

- `serve port handler` listens and runs until it is given up; its result is the
  `Errno` that ended it. `serveOn listener handler` takes a listener made by
  `listen`.
- To stop the server, race it: `race (serve 8080 handler) shutdownSignal`. The
  connections are closed with it.
- One task per connection: it reads a request, runs the handler, writes the
  response, and repeats. So a slow handler holds up only its own connection, and
  responses on a connection come in the order of the requests.
- `Request` and `Response`, the `Response.*` constructors and the parser are those
  of `Network.HTTP.Message`, which this module re-exports.
- The wire-format subset is that of `http-server.md`: `Content-Length` bodies,
  keep-alive by default (for HTTP/1.1), no chunked encoding, no TLS. What cannot be served is
  answered, with `Connection: close`, and the connection ends:
  `400` for a head that cannot be parsed or framing headers that cannot be trusted
  (`bodyLength`, `parseHead`), `413` for a request over `limits.maxRequestBytes`
  (default 8 MiB), `431` for a head over `limits.maxHeadBytes` (default 64 KiB; a
  head cannot be longer than the request limit either, so the smaller of the two
  applies). Pass `serve {limits = MkLimits head request}` to change them. After
  the answer the server does a *lingering close*: it shuts down its side, reads and
  discards what the client still sends for up to one second and 256 KiB (a `408`
  does the same), then closes (a refused connection is held that much longer), so that a body that was refused unread does not make the system reset the
  connection and take the answer with it. A client that sends more than that, or
  more slowly, can still lose the answer.
- A request with `Connection: close` (also as one token among others), or a
  handler that answers with `Connection: close`, ends the connection after the
  response, and the response then has a single `Connection: close` header: any
  other `Connection` header of the handler is replaced. The response to `HEAD`
  has the head of the response to `GET` and no body, as have 1xx, 204 and 304, which
  have no `Content-Length` either. The route table of `Network.Async.HTTP.Router` sends
  a `HEAD` that no `head` route takes to the `get` route of the same path.
- HTTP/1.0 requests are served too, and the response is still `HTTP/1.1`. The
  connection ends after the response unless the request has `Connection: keep-alive`,
  and then the response says `Connection: keep-alive`. A request line without a
  version, or one that does not start with `HTTP/`, is `400`; a version other than
  `HTTP/1.0` and `HTTP/1.1` is `505`.
- The end of the head is looked for from where the previous bytes ended, not from
  the start each time, and the head is parsed once, not at every read of the body.
- `accept` that ran out of descriptors or memory is tried again after 10 ms; one
  that failed with an error of the moment (`ECONNABORTED`, `EPROTO`, the network
  errors `accept(2)` lists) at once. Any other error ends the server.
- Timeouts (`Limits`, in milliseconds; 0 is none): `idleTimeoutMs` (default 60 s)
  is how long a connection may wait for the first byte of a request, the first one or
  the next one of a kept-alive connection; after it the connection is closed.
  `requestTimeoutMs` (30 s) is how long a request may take from its first byte to
  its last: one deadline for the head and the body together, not a time per read, so a
  client that sends a byte at a time does not hold the connection; after it the
  request is answered with `408` and the connection ends. `writeTimeoutMs` (30 s) is
  how long a response may take to go out; after it the connection is closed. The time
  the handler takes is not counted: give a handler that may wait for long its own
  `timeoutAt`.
- Requests that arrive together are served one after the other, and what is left
  after each is copied to the front of a new buffer; for thousands of tiny pipelined
  requests in one read that is quadratic (not measured).

`Sock.close` is not safe to call from two threads at once. `withSock` and the server
call it on the thread of the scheduler, and so are the system calls of `accept`,
`recv`, `send` and `connect`, so no call is running on a worker when a connection
is closed and its descriptor number cannot be reused under it.

Tested by `tests/TestNetworkAsync` and `tests/TestAsyncHTTPServer`.

## One thread or several

The server is the same either way; what changes is how the tasks are run.

```idris2
main = ignore (runServer 8 (serve 8080 handler))   -- 0: one thread
```

`runServer n` is `runTaskParallel n` (`runServer 0` is `runTask`): the handler's own
`liftIO`s, and the encoding of the response and the copy of a body, run on `n` threads
at the same time, and a task that waits for the network or a timer gives its thread to
other requests. The control of the tasks (`>>=`, `race`, `spawn`, the waits) stays on
one thread, the *reactor*, which also watches the descriptors and does the small steps
-- the non-blocking system calls, finding the end of the head and parsing it -- because
handing such a step to a worker costs more than it does (`task.md`, "`Point` on the
workers").

What that asks of a handler: whatever it shares with other requests must be safe
to share. Use `Control.Task.Ref`, `MVar` and `Chan` (see `task.md`), not an
`IORef`. `Sock.close` is one more thing the reactor must do: inside a task use
`onReactor (close s)`; `withSock` already does.

`tests/TestAsyncHTTPServerThreads` runs the same handler, which keeps its thread
busy for 60 ms, for four clients: with one thread the handlers never overlap, with
eight they do.

## `Network.Async.HTTP.Router`

`Network.HTTP.Router`'s table, with handlers that give a `Task Response`. The
routes are built with the same `get`, `post`, ... and `Network.HTTP.Route`
patterns; `Network.Async.HTTP.Router.router notFound routes` is a `Handler`.

```idris2
routes : List Network.Async.HTTP.Router.RouteEntry
routes =
  [ get ("hello" // end) (liftIO (ok "hello\n"))
  , get ("users" // capture "id" Int end) (\n => liftIO (ok ("user " ++ show n ++ "\n")))
  ]

handler : Handler
handler = Network.Async.HTTP.Router.router notFound routes
```

To make this possible `Network.HTTP.Route` and `Network.HTTP.Router` are generic in
what a handler gives: `HandlerOf r tys` and `RouteEntryOf r`, with `lookupRoute`
doing the matching. `HandlerFor` and `RouteEntry` are the old shapes
(`r = (Response -> IO ()) -> IO ()`), so existing routes compile unchanged. As
before, a route's handler does not see the `Request` (its captures are all it
gets); a `Handler` that needs the body is used as the `notFound` of the router.

## Performance

`bench/bench.sh` runs `bench/OldServer.idr` (the callback server of `http-server.md`) and
`bench/NewServer.idr` (this server) with the same routes under `wrk` (`new-1` is one
thread, `new-3` is `runServer 3`). Loopback, 4 cores shared with `wrk`, 8 s per
scenario, 2026-10-24: the figures compare the servers with each other on one machine
and mean nothing else.

| scenario (`wrk`) | old req/s | new-1 req/s | new-3 req/s |
| --- | ---: | ---: | ---: |
| `GET /hello`, 1 connection | 22 100 | 16 100 | 6 700 |
| `GET /hello`, 64 connections | 27 900 | 14 000 | 7 900 |
| `GET` 64 KiB body, 16 connections | 13 700 | 10 300 | 5 600 |
| `POST` 64 KiB body, 16 connections | 10 400 | 7 700 | 6 500 |
| 16 pipelined `GET /hello` per write, 16 connections | 6 200 | 6 200 | 6 200 |
| a handler that computes for about 5 ms, 64 connections | 188 | 186 | 426 |
| a handler that sleeps 50 ms, 64 connections | -- | 1 140 | 1 080 |

- On one thread this server does 50 to 75 per cent of the requests per second of the
  callback server when the requests are small or carry 64 KiB, and the same when
  requests are pipelined or the handler computes. With one connection that is about 62 µs
  a request against 45 µs. A `perf record` of 64 connections of `GET /hello` shows no single
  hot spot: `malloc` and `free` take a quarter of the time and the rest is the
  interpreter of `Task` (closures built and applied).
- Timeouts were the largest single cost. Every `recv` and `sendAll` ran inside a
  `timeoutAt`: a `race` with its own scope, a timer in the scheduler's map and
  `timerfd_settime` calls, three times a request. `recvUntil` and `sendAllUntil` try
  the non-blocking call first and make the timeout only if it would block, so a
  request whose data is already there makes none. That is nearly all of the gain:
  user instructions per `GET /hello`, one connection, one thread, 390 000 before and
  262 000 after; requests per second 11 300 before, 16 100 after. In addition a timer
  that is added no longer arms the descriptor when it is not earlier than what the
  descriptor is armed for, and a withdrawn timer leaves it armed (the wake-up finds
  nothing due and `fireTimers` arms the next); how much that saves was not measured
  separately.
- Several threads cost a round trip between the thread of the scheduler and a worker
  for every `liftIO`, and a request has a dozen of small ones. The server therefore runs
  the small steps (the non-blocking `recv` and `send`, parsing the head) with `onReactor`,
  and `>>=` chains the `liftIO`s that follow each other onto one worker
  (`PointThen`, `task.md`). Without them 3 threads gave 2 300 requests a second (1 connection),
  2 600 (64 connections) and 660 (the sleeping handler). They
  help when the handlers compute: 2.4 times the requests of one thread (the 4th
  core is `wrk`'s), and they are still 43 to 60 per cent of one thread on `GET /hello`
  because the handler's own `liftIO`s, the encoding and the copy of the body are
  handed over. The callback server has one thread, so it keeps up with `new-1` there.
- A handler that waits (`sleepFor 50`) does not hold a thread: 64 connections get 1 100
  requests a second where waiting alone would allow 1 280. The callback server has no
  way to wait in a handler.
- Arming the timer once divided a `Nat`, which made this server 5 to 10 times slower
  than the callback server on small requests; see `KNOWN-BUGS.md`, "`Nat` division and
  remainder are slow".

Not measured: many idle connections, large numbers of connections, and the memory used.

## Open points

- An io_uring variant of `Network.Async` with the same types.
- Responses are written whole with `sendAll`; a body that is large or comes
  piece by piece has no streaming interface yet.
