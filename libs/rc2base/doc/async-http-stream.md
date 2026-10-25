# `Network.Async.HTTP.Stream`: reading an answer as it arrives

An HTTP client for answers that come in pieces over a long time: server-sent
events (`text/event-stream`), as a language model sends its reply a word at a
time. `Network.HTTP.Client` (libcurl) gives the body when the answer is complete;
this gives the events as they arrive, from a task of the scheduler
(`Network.Async`), so a slow server holds up nothing else and a program that is
waiting for the next event can wait for other things too (a terminal, a timer).

```idris2
r <- streamPost (IPv4Addr 192 168 3 82) 1234 "192.168.3.82:1234" "/v1/chat/completions"
                [("Content-Type", "application/json")] requestBody
case r of
  Left e => ...                      -- StreamError
  Right (head, stream) => loop stream
  where
    loop s = do
      ev <- nextEvent s              -- Task (Either StreamError (Maybe SseEvent))
      ...                            -- Nothing: the body has ended
-- and closeStream stream when done
```

- `streamPost addr port host path headers body` connects, sends the request
  (`HTTP/1.1`, `Connection: close`, `Accept: text/event-stream`, the `Content-Length`
  of the UTF-8 bytes of `body`) and reads the head of the answer (its lines end with
  `\r\n` or `\n`). A status outside 200..299 is `Left (HttpStatus status text)`, the
  text being what the body said in three seconds, up to 300 characters, its lines
  joined with a blank. CR and LF are not allowed in `host`, `path` and the headers
  (`SendFailed`, before anything is sent). If the task is given up before the head is
  read, the socket is closed.
- `nextEvent` waits for the next event. An event is the lines up to a blank line:
  `data:` lines (joined with a line end in `payload`) and an optional `event:` name
  (an empty one is none). Comments (`:`) and the other fields (`id`, `retry`) are
  passed over; there is no `Last-Event-ID` and no reconnection. A line ends with
  `\n`, `\r\n` or `\r`; a byte order mark at the start of the body is dropped. At the
  end of the body an event that has data but no blank line after it is given too;
  then `Nothing`.
- The body is read as its head says: `Transfer-Encoding: chunked`, a
  `Content-Length`, or until the connection closes. A chunked body or one with a
  length that the connection leaves short is an error (`RecvFailed`), not an end; so
  are a chunk size that is not a number or is over 128 bytes of line, anything but a
  line end after the data of a chunk (`BadAnswer`), and a line of the body over
  1 MiB. After such an error the stream cannot be read any more.
- The text is decoded from UTF-8 line by line, so a character cut by the
  boundary of two reads (or two chunks) is whole in its line.
- The stream belongs to one task at a time (the buffer is shared). It keeps its state
  in itself, so a program may read an event in one task and the next in another
  (`RunTaskAs` of `termui`, one event per task, is how a terminal program gets each
  event as a message). What `nextEvent` reads is decoded and split into lines in one
  step, so a task given up while it waits loses nothing it has read; the stream is
  then still readable, if the same task is not running. `closeStream` is a task
  (`onReactor (close ..)`, as `withSock` does) and may be called again.

Limits: plain `http` to an IPv4 address (`Network.Async.connect` has no host
name lookup; there is no TLS), a head of at most 64 KiB, no redirects, no
`100-continue` (a `1xx` answer is taken for the answer), no limit on the number of
lines of one event. `Host` is the string the caller gives. A stream that is dropped
without `closeStream` keeps its socket until the program ends.

The pure parts are exported for tests and for other framings: `feedChunked`
(the chunk decoder as a state machine over bytes), `splitLines` and
`feedSse`/`sseFlush`.

Test: `tests/TestAsyncHTTPStream` (a server task sends the answer in pieces while
the client reads the events: they arrive while the server is still sending).
