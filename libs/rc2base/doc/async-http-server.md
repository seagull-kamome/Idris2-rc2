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
| `recv : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno Int)` | into `buf[off ..]`; `Right 0` is end of input |
| `send`, `sendAll` | `send` writes some bytes, `sendAll` all of them |

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
  keep-alive by default, no chunked encoding, no TLS. What cannot be served is
  answered, with `Connection: close`, and the connection ends:
  `400` for a head that cannot be parsed or framing headers that cannot be trusted
  (`bodyLength`), `413` for a request over `limits.maxRequestBytes` (default 8 MiB),
  `431` for a head over `limits.maxHeadBytes` (default 64 KiB). Pass
  `serve {limits = MkLimits head request}` to change them.
- A request with `Connection: close` (also as one token among others) is answered
  with `Connection: close` and the connection ends. The response to `HEAD` has the
  head of the response to `GET` and no body, as have 1xx, 204 and 304, which have no
  `Content-Length` either. (A route table does not send `HEAD` to the `GET` route:
  `Method` has `HEAD`, but a route for it has to be written.)
- The end of the head is looked for from where the previous bytes ended, not from
  the start each time, and the head is parsed once, not at every read of the body.
- `accept` that ran out of descriptors or memory is tried again after 10 ms; one
  that failed with an error of the moment (`ECONNABORTED`, `EPROTO`, the network
  errors `accept(2)` lists) at once. Any other error ends the server.
- There is no timeout on reading or writing yet: a client that sends one byte at a
  time holds its connection (and the memory of its head, up to the limit).

`Sock.close` is not safe to call from two threads at once. `withSock` and the server
call it on the thread of the scheduler. A `recv` or `send` that is already running on
a worker (parallel mode) when the connection is closed is not stopped, so a
descriptor number that is reused in that moment could be read or written by it.

Tested by `tests/TestNetworkAsync` and `tests/TestAsyncHTTPServer`.

## One thread or several

The server is the same either way; what changes is how the tasks are run.

```idris2
main = ignore (runServer 8 (serve 8080 handler))   -- 0: one thread
```

`runServer n` is `runTaskParallel n` (`runServer 0` is `runTask`): the actions
of the tasks -- reading and parsing a request, the handler's own `liftIO`s,
the system calls -- run on `n` threads at the same time, and a task that waits
for the network (`accept`, `recv`, `send` when they would block) gives its thread
to other requests. The control of the tasks (`>>=`, `race`, `spawn`, the waits)
stays on one thread, the *reactor*, which also watches the descriptors.

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

## Open points

- An asynchronous `connect` (for clients).
- An io_uring variant of `Network.Async` with the same types.
- Responses are written whole with `sendAll`; a body that is large or comes
  piece by piece has no streaming interface yet.
