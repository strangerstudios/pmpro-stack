#!/usr/bin/env bash
#
# test-wordpress-filters-log-formats.sh - The six WordPress filters must yield
# the CLIENT address on both Apache access-log shapes, and jail.local must never
# let fail2ban resolve a hostname into a ban.
#
# Background: the jails glob /var/log/apache2/*access.log, which takes the
# per-vhost `combined` logs (client first) AND other_vhosts_access.log, which is
# `vhost_combined` (`host:port client ...`). Filters written for `combined`
# captured the vhost name as <HOST> on those lines, and fail2ban's default
# `usedns = warn` resolved it, banning the site's own Cloudflare A/AAAA instead
# of the attacker. Each filter carries a prefregex that strips the optional
# prefix, and jail.local sets usedns = no.
#
# Two layers:
#   - static checks (bash + awk + grep): run anywhere, always.
#   - behavioural checks: need fail2ban-regex (a provisioned server, or a dev
#     box with fail2ban installed). Skipped with a SKIP line where it is absent,
#     so the suite still passes on macOS; run it on a server before shipping a
#     filter change.
#
# Paths can be overridden to test a staged copy on a server:
#   F2B_FILTER_DIR=/tmp/f2b/filter.d F2B_JAIL_LOCAL=/tmp/f2b/jail.local <this>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F2B_DIR="$(cd "$SCRIPT_DIR/../files" && pwd)"
FILTER_DIR="${F2B_FILTER_DIR:-$F2B_DIR/filter.d}"
JAIL_LOCAL="${F2B_JAIL_LOCAL:-$F2B_DIR/jail.local}"

FILTERS=(wordpress-login-brute wordpress-spam wordpress-webshell wordpress-credential-scan wordpress-404-flood wordpress-recon)
PREFREGEX='prefregex = ^(?:[\w.-]+:\d+ )?<F-CONTENT>.+</F-CONTENT>$'

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

PASSED=0
FAILED=0
SKIPPED=0

# Record a passing check.
#
# @param $1 Label.
# @return void
ok() { printf 'PASS  %s\n' "$1"; PASSED=$(( PASSED + 1 )); }

# Record a failing check.
#
# @param $1 Label.
# @param $2 Detail.
# @return void
bad() { printf 'FAIL  %s (%s)\n' "$1" "$2"; FAILED=$(( FAILED + 1 )); }

# Record a skipped check.
#
# @param $1 Label.
# @return void
skip() { printf 'SKIP  %s\n' "$1"; SKIPPED=$(( SKIPPED + 1 )); }

# ── static: every filter carries the exact prefregex, under [Definition] ────

for f in "${FILTERS[@]}"; do
	path="$FILTER_DIR/$f.conf"
	if [ ! -f "$path" ]; then bad "$f.conf present" "$path"; continue; fi
	n="$(grep -cxF -- "$PREFREGEX" "$path")"
	sec="$(awk '/^\[/{s=$0} /^prefregex[ \t]*=/{print s; exit}' "$path")"
	if [ "$n" -eq 1 ] && [ "$sec" = "[Definition]" ]; then
		ok "$f: one prefregex, under [Definition]"
	else
		bad "$f: one prefregex, under [Definition]" "count=$n section=${sec:-none}"
	fi
done

# ── static: jail.local [DEFAULT] usedns = no ────────────────────────────────

usedns="$(awk '/^\[/{s=$0} s=="[DEFAULT]" && /^usedns[ \t]*=/{v=$0; sub(/^usedns[ \t]*=[ \t]*/,"",v); print v; exit}' "$JAIL_LOCAL")"
if [ "$usedns" = "no" ]; then
	ok "jail.local [DEFAULT] usedns = no"
else
	bad "jail.local [DEFAULT] usedns = no" "got '${usedns:-unset}' (fail2ban default is warn: hostnames get resolved into bans)"
fi

# ── behavioural: fail2ban-regex ─────────────────────────────────────────────

if ! command -v fail2ban-regex >/dev/null 2>&1; then
	skip "fail2ban-regex not installed here; run this suite on a server for the behavioural checks"
else
	V4=203.0.113.9
	V6=2001:db8::7
	VHOST=example.com
	STAMP='[21/Sep/2026:19:56:08 +0000]'

	# Request lines that trip each filter.
	declare -A REQ=(
		[wordpress-login-brute]='"POST /wp-login.php HTTP/1.1" 200 11551'
		[wordpress-spam]='"POST /wp-comments-post.php HTTP/1.1" 302 0'
		[wordpress-webshell]='"GET /shell.php HTTP/1.1" 404 0'
		[wordpress-credential-scan]='"GET /.env HTTP/1.1" 404 0'
		[wordpress-404-flood]='"GET /no-such-page HTTP/1.1" 404 0'
		[wordpress-recon]='"GET /wp-admin/ HTTP/1.1" 302 484'
	)

	# Matched hosts fail2ban-regex reports for a fixture against a filter.
	#
	# @param $1 Fixture path.
	# @param $2 Filter path.
	# @return Hosts on stdout, one per line.
	matched_hosts() {
		fail2ban-regex -v --usedns=no "$1" "$2" 2>&1 | grep -E '^\|\s+[0-9a-fA-F.:]+\s' | awk '{print $2}' | sort
	}

	for f in "${FILTERS[@]}"; do
		fx="$TEMP_DIR/$f.log"
		tail='"https://example.test/" "Mozilla/5.0"'
		{
			printf '%s - - %s %s %s\n' "$V4" "$STAMP" "${REQ[$f]}" "$tail"
			printf '%s - - %s %s %s\n' "$V6" "$STAMP" "${REQ[$f]}" "$tail"
			printf '%s:443 %s - - %s %s %s\n' "$VHOST" "$V4" "$STAMP" "${REQ[$f]}" "$tail"
			printf '%s:443 %s - - %s %s %s\n' "$VHOST" "$V6" "$STAMP" "${REQ[$f]}" "$tail"
		} > "$fx"
		got="$(matched_hosts "$fx" "$FILTER_DIR/$f.conf" | uniq -c | awk '{printf "%s x%s ", $2, $1}')"
		want="$V6 x2 $V4 x2 "
		if [ "$got" = "$want" ]; then
			ok "$f: combined and vhost_combined lines both yield the client (v4 + v6)"
		else
			bad "$f: combined and vhost_combined lines both yield the client" "got '$got' want '$want'"
		fi
		if fail2ban-regex -v --usedns=no "$fx" "$FILTER_DIR/$f.conf" 2>&1 | grep -qF "$VHOST"; then
			bad "$f: the vhost name never surfaces as a host" "matched $VHOST"
		else
			ok "$f: the vhost name never surfaces as a host"
		fi
	done

	# A recon walk logged in vhost_combined. The client, not the vhost, must be
	# the host.
	fx="$TEMP_DIR/recon-vhost.log"
	printf '%s\n' 'example.com:443 203.0.113.81 - - [12/Sep/2026:20:49:31 +0000] "GET /wp-admin/ HTTP/1.1" 302 484 "https://example.com/admin" "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Mobile Safari/537.36"' > "$fx"
	got="$(matched_hosts "$fx" "$FILTER_DIR/wordpress-recon.conf" | tr '\n' ' ')"
	if [ "$got" = "203.0.113.81 " ]; then
		ok "vhost_combined recon line: wordpress-recon bans 203.0.113.81, not example.com"
	else
		bad "vhost_combined recon line: wordpress-recon bans 203.0.113.81, not example.com" "got '$got'"
	fi

	# A prefix-shaped IPv6 client on a combined line is still the client, not
	# mistaken for a host:port prefix.
	fx="$TEMP_DIR/v6edge.log"
	printf '%s\n' "2001:db8:3036::6815:1b2d - - $STAMP ${REQ[wordpress-recon]} \"-\" \"Mozilla/5.0\"" > "$fx"
	got="$(matched_hosts "$fx" "$FILTER_DIR/wordpress-recon.conf" | tr '\n' ' ')"
	if [ "$got" = "2001:db8:3036::6815:1b2d " ]; then
		ok "an IPv6 client on a combined line is not eaten by the prefix"
	else
		bad "an IPv6 client on a combined line is not eaten by the prefix" "got '$got'"
	fi

	# ignoreregex still applies after the prefix is stripped (recon's nonce
	# exemption; 404-flood's static-asset exemption), on the vhost_combined shape.
	fx="$TEMP_DIR/ignore.log"
	{
		printf '%s:443 %s - - %s "GET /wp-admin/edit.php?_wpnonce=deadbeef HTTP/1.1" 302 0 "-" "Mozilla/5.0"\n' "$VHOST" "$V4" "$STAMP"
	} > "$fx"
	if fail2ban-regex --usedns=no "$fx" "$FILTER_DIR/wordpress-recon.conf" 2>&1 | grep -qE 'Lines: 1 lines, 1 ignored, 0 matched'; then
		ok "recon: nonce-carrying admin redirect is still ignored on a vhost_combined line"
	else
		bad "recon: nonce-carrying admin redirect is still ignored on a vhost_combined line" "$(fail2ban-regex --usedns=no "$fx" "$FILTER_DIR/wordpress-recon.conf" 2>&1 | grep Lines:)"
	fi
	fx="$TEMP_DIR/ignore404.log"
	printf '%s:443 %s - - %s "GET /missing.css HTTP/1.1" 404 0 "-" "Mozilla/5.0"\n' "$VHOST" "$V4" "$STAMP" > "$fx"
	if fail2ban-regex --usedns=no "$fx" "$FILTER_DIR/wordpress-404-flood.conf" 2>&1 | grep -qE 'Lines: 1 lines, 1 ignored, 0 matched'; then
		ok "404-flood: static-asset 404 is still ignored on a vhost_combined line"
	else
		bad "404-flood: static-asset 404 is still ignored on a vhost_combined line" "$(fail2ban-regex --usedns=no "$fx" "$FILTER_DIR/wordpress-404-flood.conf" 2>&1 | grep Lines:)"
	fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
	printf 'RESULT: %s checks passed, %s skipped\n' "$PASSED" "$SKIPPED"
else
	printf 'RESULT: %s passed, %s FAILED, %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
fi
exit "$( [ "$FAILED" -eq 0 ] && echo 0 || echo 1 )"
