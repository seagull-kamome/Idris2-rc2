# `Network.URL`: URL parsing, building, and percent-encoding

## Motivation

`Network.HTTP.Router` deliberately doesn't parse query strings -- it
strips `?...` off before matching path segments and stops there. The
piece it leaves out (query parameters, and the percent-encoding under
them) lives here instead, in a module that has nothing to do with
routing so a plain HTTP client can use it too. Pure Idris, no FFI, no
new dependency.

## Percent-escapes carry UTF-8

`%XX` sequences on the wire are UTF-8 bytes. `percentDecode "%C3%A9"`
reassembles them to `"é"` -- one codepoint -- and `percentEncode "é"`
gives `"%C3%A9"` back. This is right for every backend: rc2's `String`
is UTF-8 on the wire but *codepoint*-wise through `pack`/`unpack`
(`unpack` decodes UTF-8, `pack` re-encodes it -- same as Chez), and the
`%XX` bytes are routed through `Text.Encoding.UTF8` to match. A
malformed or truncated sequence (`%FF`, a lone lead byte) decodes to
U+FFFD, one per bad byte.

`percentDecode "%C3%A9" == "é"` is `True` -- the result and a non-ASCII
source literal are the same codepoints.

## Percent-encoding

```idris
percentDecode : String -> String   -- %XX run -> UTF-8 decode; '+' left alone; a bare '%' kept literal
percentEncode : String -> String   -- every non-`unreserved` byte of the UTF-8 form -> %XX; space -> %20
unreserved    : Char -> Bool       -- RFC 3986: A-Za-z0-9 and - . _ ~
```

`percentEncode` is for a path segment or a fragment. Query keys/values
use the `application/x-www-form-urlencoded` variant internally (space
becomes `+`, a literal `+` becomes `%2B`) -- reachable through
`buildQuery`/`parseQuery`, not exposed on its own.

## Query strings

```idris
parseQuery : String -> List (String, String)   -- "?a=1&b=two+words&c" -> [("a","1"),("b","two words"),("c","")]
buildQuery : List (String, String) -> String   -- inverse; each pair as `k=v`, joined with `&`
```

`parseQuery` tolerates a leading `?`, drops empty (`&&`) segments, and
form-decodes keys and values. `parseQuery . buildQuery` round-trips.

## Whole URLs

```idris
record URL where
  scheme   : Maybe String            -- lowercased; Nothing for a relative reference
  host     : Maybe String            -- Nothing without `//authority`; keeps `[...]` for an IPv6 literal
  port     : Maybe Int
  path     : String                  -- left percent-encoded
  query    : List (String, String)   -- decoded
  fragment : Maybe String            -- decoded

parse  : String -> URL   -- best-effort, always succeeds; not a validator
render : URL -> String   -- reassemble (re-encodes query and fragment; path as-is)
pathSegments : String -> List String   -- split on '/', drop empties, percent-decode each
```

`parse` handles `scheme://[userinfo@]host[:port]/path?query#fragment`
and the degenerate cases: scheme-relative `//host/path`, path-only
`/path?q#f`, an IPv6 host literal `http://[::1]:9000/p`, authority with
no path. `userinfo` is discarded. Anything it can't recognise mostly
ends up in `path`.

`render` isn't guaranteed byte-identical to the string `parse` was
given: `userinfo` is gone, `query` comes back through `buildQuery`
(so `y=t w` renders as `y=t+w`), `fragment` through `percentEncode`.

`path` is kept encoded on purpose -- decoding it would make a `%2F`
inside one segment indistinguishable from a real separator. Use
`pathSegments` to split-and-decode when that's what you want.

## Verified

`tests/TestURL.idr` (in `tests/verify.sh`), under `--cg rc2`: the
percent codec (space, `/`, a trailing `%`, a 2-byte and a 3-byte UTF-8
sequence, a malformed byte -> U+FFFD, encode/decode round-trip),
`parseQuery`/`buildQuery` and their round-trip, `parse` on a full URL /
path-only / scheme-relative / IPv6-host / no-path input, `render`, and
`pathSegments`.
