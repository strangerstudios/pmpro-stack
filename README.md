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
  scans, 404 floods, admin recon) whose bans are enforced at the Apache layer
  so they hold behind Cloudflare, the 8G Firewall at the Apache layer,
  server-level deny rules for backup/dump/secret artifacts, a hardened
  ImageMagick policy, and security-only unattended upgrades with a post-apt
  guard that restarts any stack service a package upgrade leaves dead
- **Send-only outbound mail** — optional BYO-SMTP relay (SES, Mailgun, Postmark…)

## What it is *not*

This is the open baseline, not our managed platform. Deliberately **excluded**:
centralized monitoring, control-plane integration, managed operations tooling,
and anything tied to private accounts or infrastructure. See
[`docs/PROVENANCE.md`](docs/PROVENANCE.md) for exactly what was stripped and why.

## Install (one command)

macOS, Linux, or Windows via WSL:

```bash
curl -fsSL https://github.com/strangerstudios/pmpro-stack/releases/latest/download/install.sh | bash
```

Windows (PowerShell) — sets up WSL if needed, then runs the same installer inside it:

```powershell
irm https://github.com/strangerstudios/pmpro-stack/releases/latest/download/install.ps1 | iex
```

The installer puts the latest release in `~/.pmpro-stack`, links `pmpro-stack`
into `~/.local/bin`, installs the tools it needs (`curl`, `jq`, `openssl`, `ssh`,
`git`, and Ansible via `pipx`, plus the `community.general` and `ansible.posix`
collections), and writes a token template to `~/.pmpro-stack.env`. Later,
`pmpro-stack update` pulls the newest release. The installer scripts live in this
repo (`install.sh`, `install.ps1`) and are attached to every release.

## Get your API tokens

You need two tokens. Put them in `~/.pmpro-stack.env` (the installer created it;
`pmpro-stack` reads it automatically — nothing to export):

```bash
DO_API_TOKEN=dop_v1_...
CF_API_TOKEN=...
```

Both dashboards change layout now and then, but the path is roughly:

- **DigitalOcean** — [cloud.digitalocean.com/account/api/tokens](https://cloud.digitalocean.com/account/api/tokens)
  → *Generate New Token* → give it a name → **Full Access** (or Custom Scopes with
  `droplet` and `ssh_key` read + write) → *Generate Token*. Copy it right away —
  DigitalOcean shows it only once.
- **Cloudflare** — [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
  → *Create Token* → use the **Edit zone DNS** template → under *Zone Resources*
  pick the zone your site's domain lives in → *Continue to summary* → *Create
  Token* → copy it.

You also need a **domain** whose DNS is on Cloudflare, and an **email** for
Let's Encrypt.

## Quickstart (one command)

`pmpro-stack create` does the whole thing — creates the droplet, sets DNS, runs
the playbook (incl. TLS), and installs WordPress + PMPro:

```bash
pmpro-stack create \
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
`configure`, `install-wp`, `status`. See `pmpro-stack --help`.

## Updating

```bash
pmpro-stack update          # install the latest GitHub release
pmpro-stack update --check  # just report whether one is available
pmpro-stack version
```

In a git checkout of this repo, `update` does a fast-forward `git pull` instead.

## Quickstart (agent path)

Point Claude Code (or any agent that reads `AGENTS.md`) at this repo or at the
install above, and tell it your domain. The agent follows [`AGENTS.md`](AGENTS.md):
it has you fill in `~/.pmpro-stack.env` and drives `pmpro-stack` to provision the
site. Tokens stay in that file — never commit them.

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
install WordPress afterward with `pmpro-stack install-wp --ip <ip> --domain <d>`.)

## Status

Both phases are in place:

- **Server config layer** — the Ansible roles + playbook (`ansible/`) that turn a
  stock Ubuntu 24.04 host into the hardened stack above.
- **Provisioning CLI** — `bin/pmpro-stack`: one command to create the droplet
  from stock Ubuntu, manage DNS in your Cloudflare zone, run the playbook, and
  install WordPress + Paid Memberships Pro end to end.

- **Caching MU plugin** — a must-use plugin (`mu-plugin/`) that bundles Surge
  (page cache) + Redis Object Cache (object cache), installs both drop-ins,
  keeps PMPro's checkout, confirmation, login, and member-account pages out of
  the page cache (filter: `pmpro_stack_exclude_from_cache`), regenerates PDF preview thumbnails via poppler (the hardened ImageMagick
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
