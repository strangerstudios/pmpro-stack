# AGENTS.md — runbook for AI coding agents

You are helping a user stand up a hardened WordPress + Paid Memberships Pro host
using this repo. This file is the runbook. Read it fully before acting.

## What this repo does

It configures a single Ubuntu 24.04 server into an opinionated, hardened LAMP +
Redis + PHP-FPM stack ready for WordPress + Paid Memberships Pro. The server
configuration lives in `ansible/` (a playbook + roles). See `README.md` for the
feature list and `docs/ARCHITECTURE.md` for per-role detail.

## The tool — `bin/pmpro-stack`

A single CLI with subcommands drives everything. Run `bin/pmpro-stack --help`
first to see the current surface; do not assume flags that `--help` doesn't list.

- `create` — full flow (create-droplet → setup-dns → configure → install-wp)
- `create-droplet` — boot a stock `ubuntu-24-04-x64` droplet on DigitalOcean
- `setup-dns` — upsert the domain A record (and www only with `--www`) in the user's own Cloudflare zone
- `configure` — run the bundled Ansible playbook (`ansible/site.yml`) incl. certbot TLS
- `install-wp` — DB + WordPress + Paid Memberships Pro into the configured server
- `status` — droplet + SSH + HTTPS reachability

The one-shot path is `bin/pmpro-stack create --domain <d> --le-email <e>`. Prefer
it unless the user wants to run a single step.

## Secrets — handle carefully

- The user supplies a **DigitalOcean API token** and a **Cloudflare API token**.
  Read them from the environment (`DO_API_TOKEN`, `CF_API_TOKEN`) or a
  host-local `~/.pmpro-stack.env` the user creates.
- **Never** write tokens into the repo, commit them, echo them on a command line
  (shell history), or paste them into logs. `.gitignore` blocks `*.env`, certs,
  and keys — keep it that way.
- TLS keys are issued on the server by certbot. None ship in this repo. Never
  add a `*.pem`/`*.key`/`authorized_keys` file to it.

## Information to collect from the user before provisioning

1. **Domain** (e.g. `members.example.com`) — must be one they control.
2. **Cloudflare zone** for that domain, and a CF token with DNS edit on it.
3. **Let's Encrypt contact email**.
4. **DigitalOcean token**, preferred **region** and droplet **size**
   (default: a 4 GB droplet — `s-2vcpu-4gb`).
5. **WordPress admin** username/email (generate a strong password; show it once).

## Provisioning flow

The simplest path is one command:

```bash
bin/pmpro-stack create --domain <domain> --le-email <email> [--region <r>] [--size <s>]
```

It runs all four steps in order and prints the site URL + admin credentials
once at the end. Under the hood (and runnable individually if a step fails):

1. **`create-droplet`** — boots a stock `ubuntu-24-04-x64` droplet (no golden
   image). Imports the user's local SSH pubkey to DO if needed. Returns the IP.
2. **`setup-dns`** — upserts the domain A record in the user's own Cloudflare
   zone, **DNS-only (grey-cloud)** so the Let's Encrypt HTTP-01 challenge reaches
   the origin. `--cf-proxy` upserts it proxied (orange-cloud) instead. No `www`
   alias by default; `--www` adds one (sensible only for apex domains).
3. **`configure`** — runs `ansible/site.yml` against the droplet: the hardened
   stack + certbot TLS (skipped if no `--le-email`). The UFW role admits 80/443
   **only from Cloudflare** by default; `--open-firewall` admits them from anywhere
   (set automatically by `create --direct`).
4. **`install-wp`** — creates the DB, installs WordPress + Paid Memberships Pro,
   writes wp-config, sets up wp-cron, deploys the caching MU plugin (`mu-plugin/`)
   and turns on page + object caching. Prints credentials once **and** writes them
   to a gitignored `./<domain>.env` (chmod 600) so they're not lost — `--no-creds-file`
   to skip, `--creds-file <path>` to relocate.
5. **Front with Cloudflare** — `create` finishes by flipping the records to proxied
   (orange-cloud). This is mandatory, not cosmetic: the UFW role admits 80/443 only
   from Cloudflare, so a grey-cloud record would leave the site **unreachable to
   real visitors**. `--direct` skips this flip and instead opens the firewall to all.

**The firewall posture and the DNS proxy state must stay consistent** — proxied +
Cloudflare-only (default), or grey-cloud + open (`--direct`). A grey-cloud record
behind a Cloudflare-only firewall is the one combination that silently breaks
public access while the box itself serves fine on localhost. The `create`
completion also prints DNS-propagation/cache-flush guidance and a caching note.

If one step fails mid-`create`, re-run just that subcommand with the printed IP
(e.g. `bin/pmpro-stack configure --ip <ip> --domain <d> --le-email <e>`).

## Guardrails

- Booting and billing real cloud infrastructure is a destructive, costly action.
  **Confirm with the user before creating or destroying any droplet or DNS
  record.** Show what you're about to create and the rough cost.
- Use the **stock Ubuntu image**. This repo has no golden image; do not look for
  or depend on a prebaked snapshot.
- `server_name` drives both the Apache vhost and the TLS cert. Get it right
  before running the `ssl` role — reissuing for a typo'd domain wastes a
  Let's Encrypt rate-limit slot.
- If TLS issuance fails, it's almost always DNS not yet pointing at the host, the
  record still proxied (orange-cloud), or 80/443 not reachable. Check those
  before retrying certbot.
- Keep the `pmpro` system user name as-is; roles assume it.
