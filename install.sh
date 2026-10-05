#!/usr/bin/env bash
#
# pmpro-stack installer — macOS, Linux, and Windows via WSL.
#
#   curl -fsSL https://github.com/strangerstudios/pmpro-stack/releases/latest/download/install.sh | bash
#
# Installs the latest pmpro-stack release to ~/.pmpro-stack, puts `pmpro-stack`
# on your PATH (~/.local/bin), installs the tools it needs (curl, jq, openssl,
# ssh, tar, git, pipx → ansible + collections), and writes a ~/.pmpro-stack.env
# template for your DigitalOcean + Cloudflare tokens.
#
# Overrides:
#   PMPRO_STACK_HOME=<dir>   install location   (default: ~/.pmpro-stack)
#   PMPRO_STACK_REF=<ref>    git tag/branch to install instead of the latest release
#   PMPRO_STACK_NO_DEPS=1    skip system package / ansible installation
#

set -euo pipefail

REPO="strangerstudios/pmpro-stack"
INSTALL_DIR="${PMPRO_STACK_HOME:-$HOME/.pmpro-stack}"
BIN_DIR="$HOME/.local/bin"
ENV_FILE="$HOME/.pmpro-stack.env"

info() { printf '→ %s\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ─── Platform ─────────────────────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
	Linux)  PLATFORM=linux ;;
	Darwin) PLATFORM=macos ;;
	MINGW*|MSYS*|CYGWIN*)
		die "Run this inside WSL (Windows Subsystem for Linux), not Git Bash/MSYS.
       Open PowerShell and run:  wsl --install   then re-run this installer in the WSL shell.
       Or use install.ps1, which does that for you." ;;
	*) die "Unsupported OS: $OS" ;;
esac
grep -qi microsoft /proc/version 2>/dev/null && info "Detected WSL — treating as Linux."

SUDO=""
if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

# ─── System packages ──────────────────────────────────────────────────────────
install_system_deps() {
	local need=() c
	for c in curl jq openssl ssh tar git; do
		command -v "$c" >/dev/null 2>&1 || need+=("$c")
	done
	command -v python3 >/dev/null 2>&1 || need+=(python3)
	command -v dig     >/dev/null 2>&1 || need+=(dig)

	if [[ ${#need[@]} -eq 0 ]]; then ok "System tools present (curl jq openssl ssh tar git python3 dig)"; return; fi
	info "Installing missing tools: ${need[*]}"

	if [[ "$PLATFORM" == macos ]]; then
		command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS: https://brew.sh — install it, then re-run."
		local pkgs=()
		for c in "${need[@]}"; do
			case "$c" in
				ssh) ;;                       # ships with macOS
				dig) pkgs+=(bind) ;;
				python3) pkgs+=(python) ;;
				*) pkgs+=("$c") ;;
			esac
		done
		[[ ${#pkgs[@]} -gt 0 ]] && brew install "${pkgs[@]}"
	elif command -v apt-get >/dev/null 2>&1; then
		local pkgs=()
		for c in "${need[@]}"; do
			case "$c" in
				ssh) pkgs+=(openssh-client) ;;
				dig) pkgs+=(dnsutils) ;;
				*) pkgs+=("$c") ;;
			esac
		done
		$SUDO apt-get update -qq
		DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "${pkgs[@]}"
	elif command -v dnf >/dev/null 2>&1; then
		local pkgs=()
		for c in "${need[@]}"; do
			case "$c" in
				ssh) pkgs+=(openssh-clients) ;;
				dig) pkgs+=(bind-utils) ;;
				*) pkgs+=("$c") ;;
			esac
		done
		$SUDO dnf install -y "${pkgs[@]}"
	else
		die "No supported package manager found (apt-get, dnf, brew). Install manually: ${need[*]}"
	fi
	ok "System tools installed"
}

# ─── pipx + Ansible ───────────────────────────────────────────────────────────
install_ansible() {
	if command -v ansible-playbook >/dev/null 2>&1 && command -v ansible-galaxy >/dev/null 2>&1; then
		ok "Ansible present ($(ansible-playbook --version 2>/dev/null | head -1))"
		return
	fi

	if ! command -v pipx >/dev/null 2>&1; then
		info "Installing pipx"
		if [[ "$PLATFORM" == macos ]]; then
			brew install pipx
		elif command -v apt-get >/dev/null 2>&1 && apt-cache show pipx >/dev/null 2>&1; then
			DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq pipx
		elif command -v dnf >/dev/null 2>&1; then
			$SUDO dnf install -y pipx
		else
			python3 -m pip install --user pipx 2>/dev/null \
				|| python3 -m pip install --user --break-system-packages pipx
		fi
	fi
	export PATH="$BIN_DIR:$PATH"
	pipx ensurepath >/dev/null 2>&1 || true

	info "Installing Ansible via pipx (this takes a minute)"
	pipx install --include-deps ansible >/dev/null
	ok "Ansible installed"
}

# ─── Fetch pmpro-stack ────────────────────────────────────────────────────────
resolve_ref() {
	if [[ -n "${PMPRO_STACK_REF:-}" ]]; then echo "$PMPRO_STACK_REF"; return; fi
	local tag
	tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')" || true
	[[ -n "$tag" ]] || die "Could not determine the latest release of ${REPO}. Set PMPRO_STACK_REF=<tag> and retry."
	echo "$tag"
}

install_stack() {
	local ref="$1"
	local tmp
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT

	info "Downloading pmpro-stack ${ref}"
	curl -fsSL "https://github.com/${REPO}/archive/${ref}.tar.gz" -o "$tmp/src.tar.gz" \
		|| die "Download failed for ref '${ref}'."
	mkdir -p "$tmp/src"
	tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components=1
	[[ -x "$tmp/src/bin/pmpro-stack" ]] || die "Archive did not contain bin/pmpro-stack."

	mkdir -p "$(dirname "$INSTALL_DIR")"
	if [[ -d "$INSTALL_DIR" ]]; then
		rm -rf "${INSTALL_DIR}.old"
		mv "$INSTALL_DIR" "${INSTALL_DIR}.old"
	fi
	mv "$tmp/src" "$INSTALL_DIR"
	rm -rf "${INSTALL_DIR}.old"
	echo "$ref" > "$INSTALL_DIR/.installed-ref"
	ok "Installed to ${INSTALL_DIR}"

	mkdir -p "$BIN_DIR"
	ln -sfn "$INSTALL_DIR/bin/pmpro-stack" "$BIN_DIR/pmpro-stack"
	ok "Linked ${BIN_DIR}/pmpro-stack"
}

install_collections() {
	command -v ansible-galaxy >/dev/null 2>&1 || { warn "ansible-galaxy not found; skipping collection install."; return; }
	info "Installing Ansible collections"
	ansible-galaxy collection install -r "$INSTALL_DIR/ansible/requirements.yml" >/dev/null
	ok "Ansible collections installed"
}

# ─── Token file ───────────────────────────────────────────────────────────────
write_env_template() {
	if [[ -f "$ENV_FILE" ]]; then ok "Token file exists: ${ENV_FILE}"; return; fi
	cat > "$ENV_FILE" <<'ENVEOF'
# pmpro-stack tokens — this file is read automatically by `pmpro-stack`.
# Keep it private (chmod 600). Never commit it or paste it into chat.

# DigitalOcean — https://cloud.digitalocean.com/account/api/tokens
#   Generate New Token → name it, pick Full Access (or custom: droplet + ssh_key
#   read/write) → copy the token once; DO only shows it once.
DO_API_TOKEN=

# Cloudflare — https://dash.cloudflare.com/profile/api-tokens
#   Create Token → use the "Edit zone DNS" template → Zone Resources: include the
#   zone your site domain lives in → Continue → Create Token → copy it.
CF_API_TOKEN=
ENVEOF
	chmod 600 "$ENV_FILE"
	ok "Wrote token template: ${ENV_FILE}"
}

# ─── Run ──────────────────────────────────────────────────────────────────────
echo
printf '\033[1mpmpro-stack installer\033[0m\n'
echo

if [[ "${PMPRO_STACK_NO_DEPS:-0}" != 1 ]]; then
	install_system_deps
	install_ansible
else
	info "PMPRO_STACK_NO_DEPS=1 — skipping dependency installation"
fi

REF="$(resolve_ref)"
install_stack "$REF"
[[ "${PMPRO_STACK_NO_DEPS:-0}" != 1 ]] && install_collections
write_env_template

echo
ok "pmpro-stack ${REF} is installed."
echo
case ":$PATH:" in
	*":$BIN_DIR:"*) ;;
	*)
		warn "${BIN_DIR} is not on your PATH yet. Open a new terminal, or run:"
		echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
		echo ;;
esac
echo "Next steps:"
echo "  1. Add your tokens:        \$EDITOR ${ENV_FILE}"
echo "  2. Create your site:       pmpro-stack create --domain members.example.com --le-email you@example.com"
echo "  3. Later, get updates:     pmpro-stack update"
echo
