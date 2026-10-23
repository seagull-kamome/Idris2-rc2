# Static files, CGI and a reverse proxy behind `Network.Async.HTTP.Router`

`Network.Async.HTTP.Router.router` takes a route table (`get`, `post`, ...) whose
handlers give a `Task Response` and make a `Handler` of it (see `http-router.md`
for the patterns). A route handler is given only the captures of its path, not the
`Request`, so it cannot serve "everything below `/static`" or hand a request body
to a program. Three `Handler` transformers do that (`static`, `cgi`, `proxy`), and the router's `notFound`
argument is where they plug in:

```idris2
handler : Handler
handler =
  static "/static" "public"
    (cgi "/cgi-bin" "cgi"
      (proxy "/api" (IPv4Addr 127 0 0 1) 9000
        (router notFoundHandler routes)))
```

A request below `/static` is answered with a file, one below `/cgi-bin` by a
program, one below `/api` by another HTTP server, and anything else goes on to the next `Handler`, at last to `router`,
which tries the routes and then `notFoundHandler`. The prefixes are tried first,
so a route under them is never reached; to try the routes first, put the
transformers inside the router's `notFound` argument instead:
`router (static ... (cgi ... notFoundHandler)) routes`.
The prefix is matched by whole segments (`Network.HTTP.Route.segmentsUnder`):
`/static` is a prefix of `/static` and `/static/a`, not of `/staticx`.

## `Network.Async.HTTP.Static`

`static {options} mountAt root next`:

- Only `GET` and `HEAD` (405 with `Allow` otherwise). The segments after the prefix
  are percent-decoded and added to `root`; a segment that is empty, `.`, `..` or
  holds a `/` or NUL (`%2e%2e`, `%2f` too) makes the answer 404. Symbolic links are
  followed, so what a link in `root` points to can be reached.
- A directory is answered with its `indexFile` (default `index.html`); without the
  trailing `/` in the request it is redirected (301) to the one with it, so that
  relative links in the page work.
- `Content-Type` comes from the extension (`mimeType`), `ETag` from the size and the
  time of modification; `If-None-Match` with it is answered with 304.
  `cacheControl` adds a `Cache-Control`.
- The file is read into a buffer of its size (from `stat`), `chunkBytes` at a time
  (default 256 KiB), each read a `blocking` step of its own with `pread`: a large
  file does not hold a worker thread (or, with none, the scheduler) for the whole
  read. The body is still held in memory whole, so a file over `maxFileBytes`
  (default 16 MiB) is answered with 500. A file that has become shorter than its
  `stat` size, or cannot be read, is 500 too. No `Range`, no `If-Modified-Since`,
  no streaming (`TODO.md`).

## `Network.Async.HTTP.CGI`

`cgi {options} mountAt dir next` runs `dir/<first segment after the prefix>`, which
has to be a regular file with the execute permission (else 404). The rest of the
path is `PATH_INFO`. RFC 3875 variables: `GATEWAY_INTERFACE`, `SERVER_PROTOCOL`,
`SERVER_SOFTWARE`, `SERVER_NAME`, `SERVER_PORT` (both from `options`),
`REQUEST_METHOD`, `SCRIPT_NAME`, `PATH_INFO`, `QUERY_STRING`, `CONTENT_LENGTH`,
`CONTENT_TYPE` and `HTTP_*` for the other headers except `Proxy` (httpoxy). The
program gets no environment of ours, only `options.environment` (empty by default: no `PATH` either, a program that
needs one is given it there, e.g. `environment := [("PATH", "/usr/bin:/bin")]`)
and these. The request body is its standard input; its standard error is ours.

- The process is started with `posix_spawn` (`System.Posix.Spawn`), which is safe
  with several threads and passes on no descriptor but 0 and 1 (the client's
  socket and the listener stay out of the program). `cgi` makes the process
  ignore SIGPIPE (`ignoreSigpipe`), the program has the default action.
  The program starts with `dir` as its working directory (`posix_spawn_file_actions_addchdir_np`, glibc 2.29 or later).
- Both pipes are non-blocking and waited for on the scheduler's epoll
  (`awaitReadable`/`awaitWritable`), the end of the program with a `pidfd`
  (Linux 5.3), so a slow program holds up only its own connection. The body is
  written while the output is read, so a program that answers before it has read
  all its input does not stall.
- The output is a head, an empty line (CRLF or LF) and a body. `Status: 404 ...`
  sets the status; `Location` without it gives 302. A head with neither
  `Content-Type` nor `Location`, no head at all, or more than `maxOutputBytes`
  (default 16 MiB) is 502. `Content-Length`, `Connection` and `Transfer-Encoding`
  of the program are dropped; the server frames the answer. The whole output is
  collected before the answer starts (no streaming, no `nph-` scripts).
- After `timeoutMs` (default 30 s, from the start to the end of the program) the
  program is killed with SIGKILL and reaped, and the answer is 504. A connection
  that is given up while the program runs kills it too (`finally`).

Build programs that use `cgi` with `IDRIS2_CFLAGS=-D_GNU_SOURCE` (glibc hides
`posix_spawn_file_actions_addclosefrom_np` otherwise; glibc 2.34 or later).


## `Network.Async.HTTP.Proxy`

`proxy {options} mountAt upstream port next` forwards the requests at or below
`mountAt` to the HTTP server at the IPv4 address `upstream` and `port` (a host name
would need a blocking lookup: `EAFNOSUPPORT`, so 502), and gives its answer back.

- The path below `mountAt` is asked for (`/api/users?x=1` is `/users?x=1`); with
  `stripMount = False` the path as it is. The method and the body go as they are
  (`Content-Length` set again); `HEAD` is asked as `GET`, so that the
  `Content-Length` the client sees is right (the server leaves the body out).
- The request is HTTP/1.0 with no keep-alive: the server answers without chunks and
  the answer ends with its connection, so the answer needs no framing of its own.
  A new connection per request, no pooling.
- Headers: `Host` is the server's own (`hostHeader` to change it) and the original
  one goes in `X-Forwarded-Host` (one the client sent is replaced, not passed on).
  The hop-by-hop headers (`Connection`, `Keep-Alive`, `Transfer-Encoding`, `TE`,
  `Trailer`, `Upgrade`, `Proxy-*`) and `Expect` are not passed on, in either
  direction; `Content-Length` of the answer is set again from the body. The names of
  the headers of the answer are in lower case, as the parser gives them; repeated
  ones (`Set-Cookie`) stay repeated.
- The exchange is tasks on the scheduler (`connect`, `sendAll`, `recv` of
  `Network.Async`), so a slow server holds up only the connection of its request.
  The socket is closed when the exchange ends or is given up. After `timeoutMs`
  (default 30 s, from the connect to the end of the answer) the answer is 504.
- 502 when the server cannot be reached, resets the connection, answers with no
  proper head or status, an answer shorter than its `Content-Length`, or more than
  `maxResponseBytes` (default 16 MiB). The answer is held whole: no streaming, no
  `Upgrade` (WebSocket), no `100-continue`, and no `X-Forwarded-For` (the handler
  does not know the address of the client).

Tests: `tests/TestAsyncHTTPStaticCGI`, `tests/TestAsyncHTTPProxy`.
