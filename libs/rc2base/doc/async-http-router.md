# Static files and CGI behind `Network.Async.HTTP.Router`

`Network.Async.HTTP.Router.router` takes a route table (`get`, `post`, ...) whose
handlers give a `Task Response` and make a `Handler` of it (see `http-router.md`
for the patterns). A route handler is given only the captures of its path, not the
`Request`, so it cannot serve "everything below `/static`" or hand a request body
to a program. Two `Handler` transformers do that, and the router's `notFound`
argument is where they plug in:

```idris2
handler : Handler
handler =
  static "/static" "public"
    (cgi "/cgi-bin" "cgi"
      (router notFoundHandler routes))
```

A request below `/static` is answered with a file, one below `/cgi-bin` by a
program, and anything else goes on to the next `Handler`, at last to `router`,
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
- The file is read whole, on a worker thread (`blocking`; with no workers, on the
  scheduler's own), and sent as the body. A file over `maxFileBytes` (default 16
  MiB) is answered with 500. No `Range`, no `If-Modified-Since`, no streaming
  (`TODO.md`).

## `Network.Async.HTTP.CGI`

`cgi {options} mountAt dir next` runs `dir/<first segment after the prefix>`, which
has to be a regular file with the execute permission (else 404). The rest of the
path is `PATH_INFO`. RFC 3875 variables: `GATEWAY_INTERFACE`, `SERVER_PROTOCOL`,
`SERVER_SOFTWARE`, `SERVER_NAME`, `SERVER_PORT` (both from `options`),
`REQUEST_METHOD`, `SCRIPT_NAME`, `PATH_INFO`, `QUERY_STRING`, `CONTENT_LENGTH`,
`CONTENT_TYPE` and `HTTP_*` for the other headers except `Proxy` (httpoxy). The
program gets no environment of ours, only `options.environment` (default: `PATH`)
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

Test: `tests/TestAsyncHTTPStaticCGI`.
