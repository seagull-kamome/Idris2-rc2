# HTTP client: `Network.HTTP.Client.Curl` and `Network.HTTP.Client.WebAPI`

Both families came from the standalone `idris2-curl` package and now
live in rc2base, so they are rc2-only like the rest of the library.
`Network.HTTP.Server`/`Router` (see `http-server.md`, `http-router.md`)
are the server side.

## Modules

| Module | Role |
|---|---|
| `Network.HTTP.Client.Curl.Types` | wrappers for libcurl's integer codes (`CURLcode`, `CURLINFO`, ...) and constants |
| `Network.HTTP.Client.Curl.Raw` | one `%foreign` per libcurl function plus thin `HasIO` wrappers (NULL becomes `Maybe`, codes become the `Types` wrappers) |
| `Network.HTTP.Client.Curl.Fetch` | a JS `fetch()`-shaped layer: `fetch`, `fetchBytes`, `fetchText`, `get`/`post`/`request`, `FetchError` (`CurlError`, `SetupError`, `HttpError`) |
| `Network.HTTP.Client.Curl.TextBuffer` | `curlEasyPerformToTextBuffer`, capturing a body into a `Data.TextBuffer` |
| `Network.HTTP.Client.WebAPI.JSON` | JSON encoding (`render`) for the clients below |
| `Network.HTTP.Client.WebAPI.AI.OpenAI` / `.Providers` | one OpenAI-compatible chat client; each service (Claude, Gemini, llama.cpp) is only an `Endpoint` |
| `Network.HTTP.Client.WebAPI.Auth.OAuth2` / `.PKCE` | OAuth 2.0 authorization code flow with PKCE and a loopback redirect, token refresh, token file |

A program using them needs `-p rc2base -p contrib -p network` and
libcurl's development files and library on the compiler's search path.

## Design notes

**No C shim.** Output pointers and C structs go through
`System.FFI.Struct`: out-parameters are one-field `Struct` cells
(`CellI64`, `CellPtr`, ...), and libcurl's bare-tag structs
(`curl_header`, `curl_slist`) get private struct names that spell out
the real layout, so the `externStruct` directive is not needed. A
`Struct` read must not be reordered after the `free` of its memory:
`getField` is pure, so read it in a way the compiler cannot move.

**Body capture without `CURLOPT_WRITEFUNCTION`.** An Idris function
cannot be passed to C as a function pointer. Instead,
`CURLOPT_WRITEDATA` is pointed at a libc `open_memstream` `FILE *`,
which redirects libcurl's default writer into a growable heap buffer.
After the transfer: `fclose`, then `memcpy` into a `Buffer`, a `String`
(one copy; an embedded NUL cuts it short) or, via
`Data.TextBuffer.fromRawUtf8`, a `TextBuffer`. Limitation:
`CURLOPT_WRITEDATA` is left pointing at the closed stream, so set it
again (or reset the handle) before a later `curlEasyPerform` on the
same handle without capture. Streaming `WRITEFUNCTION`,
`HEADERFUNCTION` and `READFUNCTION` are not bound.

**Sentinel values.** Do not pass a negative or all-ones sentinel as an
`Int` argument; pass the real value instead. `curlMimeData` passes the
string's UTF-8 byte length rather than `CURL_ZERO_TERMINATED`.

**WebAPI uses only `Fetch`.** Every HTTP call goes through
`Network.HTTP.Client.Curl.Fetch`, never `Raw`, so the HTTP layer can be
swapped by changing only those calls. The public types do not mention
curl: a transfer failure reaches the caller as `TransportError String`.
`fetch` is `partial`, hence `chat`, `refresh`, `accessToken` and `login`
are too.

**One OpenAI-compatible client.** Claude, Gemini and llama.cpp all
serve `POST /chat/completions` with `Authorization: Bearer`. An
`Endpoint` is a base URL plus an `IO` action producing the auth
headers; the action runs before every request, which is where an OAuth
token refreshes itself.

**JSON.** Parsing uses contrib's `Language.JSON`; encoding is our own
`render`, because contrib prints every number as a `Double` (`1024.0`),
which APIs with strict integer fields (`max_tokens`) reject.

**OAuth 2.0.** Google's device flow only allows a short list of scopes
(Gemini's are not among them), so `login` uses the authorization code
flow for native apps (RFC 8252) with PKCE (RFC 7636):

- the redirect goes to `http://127.0.0.1:<random port in 49152-65535>`
  (up to five tries);
- `login` waits with `poll(2)` on the listening socket and stdin, so
  the user can paste the redirect address when the browser cannot reach
  this machine;
- `state` is checked, and verifier and state come from `/dev/urandom`;
- SHA-256 is written in Idris (`Auth.PKCE`) rather than binding
  libcrypto to hash 43 bytes;
- tokens are saved as JSON with mode 0600 (created empty, restricted,
  then written); a refresh response usually carries no refresh token,
  so the old one is kept.

## Credentials

`Providers` reads keys from the environment (`fromEnv`); the OAuth
client id and secret come from `GOOGLE_CLIENT_ID` and
`GOOGLE_CLIENT_SECRET`. Keep them out of public repositories.

## Tests

All three run without outbound network and are listed in
`tests/verify.sh`. `verify.sh` gives every test an open, silent stdin
(a FIFO), because `login` polls stdin, and masks the random
authorization URL that `login` prints.

- `TestCurl`: the `Curl` family. Local transfers use a `file://` URL on
  a file the test writes; HTTP transfers go to a `Network.HTTP.Server`
  forked inside the test. It needs libcurl's headers; `verify.sh`
  prints `SKIP` when `gcc` cannot find `curl/curl.h`.
- `TestWebAPIPure`: SHA-256 / base64url / PKCE known answers, JSON
  rendering, chat and token JSON, URL and form encoding.
- `TestWebAPI`: `chat` and `login` against a mock API and token
  endpoint (again a forked `Network.HTTP.Server`). The mock checks the
  PKCE code verifier against the challenge it saw on `/auth`. The
  "browser" is a thread started from `Client.onAuthUrl`, a hook called
  with the authorization URL and the redirect URI once `login` has
  printed them. Covered: a reply, a rejected key, no key, an
  unreachable server; login by loopback redirect, the token file
  (valid, expired, revoked refresh token), a refused login and a wrong
  code. Not covered: the paste-the-address path, which reads stdin.
