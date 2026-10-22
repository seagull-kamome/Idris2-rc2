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
| `close : Sock -> IO ()` | idempotent |
| `withSock : Sock -> Task a -> Task a` | closes the socket when the task ends *or is given up* |

`send` uses `MSG_NOSIGNAL`: a peer that went away is `EPIPE`, not SIGPIPE.

`withSock` is how a cancelled scope (a `race` that was lost, say) closes the
descriptors of the tasks in it: it spawns a sentinel in the scope whose
cancellation closes the socket, and ends the sentinel when the task is done.

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
  keep-alive by default, `Connection: close`, no chunked encoding, no TLS. A
  request larger than `maxRequestBytes` (default 8 MiB) or with a malformed head
  has its connection closed with no response.
- When `accept` runs out of descriptors the server waits 10 ms and tries again.

Tested by `tests/TestNetworkAsync` and `tests/TestAsyncHTTPServer`.

## Open points

- An asynchronous `connect` (for clients).
- An io_uring variant of `Network.Async` with the same types.
- Responses are written whole with `sendAll`; a body that is large or comes
  piece by piece has no streaming interface yet.
