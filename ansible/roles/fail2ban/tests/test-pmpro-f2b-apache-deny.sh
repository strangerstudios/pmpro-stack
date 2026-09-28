#!/usr/bin/env bash
#
# test-pmpro-f2b-apache-deny.sh — Offline test for the Apache deny renderer.
#
# Runs anywhere with bash + coreutils; touches no server. All state paths are
# redirected via the script's PMPRO_F2B_* overrides, and apache2ctl/systemctl
# are stubbed on PATH so the render path (configtest + reload) completes without
# a real Apache.
#
# The load-bearing assertion is that every rendered conf carries `AuthMerging
# And`. Without it the <Location "/"> deny (evaluated last) REPLACES the
# authorization of .htaccess / <Files> / FilesMatch instead of combining with
# it, exposing member media and secret files to any non-banned visitor. This
# test guards against that regression.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../files/bin" && pwd)"
DENY="$SCRIPT_DIR/pmpro-f2b-apache-deny"

TEMP_DIR="$(mktemp -d)"
STUB_DIR="$TEMP_DIR/bin"
mkdir -p "$STUB_DIR"
printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/apache2ctl"
printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/systemctl"
# flock is absent on some dev hosts (macOS); the fd is already open via exec, so
# a no-op lock is fine for a single-process offline test.
command -v flock >/dev/null 2>&1 || printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/flock"
chmod +x "$STUB_DIR"/*
export PATH="$STUB_DIR:$PATH"

export PMPRO_F2B_LIST="$TEMP_DIR/deny.list"
export PMPRO_F2B_CONF="$TEMP_DIR/deny.conf"
export PMPRO_F2B_LINK="$TEMP_DIR/deny.link"
export PMPRO_F2B_LOCK="$TEMP_DIR/deny.lock"
export PMPRO_F2B_RELOAD=0

PASSED=0
FAILED=0
ok()   { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }

conf_has() { grep -qF "$1" "$PMPRO_F2B_CONF"; }
# A live directive line, not a comment or prefix: whole-line, leading indent
# only. `grep -F "AuthMerging And"` would also match the explanatory comment, so
# a rendered "# AuthMerging And" (Apache back to its Off default) would pass.
conf_directive() { grep -qE "^[[:space:]]*$1[[:space:]]*$" "$PMPRO_F2B_CONF"; }

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

echo "test-pmpro-f2b-apache-deny"

# Two jails ban two IPs.
"$DENY" add wordpress-recon 1.2.3.4 >/dev/null 2>&1
"$DENY" add wordpress-404-flood 5.6.7.8 >/dev/null 2>&1

# The regression guard: AuthMerging must be a LIVE directive (so the ban ANDs
# with inherited authz instead of replacing it), and the ban list must stay
# wrapped in RequireAll — a bare granted + not-ip pair merges as an implicit
# RequireAny, where "granted" alone satisfies the request and bypasses the bans.
if conf_directive "AuthMerging And"; then ok "AuthMerging And is a live directive"; else fail "AuthMerging And missing or only a comment (reverts to Off/replace)"; fi
if conf_directive "<RequireAll>" && conf_directive "</RequireAll>"; then ok "ban list wrapped in RequireAll (ANDed, not RequireAny)"; else fail "RequireAll wrapper missing (bans would merge as implicit OR)"; fi
# AuthMerging must be a live directive inside the Location, before an existing RequireAll.
if awk '
	/^[[:space:]]*<Location "\/">[[:space:]]*$/ { loc=1; next }
	loc && /^[[:space:]]*AuthMerging And[[:space:]]*$/ { am=1 }
	loc && /^[[:space:]]*<RequireAll>[[:space:]]*$/ { found=1; exit !am }
	END { exit !(found && am) }
' "$PMPRO_F2B_CONF"; then ok "AuthMerging precedes RequireAll inside the Location"; else fail "AuthMerging not a live directive before RequireAll in the Location"; fi
if conf_has "Require all granted"; then ok "conf grants by default"; else fail "conf missing Require all granted"; fi
if conf_has "Require not ip 1.2.3.4" && conf_has "Require not ip 5.6.7.8"; then ok "both banned IPs present"; else fail "a banned IP is missing"; fi

# Unban one IP; it drops, the other and the AuthMerging guard remain.
"$DENY" del wordpress-recon 1.2.3.4 >/dev/null 2>&1
if ! conf_has "Require not ip 1.2.3.4" && conf_has "Require not ip 5.6.7.8"; then ok "del removes only the unbanned IP"; else fail "del did not remove exactly one IP"; fi
if conf_directive "AuthMerging And"; then ok "AuthMerging survives a re-render"; else fail "AuthMerging lost on re-render"; fi

# Clearing the last jail empties the deny list but still renders a valid guarded conf.
"$DENY" clear wordpress-404-flood >/dev/null 2>&1
if conf_directive "AuthMerging And" && conf_directive "<RequireAll>" && ! conf_has "Require not ip"; then ok "empty deny list still renders the guard"; else fail "empty render dropped the guard or kept a ban"; fi

echo
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
