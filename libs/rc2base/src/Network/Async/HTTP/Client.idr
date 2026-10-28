||| The asynchronous counterpart of `Network.HTTP.Client`: the same requests and
||| answers, as a `Task` of the scheduler, so that a slow server holds up nothing
||| else. `Network.Async.HTTP.Client.Curl` is the implementation on libcurl. See
||| `doc/async-http-client.md`.
module Network.Async.HTTP.Client

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Network.HTTP.Client

||| An HTTP client for tasks. The answer is complete when the task ends; giving
||| the task up (a `race` it lost, a `timeoutAt`) abandons the transfer.
public export
interface AsyncHTTPClient h where
  ||| `fetch`, as a task: the body as a `String`.
  fetchAsync : h -> FetchRequest -> Task (Either FetchError FetchResponse)
  ||| `fetchBytes`, as a task.
  fetchBytesAsync : h -> FetchRequest -> Task (Either FetchError FetchResponseBytes)

||| The status and the headers of an answer whose body is still coming.
public export
record FetchHead where
  constructor MkFetchHead
  status  : Int
  headers : List (String, String)

||| `GET url`, returning just the body; a non-2xx status becomes `HttpError`.
export
fetchTextAsync : AsyncHTTPClient h => h -> String -> Task (Either FetchError String)
fetchTextAsync http url = do
    Right resp <- fetchAsync http (get url)
        | Left err => pure (Left err)
    pure $ if resp.status >= 200 && resp.status < 300
              then Right resp.body
              else Left (HttpError resp.status)
