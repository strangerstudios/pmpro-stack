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
# systemctl logs each call and fails once when $STUB_FAIL_ONCE exists.
cat > "$STUB_DIR/systemctl" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
if [ -n "${STUB_FAIL_ONCE:-}" ] && [ -f "$STUB_FAIL_ONCE" ]; then rm -f "$STUB_FAIL_ONCE"; exit 1; fi
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/logger"
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
export PMPRO_F2B_RELOAD_DELAY=1
export STUB_LOG="$TEMP_DIR/systemctl.log"

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

# Reference counting: an IP two jails hold survives one jail clearing.
"$DENY" add wordpress-recon 9.9.9.9 >/dev/null 2>&1
"$DENY" add wordpress-webshell 9.9.9.9 >/dev/null 2>&1
"$DENY" clear wordpress-recon >/dev/null 2>&1
if conf_has "Require not ip 9.9.9.9"; then ok "IP held by another jail survives a clear"; else fail "clear dropped an IP another jail still holds"; fi
"$DENY" del wordpress-webshell 9.9.9.9 >/dev/null 2>&1
if ! conf_has "Require not ip 9.9.9.9"; then ok "IP drops once the last jail unbans"; else fail "IP still denied after the last unban"; fi

# A non-IP target is refused and never reaches the list or the conf.
"$DENY" add wordpress-recon 'bogus host' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && ! grep -q bogus "$PMPRO_F2B_LIST" && ! conf_has bogus; then ok "non-IP ban target refused (exit 2, list untouched)"; else fail "non-IP ban target accepted (rc=$rc)"; fi
"$DENY" add wordpress-recon 2001:db8::/64 >/dev/null 2>&1
if conf_has "Require not ip 2001:db8::/64"; then ok "IPv6 CIDR accepted"; else fail "IPv6 CIDR refused"; fi
"$DENY" clear wordpress-recon >/dev/null 2>&1

# The conf is enabled on first render only: a deliberate a2disconf sticks.
if [ -L "$PMPRO_F2B_LINK" ]; then ok "first render enabled the conf"; else fail "first render did not enable the conf"; fi
rm -f "$PMPRO_F2B_LINK"
"$DENY" add wordpress-recon 1.2.3.4 >/dev/null 2>&1
if [ ! -e "$PMPRO_F2B_LINK" ]; then ok "a disabled conf stays disabled on re-render"; else fail "re-render re-enabled a disabled conf"; fi
"$DENY" clear wordpress-recon >/dev/null 2>&1

# Reloads coalesce: a burst of bans (a fail2ban restart replay) is one reload.
wait_idle() { for _ in $(seq 1 80); do pgrep -f "$DENY _reload-worker" >/dev/null || return 0; sleep 0.25; done; }
: > "$STUB_LOG"
for i in $(seq 1 20); do PMPRO_F2B_RELOAD=1 "$DENY" add wordpress-recon "198.51.100.$i" >/dev/null 2>&1; done
sleep 0.5; wait_idle
n=$(grep -c "try-reload-or-restart apache2" "$STUB_LOG" || true)
if [ "$n" -ge 1 ] && [ "$n" -le 2 ]; then ok "20 bans coalesced into $n reload(s)"; else fail "20 bans caused $n reloads (want 1-2)"; fi

# A failed reload is retried rather than dropped.
: > "$STUB_LOG"
export STUB_FAIL_ONCE="$TEMP_DIR/fail-once"; touch "$STUB_FAIL_ONCE"
PMPRO_F2B_RELOAD=1 "$DENY" add wordpress-recon 203.0.113.50 >/dev/null 2>&1
sleep 0.5; wait_idle
n=$(grep -c "try-reload-or-restart apache2" "$STUB_LOG" || true)
if [ "$n" -eq 2 ] && [ ! -f "$PMPRO_F2B_LIST.reload-pending" ]; then ok "failed reload retried and succeeded"; else fail "failed reload not retried (calls=$n)"; fi
unset STUB_FAIL_ONCE

echo
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
