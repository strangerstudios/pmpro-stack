# pmpro-stack

An opinionated, hardened, self-hostable server stack for running
[WordPress](https://wordpress.org/) +
[Paid Memberships Pro](https://www.paidmembershipspro.com/) on a single Linux
server — the same baseline configuration Stranger Studios runs in production,
with everything specific to our business removed.

Point an AI coding agent (Claude Code or similar) at this repo, give it a
DigitalOcean API key and a Cloudflare API key, and it stands up an optimized
membership-site host for you. You can also run the Ansible playbook by hand.

## What you get

A fresh Ubuntu 24.04 server configured with:

- **Apache + PHP 8.3-FPM** — FPM proxy, opcache tuned, `mod_remoteip` for
  Cloudflare-fronted real client IPs
- **MySQL** — InnoDB tuned for a membership-site working set on a small box
- **Redis** — object-cache backend, memory-capped with an eviction policy
- **WP-CLI** — preinstalled
- **TLS via Let's Encrypt** — `certbot --apache`, auto-renewing (optional)
- **Hardening** — UFW (deny-all except SSH + Cloudflare), fail2ban with six
  WordPress jails (login-brute, comment-spam, webshell probes, secret-file
  scans, 404 floods, admin recon), the 8G Firewall at the Apache layer,
  server-level deny rules for backup/dump/secret artifacts, a hardened
  ImageMagick policy, and security-only unattended upgrades
- **Send-only outbound mail** — optional BYO-SMTP relay (SES, Mailgun, Postmark…)

## What it is *not*

This is the open baseline, not our managed platform. Deliberately **excluded**:
centralized monitoring, control-plane integration, managed operations tooling,
and anything tied to private accounts or infrastructure. See
[`docs/PROVENANCE.md`](docs/PROVENANCE.md) for exactly what was stripped and why.

## Prerequisites

- A server provider account — a **DigitalOcean API token** (droplet read/write)
  is the supported path; any Ubuntu 24.04 host works for the manual path.
- A **Cloudflare API token** for the zone you'll use (DNS edit) — for DNS and,
  optionally, proxying.
- A **domain** you control, and an **email** for Let's Encrypt.
- Locally: `ansible` (core) + the `community.general` and `ansible.posix` collections, plus `curl`,
  `jq`, `openssl`, and an SSH client. Install Ansible with
  `pipx install --include-deps ansible` (recommended), or
  `pip3 install ansible --break-system-packages` on PEP-668 hosts (Ubuntu 24.04,
  Debian 12+), or `sudo apt-get install -y ansible`. Then install collection deps:
  `ansible-galaxy collection install -r ansible/requirements.yml`. The CLI checks
  for every required command up front and prints the install line for anything missing.

## Quickstart (one command)

`bin/pmpro-stack` does the whole thing — creates the droplet, sets DNS, runs the
playbook (incl. TLS), and installs WordPress + PMPro:

```bash
# Tokens: export them, or put them in ~/.pmpro-stack.env (KEY=value lines).
export DO_API_TOKEN=...      # DigitalOcean (droplet read/write)
export CF_API_TOKEN=...      # Cloudflare (DNS edit on your zone)

bin/pmpro-stack create \
  --domain members.example.com \
  --le-email you@example.com
```

That boots a stock Ubuntu 24.04 droplet, upserts the `--domain` A record in your
Cloudflare zone (DNS-only at first so the Let's Encrypt challenge reaches the
origin), runs the Ansible playbook, installs WordPress + Paid Memberships Pro,
then **flips the record to proxied (orange-cloud)** so the site is fronted by
Cloudflare. It prints the site URL and admin credentials at the end, and also
writes them to a gitignored `./<domain>.env`. No `www` alias is created by
default — pass `--www` for an apex domain where you want one.

> **Cloudflare-fronted by default.** The firewall admits 80/443 **only from
> Cloudflare**, so the site is reachable solely through the proxy — direct hits
> to the origin IP are dropped by design. Pass `--direct` to instead serve
> straight from the origin (grey-cloud DNS + firewall open to all). Don't leave
> a grey-cloud record behind the default firewall: the box will serve fine on
> localhost but be unreachable to the public.

Each step is also a standalone subcommand — `create-droplet`, `setup-dns`,
`configure`, `install-wp`, `status`. See `bin/pmpro-stack --help`.

## Quickstart (agent path)

Open this repo in Claude Code (or any agent that reads `AGENTS.md`) and tell it
your domain. The agent follows [`AGENTS.md`](AGENTS.md): it collects your DO and
Cloudflare tokens and drives `bin/pmpro-stack` to provision the site. Tokens
stay in your environment — never commit them.

## Quickstart (Ansible only)

Already have an Ubuntu 24.04 host? Skip droplet creation and just configure it:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
cp ansible/inventory.example ansible/inventory   # set the host IP
$EDITOR ansible/group_vars/all.yml                # server_name, letsencrypt_email, smtp_*
cd ansible && ansible-playbook -i inventory site.yml
```

DNS must point `server_name` (plus `www.` only if you set `include_www: true`)
at the host with ports 80/443 reachable before TLS issuance succeeds. Leave
`letsencrypt_email` empty to skip
TLS and serve HTTP-only while you sort DNS. (This configures the server stack;
install WordPress afterward with `bin/pmpro-stack install-wp --ip <ip> --domain <d>`.)

## Status

Both phases are in place:

- **Server config layer** — the Ansible roles + playbook (`ansible/`) that turn a
  stock Ubuntu 24.04 host into the hardened stack above.
- **Provisioning CLI** — `bin/pmpro-stack`: one command to create the droplet
  from stock Ubuntu, manage DNS in your Cloudflare zone, run the playbook, and
  install WordPress + Paid Memberships Pro end to end.

- **Caching MU plugin** — a must-use plugin (`mu-plugin/`) that bundles Surge
  (page cache) + Redis Object Cache (object cache), installs both drop-ins,
  regenerates PDF preview thumbnails via poppler (the hardened ImageMagick
  policy denies the PDF coder), and adds a "PMPro Stack" admin page explaining
  the setup. `install-wp` deploys it and turns caching on automatically.

Not yet wired up: an opt-in Cloudflare Origin CA TLS path. See
[`docs/PROVENANCE.md`](docs/PROVENANCE.md).

## Documentation

- [`AGENTS.md`](AGENTS.md) — runbook an AI agent follows to provision a site
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — what each role does and why
- [`docs/PROVENANCE.md`](docs/PROVENANCE.md) — what was removed from the internal version

## License

GPL-2.0. See [`LICENSE`](LICENSE). "Paid Memberships Pro" and "PMPro" are
trademarks of Stranger Studios, LLC; this project configures the GPL software
but is not endorsed by, and the trademarks are not licensed for redistribution
under, the GPL.
