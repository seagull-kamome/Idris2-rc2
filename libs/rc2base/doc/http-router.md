# `Network.HTTP.Route`/`Router`: a type-safe route table

## Motivation

`Network.HTTP.Server`'s `Handler` is a single function that has to
`case`-match `req.path`/`req.method` itself -- fine for a handful of
routes, unpleasant (string comparisons, manual segment splitting, no
static check that a captured `:id` actually gets parsed before use)
once there are more than a few. `Network.HTTP.Route` adds a path
pattern type indexed by the types its captures produce, and
`Network.HTTP.Router` an Express-style table on top -- `router` turns
a `List RouteEntry` straight into an ordinary `Handler`, so it plugs
into `serve` with no other change.

## `Route`: a path pattern indexed by its capture types

```idris2
data Route : List Type -> Type where
  End     : Route []
  Fixed   : String -> Route tys -> Route tys
  Capture : (name : String) -> (ty : Type) -> FromSegment ty => Route tys -> Route (ty :: tys)
  Splat   : Route [String]
```

`tys` lists the captured types left to right. `HandlerFor tys` reads
that list off as a curried argument list ending in the ordinary
`Handler`-continuation shape:

```idris2
HandlerFor []          = (Response -> IO ()) -> IO ()
HandlerFor (ty :: tys) = ty -> HandlerFor tys
```

so a route with two captures (`Route [Int, String]`) requires a
handler of type `Int -> String -> (Response -> IO ()) -> IO ()` --
checked at compile time, not discovered by testing.

### Building a route

Two ways to extend a route, and they don't compose the same way:

- `(//)` chains a **fixed literal** in front of an already-built
  `Route`: `"users" // someRoute`.
- `capture`/`splat` **are** route constructors, not something `(//)`
  takes on its right -- `capture name ty rest` builds the route
  directly from its continuation `rest`, so multiple captures nest as
  function calls rather than chaining with `//`:

  ```idris2
  usersShow : Route [Int]
  usersShow = "users" // capture "id" Int end

  postShow : Route [Int, String]
  postShow = "users" // capture "userId" Int ("posts" // capture "slug" String end)
  ```

  `//` and `capture`/`end`/`splat` were deliberately not unified into
  one operator -- doing so would need either a multi-param type class
  dispatching on the left operand's shape (fragile inference, given
  how much of this module already leans on `tys` unification) or
  overloaded string literals for `Fixed`. Not attempted: the nesting
  above is a little noisier for a route with several captures, but
  every route in this project's own test program is two captures deep
  at most.

`splat` (`Route [String]`) captures every remaining segment as one
`/`-joined `String`; it has no continuation to chain further route
onto, so `Route`'s own shape makes "splat must be last" a type-level
fact rather than a runtime check.

### `FromSegment`: parsing one segment

```idris2
interface FromSegment ty where
  fromSegment : String -> Maybe ty
```

`String`, `Int`, `Integer` ship built in; add more instances for
anything else a route needs to capture. Returning `Nothing` doesn't
crash -- it fails that route's match, falling through to the next
`RouteEntry` (and eventually to `router`'s `notFound`) the same as a
literal-segment or method mismatch would.

## `Router`: registering and dispatching

```idris2
routes : List RouteEntry
routes =
  [ get  usersShow (\userId, respond => respond !(text 200 "user #\{show userId}\n"))
  , post ("echo" // end) (\respond => respond !(text 200 "posted\n"))
  ]

main : IO ()
main = serve 8080 (router notFoundHandler routes)
```

(A `Response` body is a `Data.Buffer`; `Network.HTTP.Server`'s
`Response.text`/`bytes`/... build one -- see that module's doc.)

`router` tries each `RouteEntry` **in registration order** and
dispatches to the first whose method and path both match -- no
specificity-based reordering (a more specific literal route isn't
automatically preferred over an earlier, more general `capture`/
`splat` one covering the same path shape). Put more specific routes
first if that matters for a given route table.

`RouteEntry` erases its route's own `tys` (`{0 tys : List Type}`) so
routes of different shapes can share one plain `List RouteEntry` --
`get`/`post`/`put`/`delete`/`patch` build one each.

A matched route's `HandlerFor` handler is only handed the capture
values and the `respond` continuation -- not `Network.HTTP.Server`'s
auto-implicit `ServerCtx` -- so it can't call `stop`. Only the
`notFound` argument (a full `Handler`) and any hand-written `Handler`
you compose alongside `router` can stop the loop; give a route table
that needs a shutdown endpoint a plain fall-through handler that checks
for it before delegating to `router`.

## Splitting the path: one pass, not repeated substr calls

`splitPath` (in `Network.HTTP.Route`) is `Data.String.split (== '/')`
plus a filter dropping empty segments (from a leading, trailing, or
doubled `/`) -- `split` itself unpacks the path once and walks the
resulting `List Char` in a single pass (`Data.List.split`'s own
`break`-then-recurse-on-the-remainder shape), so the path is scanned
once regardless of how many segments or `Route`s are checked against
it, rather than re-scanned per candidate route or per `strSubstr` call.
`pathOnly` strips a trailing `?...` query string (one `break`) before
`splitPath` ever sees the path -- `Request.path` itself carries the
query string through verbatim, see `Network.HTTP.Server`'s own doc
comment.

## Known limitations

- **No query-string parsing.** `pathOnly` only separates the query
  string from the path; nothing here parses `key=value&...` pairs or
  hands them to a handler in typed form, by design. A handler that
  needs query parameters pulls them itself with `Network.URL`'s
  `parseQuery` (over the `?...` part of `req.path`).
- **No route-specificity ordering** -- see "Registering and
  dispatching" above.
- **An unrecognized HTTP method string** (anything `Method`'s
  `methodFromString` doesn't cover -- non-standard verbs, typos) goes
  straight to `notFound`, indistinguishable from a genuinely unmatched
  path. Fine for this router's own scope (a fixed, small set of
  standard methods); a real `405 Method Not Allowed` (matching the
  path but not the method) isn't implemented.

Verified end-to-end (compiled with `--cg rc2`, exercised with `curl`):
a single `Int` capture, two captures (`Int` + `String`) via nesting, a
trailing `splat`, method-based dispatch (a `POST`-only route 404s under
`GET`), a capture whose `FromSegment` parse fails (404, not a crash),
and a query string left intact on an otherwise-matching path.
