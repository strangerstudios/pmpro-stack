# Architecture

`pmpro-stack` is a set of Ansible roles run by one playbook (`ansible/site.yml`)
against a fresh Ubuntu 24.04 host. Each role configures one slice of the stack.
Run the whole thing, or target a slice with `--tags`.

## The roles

| Role | What it does |
|------|--------------|
| `swap` | 2 GB swapfile + low `vm.swappiness`, so a memory spike degrades instead of OOM-killing. |
| `base` | apt metadata refresh, core packages (curl, zip, redis, certbot), the `pmpro` system user, the `/var/www/vhosts/staging/public` web root, a memory-capped Redis with an eviction policy, and a 90-day journald retention cap. |
| `apt-security` | Security-only unattended upgrades: `-security` pocket daily, MySQL blacklisted (patch it in a maintenance window), no automatic reboot. |
| `postfix-relay` | **Optional.** Send-only outbound mail through your own SMTP relay. No-op unless `smtp_relayhost` is set. Pins `mydestination`/`myorigin` to localhost so the box never swallows mail to the site's own domain. |
| `php` | PHP 8.3-FPM pool (user `pmpro`, unix socket), opcache, slow-log, an FPM-only 60s execution-time default, and a hardened ImageMagick policy (raster formats only; PDF previews rasterize via poppler). Tunables in `group_vars`. |
| `apache` | Apache2 fronting PHP-FPM over the socket, `mod_remoteip` trusting Cloudflare ranges (so logs/fail2ban see the real client IP behind the proxy), directory indexing off, Ubuntu's default vhost disabled, Timeout/ProxyTimeout pinned to 300 to match FPM, and two drop-in protection configs (deny rules inherit into every vhost via `RewriteOptions InheritDownBefore` + the vhost's `RewriteEngine On`). |
| `mysql` | MySQL bound to localhost, utf8mb4, InnoDB buffer pool sized for a membership-site working set (not a flat % of RAM — it shares the box with FPM). |
| `wpcli` | WP-CLI binary + a sane `wp-cli.yml`. |
| `ssl` | **Optional.** Deploys the site vhost, then `certbot --apache` issues a Let's Encrypt cert for `server_name` (plus `www` only when `include_www: true`). No-op unless `letsencrypt_email` is set. Idempotent (skips if a live cert exists). |
| `fail2ban` | fail2ban + WordPress jails: login-brute (throttles repeated `wp-login.php` POSTs), comment-spam, webshell probes, `.env`/`.git`/secret scanning, 404 floods, and wp-admin/admin-ajax recon walks. |
| `ufw` | Deny-all inbound except SSH and the Cloudflare ranges on 80/443. Set `restrict_http_to_cloudflare: false` (or `create --direct`) to open 80/443 to the world for non-proxied origins. |
| `logrotate` | Rotates the PHP-FPM slow log. |
| `8g-fw` | The 8G Firewall (perishablepress.com) at the Apache layer — blocks a large set of malicious request patterns before PHP runs. |
| `motd_banner` | A login banner. Cosmetic. |

Order matters: `base` creates the user and packages the later roles need; `apache`
must exist before `ssl` edits its vhost; `ufw` runs late so it doesn't fence off
the host mid-build.

## The levers — `ansible/group_vars/all.yml`

Everything you'd reasonably tune lives in one file:

- **Site / TLS:** `server_name`, `letsencrypt_email`
- **Outbound mail:** `smtp_relayhost`, `smtp_relayport`, `smtp_user`, `smtp_pass`
- **MySQL:** `innodb_buffer_pool_size`, `max_connections`, `innodb_log_file_size`, …
- **OPcache:** `opcache_memory_consumption`, `opcache_max_accelerated_files`, …
- **PHP-FPM:** `pm_max_children`, `php_memory_limit`, upload sizes

Defaults target a ~4 GB host. The two values worth revisiting on bigger or busier
boxes: `innodb_buffer_pool_size` (size to your DB working set) and
`pm_max_children` (how many concurrent PHP requests; bounded by RAM ÷ per-worker
footprint). The two-line guidance: size InnoDB to the data that's actually hot,
not a flat fraction of RAM, then let the freed memory feed FPM workers.

## TLS model

A self-hosted box has no prebaked origin certificate, so the default is
**Let's Encrypt via certbot**: point DNS at the host (grey-cloud / DNS-only so
the HTTP-01 challenge reaches the origin), run the playbook, get an
auto-renewing publicly-trusted cert. `bin/pmpro-stack create` then **flips the
records to proxied (orange-cloud) automatically** at the end — required, because
the `ufw` role admits 80/443 only from Cloudflare, so a grey-cloud record would
leave the site unreachable to the public. Use SSL mode Full (strict): a real
origin cert satisfies strict mode without any extra origin certificate. Bringing
your own Cloudflare Origin CA cert is a possible future opt-in, not the default.
Pass `create --direct` to skip the flip and serve straight from the origin (the
`ufw` role then opens 80/443 to the world via `restrict_http_to_cloudflare:false`).

## Requirements

- A fresh **Ubuntu 24.04** target host with root SSH access.
- Locally: `ansible` (core) and the `community.general` + `ansible.posix` collections
  (`ansible-galaxy collection install -r ansible/requirements.yml`) — used by the
  `ufw`, `ssl`, and `swap` roles.
