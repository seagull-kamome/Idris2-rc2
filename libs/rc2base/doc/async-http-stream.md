# `Network.Async.HTTP.Stream`: reading an answer as it arrives

An HTTP client for answers that come in pieces over a long time: server-sent
events (`text/event-stream`), as a language model sends its reply a word at a
time. It is the SSE reader on `Network.HTTP.Client.Curl.Async`
(`doc/async-http-client.md`): libcurl, as a task of the scheduler, so a slow
server holds up nothing else and a program that is waiting for the next event can
wait for other things too (a terminal, a timer). `https`, host names, IPv6,
redirects and the framing of the body (chunked, of a given length, until the
connection closes) are libcurl's.

```idris2
r <- streamPostUrl "http://192.168.3.82:1234/v1/chat/completions"
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

- `streamPostUrl url headers body` sends the request (`Accept: text/event-stream`
  and `Cache-Control: no-cache` first, then `headers`, which may replace them; the
  `Content-Length` of the UTF-8 bytes of `body`) and reads the head of the answer. A
  status outside 200..299 is `Left (HttpStatus status text)`, the text being what the
  body said in three seconds, up to 300 characters, its lines joined with a blank.
  CR and LF are not allowed in `url` and the headers (`SendFailed`, before anything
  is sent). If the task is given up before the head is read, the transfer is ended.
  `streamPost addr port host path headers body` is the same for an IPv4 address,
  with `Host` as `host` says.
- The transfer has 30 seconds to connect and no other limit (`CurlOptions` with the
  low-speed abort off): a model may think for minutes before its first word.
- `nextEvent` waits for the next event. An event is the lines up to a blank line:
  `data:` lines (joined with a line end in `payload`) and an optional `event:` name
  (an empty one is none). Comments (`:`) and the other fields (`id`, `retry`) are
  passed over; there is no `Last-Event-ID` and no reconnection. A line ends with
  `\n`, `\r\n` or `\r`; a byte order mark at the start of the body is dropped. At the
  end of the body an event that has data but no blank line after it is given too;
  then `Nothing`.
- A body that libcurl finds cut short (a length it did not reach, a chunked body
  that did not end) is an error (`RecvFailed` with libcurl's message), not an end;
  so is a line of the body over 1 MiB (`BadAnswer`). After such an error the stream
  cannot be read any more.
- The text is decoded from UTF-8 line by line, so a character cut by the
  boundary of two reads is whole in its line.
- The stream belongs to one task at a time. It keeps its state in itself, so a
  program may read an event in one task and the next in another (`RunTaskAs` of
  `termui`, one event per task, is how a terminal program gets each event as a
  message). What `nextEvent` reads is decoded and split into lines in the step that
  takes it from libcurl (`nextChunkWith`), so a task given up while it waits loses
  nothing it has read; the stream is then still readable, if the same task is not
  running. `closeStream` may be called again.

A stream that is dropped without `closeStream` keeps its connection until the
program ends. The body of the transfer is kept in memory until it is closed
(`doc/async-http-client.md`).

The pure parts are exported for tests: `splitLines` and `feedSse`/`sseFlush`.

Test: `tests/TestAsyncHTTPStream` (a server task sends the answer in pieces while
the client reads the events: they arrive while the server is still sending).

## The chat completions API, streaming

`Network.HTTP.Client.WebAPI.AI.OpenAIStream` is the use that `Stream` was made for:
the `"stream": true` form of OpenAI's chat completions API, which LM Studio,
llama.cpp's llama-server, Ollama and the cloud services serve.

```idris2
opened <- chatStream endpoint (chatRequest "model" [MkMessage User "hello"])   -- Task (Either ApiError ChatStream)
...
d <- nextDelta chat      -- Task (Either ApiError (Maybe Delta)); Nothing: the reply is complete
...                      -- d.content, d.reasoning, d.finish
closeChat chat
```

- `Endpoint` and `ChatRequest` are those of `OpenAI.chat`. The `baseUrl` is
  `http://host[:port][/prefix]` or the same with `https` (`endpointUrl`, which also
  takes a trailing slash off); a query, a fragment and credentials in the URL are an
  error (they would be dropped; the key goes in `authHeaders`), and so is a port that
  is not 1 to 65535.
- A `Delta` has the next piece of the answer (`content`), of the thought of a model
  that thinks first (`reasoning`, from `reasoning_content` or `reasoning`) and the
  reason the reply ended (`finish`). Events that carry none of them (the role, the
  usage) are passed over; `[DONE]` or the end of the body ends the reply.
- Only the first choice is read (the one with `index` 0 or none): `ChatRequest` has no
  `n`, and the others of a server that sends more would be other replies.
- A status outside 200..299 is `HttpStatus` with the `error.message` of the body. An
  `error` that is not null in the data of an event (`{"error": {"message": ..}}`,
  `{"error": "text"}`, or the JSON of it) is `DecodeError` with its message: the
  reply failed in the middle, which `ApiError` has no better name for.
- `nextDelta` returns `Right Nothing` at `[DONE]` and also when the body ends without
  it; a server that closes the connection in the middle of a reply and sent no length
  looks the same (libcurl can only tell it for a chunked body or one with a length).
  Call `closeChat` after the last `nextDelta`, an error included.
- `Language.JSON` reads the lower case digits of a `\uXXXX` escape wrong and does not
  join a pair of surrogates; the data of an event is rewritten before it is parsed (a
  server that escapes non-ASCII text, like Python's `json.dumps`, writes both).

Test: `tests/TestOpenAIStream` (a server task that answers the way LM Studio does).
