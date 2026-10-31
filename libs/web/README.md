# web

*[日本語](README.ja.md)*

HTTP for rc2: a libcurl client, an OpenAI-compatible chat client with OAuth 2.0 (PKCE) login, and two HTTP/1.1 servers with routers (one `epoll` event loop, one made of `Control.Task` tasks), plus static files, CGI, a reverse proxy and a URL rewriter for the task server. It was split off `rc2base`; it runs on the tasks of `control-async` (`Control.Task`, `Network.Async`). `rc2base` keeps the general parts it is built on (`Network.RC2`, `Network.URL`, `System.Linux.Epoll`, ...). Like `rc2base` it is rc2-only (the `%foreign` bindings are C-only).

A program uses it with `-p web -p control-async -p rc2base -p contrib`; neither package needs the `network` package (addresses are rc2base's `Network.Address.SocketAddress`, named like the `network` package's but with a 16-bit `Port`, sockets are `System.Posix.Socket` file descriptors). The client needs libcurl's development files and library on the compiler's search path. `web` has one small C shim of its own, `support/c/idris2rc2_web_curl_util.c` (`curl_global_init` once per process), built into `libidris2rc2web.a` and installed into the package's `lib` directory like `rc2base`'s (see `libs/rc2base/README.md`, "Native library install location").

## Modules

| Module | What it is |
| --- | --- |
| `Network.HTTP.Message` | `Request`, `Response` and the request parser, shared by the HTTP servers |
| `Network.HTTP.Server` | minimal single-threaded, `epoll`-driven HTTP/1.1 server -- see below |
| `Network.HTTP.Route`/`Router` | type-safe route table on top of `Network.HTTP.Server` -- see below |
| `Network.Async.HTTP.Server`/`Router` | an HTTP/1.1 server and route table made of tasks (handlers give a `Task Response`) -- see `doc/async-http-server.md`; `Network.Async.HTTP.Static`/`CGI`/`Proxy`/`Rewrite` add static files, external CGI programs, a reverse proxy (as `Handler` transformers or as routes of `routerWith`) and a URL rewriter to its router, see `doc/async-http-router.md`; `Network.Async.HTTP.Stream` reads a chunked or event-stream body, see `doc/async-http-stream.md` |
| `Network.HTTP.Client` | `HTTPClient`, a `fetch()`-shaped client interface -- see `doc/http-client.md` |
| `Network.Async.HTTP.Client` | `AsyncHTTPClient`, the client as a `Task`; `Network.Async.HTTP.Client.Curl` is the libcurl implementation (`fetchAsync`, `streamAsync`) -- see `doc/async-http-client.md` |
| `Network.HTTP.Client.Curl.*` | the libcurl client (`Curl`: `curlClient`), bindings (`Raw`, `Types`), `TextBuffer` capture -- see `doc/http-client.md` |
| `Network.HTTP.Client.WebAPI.*` | OpenAI-compatible chat client, OAuth 2.0 (PKCE) login -- see `doc/http-client.md` and `doc/webapi-getting-started.md` |

`examples/` holds small programs (see `doc/http-client.md`), and `bench/` compares the two servers with `wrk` (`bench/bench.sh`).

## Tests

Same layout as `libs/rc2base/tests`: one directory per test under `tests/<TestName>/` with `<TestName>.idr` and `<TestName>.expected`, listed in the `TESTS` array of `tests/verify.sh`. The script rebuilds `support/c`, type-checks and installs the package, then builds and runs every test with `-p web -p control-async -p rc2base [-p <extra>...]`. `rc2base` and `control-async` have to be installed first (their `tests/verify.sh` do it). `TestCurl`, `TestWebAPI` and `TestAsyncHTTPClient` need libcurl's headers and are skipped (with a `SKIP` line) when `gcc` cannot find `curl/curl.h`. `TestAsyncHTTPStaticCGI` finds its `public/` and `cgi/` directories from the path of the executable, so run it by its full path.

## `Network.HTTP.Server`: a minimal event-driven HTTP server

A single-threaded, `epoll`-driven HTTP/1.1 server (`System.Linux.Epoll`
for the raw event loop, `Network.RC2` for binary-safe buffer socket IO,
`Network.HTTP.Server` for the HTTP logic on top). One call starts it;
each request answers through a continuation rather than a return value,
so a `Handler` can respond synchronously, stash the continuation and
answer later (from another thread, even), or `stop` the loop. Request
and response bodies are raw `Data.Buffer` bytes -- binary safe. The
`Response.*` constructors (`text`/`html`/`json`/`ok`/`notFound`/
`bytes`/... -- call bare, or `Response.`-qualified on a name clash)
build one; each takes an optional leading implicit `headers`.

```idris2
import Language.JSON
import Network.HTTP.Server

handler : Handler
handler req respond =
  case req.path of
    "/hello" => respond !(text 200 "hello\n")
    "/echo"  => respond (MkResponse 200 [] req.body)          -- raw bytes
    "/img"   => respond (bytes 200 "image/png" pngBuf)
    "/api"   => respond !(json 200 (JObject [("ok", JBoolean True)]))
    _        => respond !(notFound "not found\n")

main : IO ()
main = serve 8080 handler   -- binds 127.0.0.1:8080, runs until `stop`
```

Linux-only (`epoll`); supports request-line + headers +
`Content-Length` body and keep-alive, a chunked request body (decoded) but not a chunked response/HTTP/1.0/TLS/
pipelining response ordering. The read accumulator is capped
(`serve`'s `maxRequestBytes`, default 8 MiB); an over-large request is
dropped without a response. See `doc/http-server.md` for the full
design and, importantly, a correctness pitfall this module's own test
program ran into: a top-level `unsafePerformIO`'d `IORef` is **not**
memoized under `--cg rc2` (nor upstream's own `--cg refc`) the way it
is under `--cg chez` -- every reference gets its own fresh `IORef`
instead of sharing one, silently. Never use that pattern to share
state across a `Handler`; create the `IORef` in `main` and pass it in
instead.

## `Network.HTTP.Route`/`Router`: a type-safe route table

A path pattern indexed by the types its captures produce, plus an
Express-style route table on top -- `router` builds a plain `Handler`
straight from a `List RouteEntry`, so it drops into `serve` with no
other change:

```idris2
import Network.HTTP.Route
import Network.HTTP.Router
import Network.HTTP.Server

usersShow : Route [Int]
usersShow = "users" // capture "id" Int end

routes : List RouteEntry
routes = [ get usersShow (\userId, respond => respond (MkResponse 200 [] "user #\{show userId}\n")) ]

main : IO ()
main = serve 8080 (router notFoundHandler routes)
```

A route with `n` captures requires a handler of type `ty1 -> ... ->
tyn -> (Response -> IO ()) -> IO ()`, checked at compile time; a
`FromSegment` parse failure (or a literal-segment/method mismatch)
falls through to the next registered route rather than crashing. See
`doc/http-router.md` for the full design, including why `capture`
nests as function calls rather than chaining with `//` the way fixed
segments do, and why path splitting is a single pass over the string
(no repeated `strSubstr` rescans).

