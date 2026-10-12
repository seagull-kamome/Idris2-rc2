#!/usr/bin/env bash
# Plays the browser for TestWebAPILogin: opens the printed authorization
# URL on the mock, then hands the redirect back three ways -- to the
# loopback listener, pasted into stdin (after one bad paste), and as a
# refusal. The URL itself is random, so it is masked in the output.
#   TestWebAPILogin.sh <binary> <mock base url>
set -u
bin="$1"
base="$2"
work="$(dirname "$bin")/TestWebAPILogin.work"
rm -rf "$work"
mkdir -p "$work"

run() {
  local mode="$1"
  local fifo="$work/$mode.in" out="$work/$mode.out"
  mkfifo "$fifo"
  "$bin" "$base" "$work/$mode.token" < "$fifo" > "$out" 2>&1 &
  local pid=$!
  exec 3> "$fifo"
  local url=
  for _ in $(seq 100); do
    url="$(grep -m1 '^http' "$out")" && break
    sleep 0.1
  done
  if [ -z "$url" ]; then
    echo "no authorization URL printed"
  else
    curl -s -o /dev/null "$url"
    local redirect state
    redirect="$(sed -n 's/.*[?&]redirect_uri=\([^&]*\).*/\1/p' <<< "$url" | sed 's/%3A/:/g; s/%2F/\//g')"
    state="$(sed -n 's/.*[?&]state=\([^&]*\).*/\1/p' <<< "$url")"
    case "$mode" in
      browser) curl -s -o /dev/null "$redirect/favicon.ico"
               curl -s -o "$work/$mode.page" "$redirect/?state=$state&code=good-code" ;;
      paste)   echo "not a url" >&3
               echo "$redirect/?state=$state&code=good-code&scope=s1+s2" >&3 ;;
      refused) curl -s -o "$work/$mode.page" "$redirect/?error=access_denied&state=$state" ;;
    esac
  fi
  exec 3>&-
  wait "$pid"
  echo "== $mode"
  sed 's/^http.*/<authorization url>/' "$out"
  if [ -f "$work/$mode.page" ]; then echo "-- browser got:"; cat "$work/$mode.page"; echo; fi
}

run browser
run paste
run refused
