# Static files, CGI, a reverse proxy and a URL rewriter behind `Network.Async.HTTP.Router`

`Network.Async.HTTP.Router.router` takes a route table (`get`, `post`, ...) whose
handlers give a `Task Response` and make a `Handler` of it; `routerWith` does the same
for routes whose handlers are given the `Request` as well as the captures of the path
(`RouteEntryWith`, see `async-http-server.md`; the patterns are those of `http-router.md`).
Static files, CGI programs and a reverse proxy are done in either of two ways, with
the same code behind both.

**As `Handler` transformers** (`static`, `cgi`, `proxy`, and `urlRewrite`), which take
every method under a URL prefix and pass the other requests on to the next `Handler`:

```idris2
handler : Handler
handler =
  urlRewrite rules
    (static "/static" "public"
      (cgi "/cgi-bin" "cgi"
        (proxy "/api" (IPv4Addr 127 0 0 1) 9000
          (router notFoundHandler routes))))
```

A request below `/static` is answered with a file, one below `/cgi-bin` by a
program, one below `/api` by another HTTP server, and anything else goes on to the next
`Handler`, at last to `router`, which tries the routes and then `notFoundHandler`. The
prefixes are tried first, so a route under them is never reached; to try the routes
first, put the transformers inside the router's `notFound` argument instead:
`router (static ... (cgi ... notFoundHandler)) routes`. The prefix is matched by whole
segments (`Network.HTTP.Route.segmentsUnder`): `/static` is a prefix of `/static` and
`/static/a`, not of `/staticx`.

**As routes of `routerWith`**, where the router does the matching of the path and the
method, and the handler is the function the transformer is made of (`serveStatic`,
`runCGI`, `forwardTo`), which takes the rest of the path that `splat` gives (segments
joined with `/`, still percent-encoded) and the request, so the route needs no lambda:

```idris2
routes : List RouteEntryWith
routes =
  [ get  ("assets" // splat)  (serveStatic "public")
  , post ("scripts" // splat) (runCGI "/scripts" "cgi")
  , get  ("api" // splat)     (forwardTo (IPv4Addr 127 0 0 1) 9000)
  , get  ("users" // capture "id" Int end) (\id, req => ...)    -- an ordinary route beside them
  ]

handler : Handler
handler = routerWith notFoundHandler routes
```

Use the routes when the method matters (`serveStatic` answers only `GET`/`HEAD`; a
`HEAD` request goes to the `get` route when there is no `head` route), when a route
should be tried in its place among the others (first match wins), or when the
paths come from the table. Use the transformers for "everything below this prefix, any
method". `runCGI` takes the path of the route (`"/scripts"`) for `SCRIPT_NAME`. A route
does no `..` check of its own on `rest`: `serveStatic`, `runCGI` and `forwardTo` refuse
such a path themselves. The URL rewriter has no route form: it changes the request
before the route is chosen.

## `Network.Async.HTTP.Static`

`static {options} mountAt root next` (or `serveStatic {options} root rest req`):

- Only `GET` and `HEAD` (405 with `Allow` otherwise). The segments after the prefix
  are percent-decoded and added to `root`; a segment that is empty, `.`, `..` or
  holds a `/` or NUL (`%2e%2e`, `%2f` too) makes the answer 404, and so does one that
  starts with `.` (`.git`, `.env`, `.htpasswd`) unless `serveDotfiles` is set. Symbolic
  links are followed, so what a link in `root` points to can be reached, and a file
  replaced between the `stat` and the open is not noticed (the open is
  `O_NONBLOCK`, so a FIFO put in its place does not block it).
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

`cgi {options} mountAt dir next` (or `runCGI {options} mountAt dir rest req`) runs `dir/<first segment after the prefix>`, which
has to be a regular file with the execute permission (else 404). The rest of the
path is `PATH_INFO`. RFC 3875 variables: `GATEWAY_INTERFACE`, `SERVER_PROTOCOL`,
`SERVER_SOFTWARE`, `SERVER_NAME`, `SERVER_PORT` (both from `options`),
`REQUEST_METHOD`, `SCRIPT_NAME`, `PATH_INFO`, `QUERY_STRING`, `CONTENT_LENGTH`,
`CONTENT_TYPE` and `HTTP_*` for the other headers. Not passed: `Proxy` (httpoxy),
`Authorization` (unless `passAuthorization`, RFC 3875, 4.1.18), and a header whose
name has anything but letters, digits and `-` in it (`X_A` would be the same variable
as `X-A`, and `X-A=B` would make a variable `HTTP_X_A` with `B=` in its value). A header
sent more than once is one variable with the values joined by `, `. The program gets
no environment of ours, only `options.environment` (empty by default: no `PATH`
either, a program that needs one is given it there, e.g.
`environment := [("PATH", "/usr/bin:/bin")]`) and these. The request body is its standard input; its standard error is ours.

- The process is started with `posix_spawn` (`System.Posix.Spawn`), which is safe
  with several threads and passes on no descriptor but 0 (the request body), 1 (the
  output) and 2 (our standard error): the client's socket and the listener stay out of
  the program. `cgi` makes the process ignore SIGPIPE (`ignoreSigpipe`); in the program
  every signal has its default action again (not the `SIG_IGN` we set, which `exec`
  keeps), the signal mask is empty (the server may block signals for `signalfd`) and it
  is a process group of its own.
  The program starts with `dir` as its working directory (`posix_spawn_file_actions_addchdir_np`, glibc 2.29 or later).
- Both pipes are non-blocking (if they cannot be made so, it is 502) and waited for on
  the scheduler's epoll (`awaitReadable`/`awaitWritable`), the end of the program with
  a `pidfd` (Linux 5.3; where there is none, by asking `waitpid` every 5 ms), so a slow
  program holds up only its own connection and the scheduler is never blocked by
  the wait. The body is written while the output is read, so a program that answers
  before it has read all its input does not stall; when the output is over (or too
  much) the writer is given up. When the program has ended, what it started is killed
  with its group (`kill (-pid)`), in the step that also reaps it.
- The output is a head, an empty line (CRLF or LF) and a body. `Status: 404 ...`
  sets the status; `Location` without it gives 302. A head with neither
  `Content-Type` nor `Location`, no head at all, or more than `maxOutputBytes`
  (default 16 MiB; exactly that much is fine) is 502, and the program is killed at
  once (it may be stuck writing what nobody reads). `Content-Length`, `Connection` and `Transfer-Encoding`
  of the program are dropped; the server frames the answer. The whole output is
  collected before the answer starts (no streaming, no `nph-` scripts).
- After `timeoutMs` (default 30 s, from the start to the end of the program) the
  program is killed with SIGKILL, with the processes it started (`kill (-pid)`), and
  reaped, and the answer is 504. A connection that is given up while the program
  runs kills it too (`finally`), and the `pidfd` is closed in that case as well. A
  process that does not go at once (an uninterruptible sleep) is reaped by a thread of
  its own, and not waited for on the scheduler.

Build programs that use `cgi` with `IDRIS2_CFLAGS=-D_GNU_SOURCE` (glibc hides
`posix_spawn_file_actions_addclosefrom_np` otherwise; glibc 2.34 or later).


## `Network.Async.HTTP.Proxy`

`proxy {options} mountAt upstream port next` (or `forwardTo {options} upstream port rest req`) forwards the requests at or below
`mountAt` to the HTTP server at the IPv4 address `upstream` and `port` (a host name
would need a blocking lookup: `EAFNOSUPPORT`, so 502), and gives its answer back.

- The path below `mountAt` is asked for (`/api/users?x=1` is `/users?x=1`); with
  `stripMount = False` the path as it is. The method and the body go as they are
  (`Content-Length` set again); `HEAD` is asked as `GET`, so that the
  `Content-Length` the client sees is right (the server leaves the body out).
- The request is HTTP/1.0 with `Connection: close`: the server answers without chunks
  and the answer ends with its connection, so the answer needs no framing of its own.
  A new connection per request, no pooling.
- A request is refused with 400, and not forwarded, if its target does not start with
  `/` (an absolute URI), has a `.` or `..` segment once decoded (`%2e%2e`, `..%2f` and
  `..%5c` too), or if a method, target or header name has a control character in it,
  or a header value one other than HTAB (a CR, LF or NUL would split or cut the message
  the server reads; the others are read differently by one reader and the next).
- Headers: `Host` is the server's own (`hostHeader` to change it) and the original
  one goes in `X-Forwarded-Host`, and `X-Forwarded-Proto: http` is added. The headers
  that say where a request came from (`Forwarded`, `X-Forwarded-For`, `X-Forwarded-Host`,
  `X-Forwarded-Proto`, `X-Forwarded-Port`, `X-Real-IP`) that the client wrote are not
  passed on: a server that trusts them could be told anything. The proxy does not write
  `X-Forwarded-For` itself, as the handler does not know the address of the client.
  A `hostHeader` with a control character is a configuration error (500).
  The hop-by-hop headers (`Connection`, `Keep-Alive`, `Transfer-Encoding`, `TE`,
  `Trailer`, `Upgrade`, `Proxy-*`), the ones `Connection` names, and `Expect` are not
  passed on, in either direction; `Content-Length` of the answer is set again from the body. The names of
  the headers of the answer are in lower case, as the parser gives them; repeated
  ones (`Set-Cookie`) stay repeated.
- The exchange is tasks on the scheduler (`connect`, `sendAllUntil`, `recvUntil` of
  `Network.Async`, which arm no timer for a call that does not block), so a slow server
  holds up only the connection of its request. The answer is read while the request is
  sent, so a server that answers without reading all of the body (413, 401) and closes
  still gives its answer (also when the connection is reset after it), and one that
  fills the connection with its answer does not stall the sending, with no time limit
  too. The socket is closed when the exchange ends or is given up. After `timeoutMs`
  (default 30 s, from the connect to the end of the answer) the answer is 504.
- 502 when the server cannot be reached, resets the connection, answers with no
  proper head (`HTTP/`, a status of three digits from 200 to 599: a `1xx` is not a
  final answer; a `Content-Length` that is not plain digits or is given twice with
  different values, or a `Transfer-Encoding`, which the HTTP/1.0 request should have
  made impossible; a head over `maxHeadBytes`, 64 KiB), an answer shorter than its
  `Content-Length` (or, with none, cut off by an error before the end of the
  connection), or more than `maxResponseBytes` (default 16 MiB; exactly that much is fine). The answer is held whole: no streaming, no
  `Upgrade` (WebSocket) and no `100-continue`.

## `Network.Async.HTTP.Rewrite`

`urlRewrite rules next` changes the path of a request, or answers it with a redirect,
before `next` (a `static`, `cgi`, `proxy` or `router`, or a chain of them) sees it.
Put it first: `urlRewrite rules (static ... (cgi ... (router ...)))`. (It is not called
`rewrite`: that is a keyword.)

```idris2
Right old  <- rule "/old/(.*)"      "/new/\1"           Internal
Right item <- rule "/legacy/([0-9]+)" "/items/\1"      (Redirect 301)
Right ext  <- rule "/docs/(.*)"     "https://example.org/\1" (Redirect 307)
let handler = urlRewrite [old, item, ext] next
```

- `rule pattern template action` compiles a POSIX extended regular expression
  (`Text.Regex.POSIX`, libc) once and checks the template: `Left` for a pattern or
  template that is not valid, a group the pattern does not have, a `Redirect` status
  other than 301, 302, 303, 307 and 308. The template is text with `\1` to `\9` for what
  the groups matched (`\0` all of the path; a group that did not take part is empty)
  and `\\` for a backslash.
- A rule matches when the pattern matches **all** of the path of the request, the query
  string left out and the path as it stands in the request (percent-encoded, so `%2f`
  is not a `/`). `/plain` does not match `/plain/more`; write `/plain(/.*)?` for both.
- The **first** rule that matches is applied, and its result is not matched again, so no
  set of rules loops. A request that no rule matches goes to `next` as it is.
- `Internal` gives `next` a request with the new path: the client does not see it.
  `Redirect status` answers with that status and the new path as `Location`. A query
  string in the template replaces the one of the request, else that stays.
- What the groups caught from the request must not become something else, so the new
  path is checked, and the request answered with 400 if it fails: it starts with one
  `/` (not `//host`, which a browser takes for another host), has no `.` or `..`
  segment (also `%2e%2e`, `..%2f` and `..%5c`), no control character (TAB too: a browser
  drops it from a URL, so `/<TAB>/host` is `//host`), space or backslash. A redirect may
  go to another host only when the template itself starts with `http://` or `https://`,
  and `rule` refuses such a template with a group before the `/` that ends the host
  (`https://example.org\\1` with `@evil.example/` caught is another host). A request whose
  path has a control character in it is 400 too (the regex engine reads a C string).

Tests: `tests/TestAsyncHTTPStaticCGI`, `tests/TestAsyncHTTPProxy` (both also through
`routerWith`), `tests/TestAsyncHTTPRewrite`.
