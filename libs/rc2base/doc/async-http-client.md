# `Network.Async.HTTP.Client`: the HTTP client as a task

`Network.HTTP.Client` (libcurl) blocks the thread for a whole transfer.
`Network.Async.HTTP.Client` gives the same requests and answers as a `Task`
of the scheduler (`Control.Task`), so a program that is waiting for a server
can wait for other things too (a terminal, a timer, other transfers). The
synchronous client is unchanged; its users need not move.

```idris2
r <- fetchAsync curlClient (get "https://example.com/")      -- Task (Either FetchError FetchResponse)

-- the body as it arrives
Right (head, stream) <- streamAsync curlClient (post url body)
chunk <- nextChunk stream            -- Task (Either FetchError (Maybe Buffer)); Nothing: the end
closeStream stream
```

## Modules

| Module | Role |
|---|---|
| `Network.Async.HTTP.Client` | `AsyncHTTPClient` (`fetchAsync`, `fetchBytesAsync`), `fetchTextAsync`, `FetchHead` (status and headers of an answer whose body is coming) |
| `Network.Async.HTTP.Client.Curl` | the implementation on libcurl for `CurlClient`; `streamAsync`, `nextChunk`, `closeStream` and the pure `parseHeads`/`finalHead` |

A program using them needs the same packages as `Network.HTTP.Client.Curl`
and libcurl 8.8.0 or later (`curl_multi_waitfds`).

## How a transfer is driven

Each request has an easy handle in a multi handle of its own, so transfers
share nothing and a task given up takes only its own with it. The task loops:

1. `curl_multi_perform` does what it can without waiting and says whether
   the transfer is over;
2. if not, the task waits for the first of: a socket from
   `curl_multi_waitfds` becoming ready (`awaitEvents` on the scheduler's
   `epoll`), or the time `curl_multi_timeout` names (at most one second,
   50 ms when libcurl names none, for the thread that resolves a name);
3. and goes to 1.

No thread blocks, no C callback is needed (Idris cannot hand a closure to C),
and libcurl is only called from the task, one call at a time.

The body is written by libcurl to a memory stream
(`CURLOPT_WRITEDATA` and `open_memstream`, as in `doc/http-client.md`), and the
response head to a second one (`CURLOPT_HEADERDATA`). After each `perform` the
stream is flushed and what was not handed out yet is copied to a `Buffer`; that
is how `nextChunk` gives the body in pieces. The stream keeps the whole body
until the transfer is closed, so a body without end holds memory.

The head is read from the header stream as text (`parseHeads`): a redirected
transfer writes one head per response, and the head of the answer is the last
one, closed by its blank line, that is not informational (1xx) and not a
redirect libcurl follows (`finalHead`).

## Contract

- `fetchAsync`/`fetchBytesAsync`: as `fetch`/`fetchBytes`; a 4xx/5xx is an
  answer, not an error. A text body is cut at its first NUL, like the
  synchronous client.
- Giving the task up (a `race` it lost, `timeoutAt`) ends the transfer and
  closes the connection.
- `streamAsync`: the task ends when the head is there; the body is not read
  until `nextChunk` is called (a server that sends faster waits on TCP). A
  transfer that fails on the way is `Left` from `nextChunk` after the bytes
  that came before it, not an end.
- `closeStream` when done, unless `nextChunk` has given the end or an error
  (it closes then). It does nothing the second time, and `nextChunk` after it
  gives the end. A stream that is dropped without it holds its connection.
- Request errors (a header name that is not a token, a control character in
  a value) are `SetupError`, before anything is sent, as in the synchronous
  client.

## Not done

- No `Expect`-style upload of a body in pieces; a request body is a `String`.
- `Network.Async.HTTP.Stream` and the client inside `Network.Async.HTTP.Proxy`
  still have their own sockets; moving them onto this is the next step
  (`TODO.md`).
- Not for `Network.HTTP.Client.WebAPI` (OAuth2, OpenAI): they keep using the
  synchronous client.

The test is `tests/TestAsyncHTTPClient`: the servers are tasks of the same
scheduler, so it shows that two transfers run at once, that the body arrives
while the server is still sending, and that a given-up transfer closes the
connection.
