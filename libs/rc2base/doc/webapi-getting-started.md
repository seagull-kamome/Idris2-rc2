# Getting started with the WebAPI clients

`Network.HTTP.Client.WebAPI.*` talks to Claude, Gemini and llama.cpp
through their OpenAI-compatible chat API, and can log in to Google with
OAuth 2.0. This page covers building a program with it, getting
credentials for each service, and a first call. The design is explained
in `http-client.md`.

## 1. Build

The clients are part of `rc2base`, so there is nothing else to install
(`rc2base`'s own `verify.sh` installs it). A program needs
`-p rc2base -p contrib -p network` and libcurl's development files and
library on the compiler's search path:

```sh
source env.sh
export IDRIS2_LDFLAGS="$(pkg-config --libs-only-L libcurl)"
export LD_LIBRARY_PATH="$(pkg-config --variable=libdir libcurl):${LD_LIBRARY_PATH:-}"
rc2/build/exec/idris2-rc2 --cg rc2 -p rc2base -p contrib -p network -o chat libs/rc2base/examples/WebAPIChat.idr
```

Compiling a program that uses the WebAPI modules takes a few minutes
and several GB of memory; under `ulimit -v 12000000` it can abort with
"out of memory". Type-checking alone (`idris2 --check`) is cheap.

## 2. A first call

Every call takes the HTTP client as its first argument; `curlClient`
(from `Network.HTTP.Client.Curl`) is the libcurl one.

```idris
import Data.Maybe

import Network.HTTP.Client.Curl
import Network.HTTP.Client.WebAPI.AI.OpenAI
import Network.HTTP.Client.WebAPI.AI.Providers

main : IO ()
main = do
    Right ep <- claudeFromEnv
        | Left e => putStrLn e
    Right r <- chat curlClient ep (chatRequest "claude-sonnet-5" [MkMessage User "Hello"])
        | Left e => printLn e
    putStrLn (fromMaybe "" (reply r))
```

Any `Endpoint` below works in place of `claudeFromEnv`. Set optional
fields by record update, e.g.
`{ maxTokens := Just 1024, temperature := Just 0.2 } (chatRequest ...)`.

`examples/WebAPIChat.idr` does the same from the command line:

```sh
./build/exec/chat claude claude-sonnet-5 "Say hello"
./build/exec/chat gemini gemini-3-flash "Say hello"
./build/exec/chat llama http://localhost:8080/v1 any-model "Say hello"
```

## 3. Claude: an API key

1. Sign in to the Claude Console (<https://console.anthropic.com/>).
2. Open **Settings → API keys** and create a key.
3. Put it in `ANTHROPIC_API_KEY`, or pass it to `claude` directly.

Claude has no OAuth sign-in for third-party programs, so an API key is
the only method here. Model names are listed in Anthropic's
documentation, under "Models overview".

## 4. Gemini

### 4a. An API key

1. Open Google AI Studio (<https://aistudio.google.com/>).
2. Choose **Get API key** and create a key.
3. Put it in `GEMINI_API_KEY`, or pass it to `gemini` directly.

### 4b. OAuth 2.0

Use this instead of an API key when calls should run as your Google
account, for example under an organization's policy. It takes a one-time
setup in Google Cloud.

**One-time setup in the Google Cloud console**
(<https://console.cloud.google.com/>):

1. Create a project, or pick an existing one. Note its **project ID**.
2. **APIs & Services → Library**: enable the
   **Generative Language API**.
3. **APIs & Services → OAuth consent screen** (Google Auth Platform):
   - User type **External** (or **Internal** in a Workspace
     organization).
   - Fill in the app name and your e-mail address.
   - Under **Audience**, while the app is in **Testing**, add your own
     Google account as a **test user**. Only test users can log in.
4. **APIs & Services → Credentials → Create credentials → OAuth client
   ID**:
   - Application type **Desktop app**.
   - Download or copy the **client ID** and **client secret**.

The client secret of a desktop app is not really secret: Google expects
it to ship inside installed programs. PKCE protects the login instead.
Still, keep it out of public repositories.

**Logging in**

```sh
export GOOGLE_CLIENT_ID=....apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
rc2/build/exec/idris2-rc2 --cg rc2 -p rc2base -p contrib -p network -o login libs/rc2base/examples/WebAPILogin.idr
./build/exec/login
```

The program prints a URL. Open it in a browser, choose your account and
allow access. Then one of two things happens:

- **The browser shows "Authorization received".** The program was
  listening on `127.0.0.1` and got the answer by itself. This is the
  normal case when the browser runs on the same machine.
- **The browser shows a connection error** (for example when the
  program runs over SSH, in a container, or in a sandbox that can't
  listen). Copy the full address from the browser's address bar, which
  starts with `http://127.0.0.1:` and contains `code=`, and paste it
  into the program's terminal.

Either way the program saves `gemini-token.json`, readable only by you.
It holds a refresh token, so treat it like a password. Later calls
refresh the access token by themselves; log in again only when Google
revokes the refresh token. While the consent screen is in **Testing**,
Google expires refresh tokens after 7 days.

**Calling Gemini with the token**

```sh
export GOOGLE_CLOUD_PROJECT=your-project-id
./build/exec/chat gemini-oauth gemini-3-flash "Say hello"
```

In code:

```idris
let c  = google clientId clientSecret geminiScopes
    ep = geminiOAuth curlClient c "gemini-token.json" projectId
```

`projectId` is sent as `x-goog-user-project`, the project billed for
the calls.

## 5. llama.cpp (and other local servers)

Start `llama-server` (or LM Studio, Ollama, vLLM: anything with an
OpenAI-compatible `/v1/chat/completions`) and point `llama` at its
`/v1` URL:

```idris
llama "http://localhost:8080/v1" Nothing
```

Pass `Just key` only if the server was started with `--api-key`. The
command-line example reads it from `LLAMA_API_KEY`. `llama-server`
ignores the model name; other servers need one of theirs (see their
`/v1/models`).

## Errors

`chat` returns `Left` with one of:

| Constructor | Meaning |
|---|---|
| `AuthError` | No usable credentials: a missing token file, a failed refresh |
| `TransportError` | The request didn't complete: setup, DNS, connection, TLS |
| `HttpStatus` | The service answered with an error; the text is its message |
| `DecodeError` | The service answered 2xx with something unexpected |
