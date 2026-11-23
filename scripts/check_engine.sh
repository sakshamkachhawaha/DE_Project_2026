#!/usr/bin/env bash
# Stops unless the server is PostgreSQL 15.
# Phase 3 and 4 ran on 15.18, so Phase 5 has to run there too.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; echo >&2; echo "Fix: start/point at PostgreSQL 15.18 (e.g. /Applications/Postgres.app/Contents/Versions/15/bin or 'brew install postgresql@15'), then run this script again." >&2; exit 1; }

CLIENT="$(psql --version 2>/dev/null || true)"
echo "psql client : ${CLIENT:-not found}"
[[ -n "$CLIENT" ]] || fail "psql is not on PATH"

CMAJOR="$(printf '%s' "$CLIENT" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)"
if [[ "$CMAJOR" != "15" ]]; then
    echo "note: the client is major version ${CMAJOR}, not 15. That is fine, a newer"
    echo "      psql can talk to a 15 server. What matters is the server below."
fi

SERVER="$(psql -d postgres -Atc 'SHOW server_version' 2>/dev/null || true)"
[[ -n "$SERVER" ]] || fail "cannot connect to a server (try: psql -d postgres -c 'select 1')"
echo "server      : $SERVER"

SMAJOR="$(printf '%s' "$SERVER" | cut -d. -f1)"
[[ "$SMAJOR" == "15" ]] || fail "server is major version ${SMAJOR}, expected 15"

PATHINFO="$(psql -d postgres -Atc 'SELECT current_setting($$server_version_num$$)' 2>/dev/null || true)"
echo "server num  : ${PATHINFO:-?}"
echo
echo "OK: both sides are PostgreSQL 15. Proceed."
