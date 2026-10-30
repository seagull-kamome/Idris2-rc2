#!/usr/bin/env bash
# Old callback server (Network.HTTP.Server) against the Task server
# (Network.Async.HTTP.Server), the same routes, measured with wrk.
#
#   ./bench.sh [seconds]        (default 8)
#
# Needs the repository's env.sh to have been sourced, rc2/build/exec/idris2-rc2
# built, the installed web and rc2base current (libs/web/tests/verify.sh installs web)
# and `nix-shell -p wrk` (or wrk on PATH). The servers and wrk share the machine,
# so the figures compare the servers with each other on this machine only.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
SECS="${1:-8}"
export LC_ALL=C.UTF-8
RC2="../../../rc2/build/exec/idris2-rc2"
for p in OldServer NewServer; do
    "$RC2" --cg rc2 -p web -p rc2base -p network -p contrib -o "$p" "$p.idr"
done

if command -v wrk >/dev/null; then
    run_wrk() { wrk "$@"; }
else
    run_wrk() { nix-shell -p wrk --run "wrk $*"; }
fi
SPID=
trap '[[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null; true' EXIT

# Wait (at most 5 s) until something listens on the port.
wait_listening() {
    for _ in $(seq 50); do
        (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

PORT=18810
# server configurations: name, command
configs=("old|./build/exec/OldServer" "new-1|./build/exec/NewServer" "new-3|./build/exec/NewServer")
threads_of() { case "$1" in new-1) echo 0 ;; new-3) echo 3 ;; esac; }

# scenarios: name, wrk arguments, path, which configs
scenarios=(
    "hello-c1|-t1 -c1|/hello|old new-1 new-3"
    "hello-c64|-t2 -c64|/hello|old new-1 new-3"
    "big64k-c16|-t2 -c16|/big|old new-1 new-3"
    "post64k-c16|-t2 -c16 -s post.lua|/echo|old new-1 new-3"
    "pipeline16-c16|-t2 -c16 -s pipeline.lua|/hello|old new-1 new-3"
    "work-c64|-t2 -c64|/work|old new-1 new-3"
    "sleep50ms-c64|-t2 -c64|/sleep|new-1 new-3"
)

printf '%-16s %-6s %12s %10s %10s %10s\n' scenario server req/s avg p99 errors
for sc in "${scenarios[@]}"; do
    IFS='|' read -r name wargs path which <<< "$sc"
    for cfg in "${configs[@]}"; do
        IFS='|' read -r cname cmd <<< "$cfg"
        [[ " $which " == *" $cname "* ]] || continue
        PORT=$((PORT + 1))
        if [[ "$cname" == old ]]; then $cmd $PORT & else $cmd $PORT "$(threads_of "$cname")" & fi
        SPID=$!
        if ! wait_listening "$PORT"; then
            printf '%-16s %-6s %s\n' "$name" "$cname" "NOSTART"
            kill "$SPID" 2>/dev/null || true; wait "$SPID" 2>/dev/null || true; SPID=
            continue
        fi
        # warm up, then measure
        run_wrk -d1s $wargs "http://127.0.0.1:$PORT$path" >/dev/null 2>&1 || true
        out="$(run_wrk -d"${SECS}s" --latency $wargs "http://127.0.0.1:$PORT$path" 2>&1 || true)"
        kill "$SPID" 2>/dev/null || true
        wait "$SPID" 2>/dev/null || true
        SPID=
        rps="$(sed -n 's/^Requests\/sec: *//p' <<< "$out")"
        avg="$(awk '/^ *Latency/ {print $2; exit}' <<< "$out")"
        p99="$(awk '/ 99%/ {print $2; exit}' <<< "$out")"
        err="$(grep -E 'Socket errors|Non-2xx|unable to connect' <<< "$out" | tr -s ' ' | tr '\n' ';' || true)"
        printf '%-16s %-6s %12s %10s %10s %s\n' "$name" "$cname" "${rps:-?}" "${avg:-?}" "${p99:-?}" "${err:-}"
    done
done
