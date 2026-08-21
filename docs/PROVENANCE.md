# Provenance

`pmpro-stack` is an open-source adaptation of the server configuration used to
run production WordPress and Paid Memberships Pro sites. It keeps the parts that
are useful on a standalone host and replaces or omits managed-platform features.

This document describes those boundaries without documenting private
infrastructure.

## Deliberately excluded

- Centralized monitoring and operations systems.
- Managed backup, security, and fleet-management tooling.
- Control-plane and image-build automation.
- Account-specific credentials, identifiers, domains, network details, and
  provider configuration.

These are platform concerns rather than requirements for a self-hosted PMPro
site.

## Replaced or parameterized

- **TLS:** Let's Encrypt via certbot, using a domain and contact email you
  provide.
- **Outbound mail:** an optional bring-your-own SMTP relay, disabled by default.
- **SSH trust:** your server provider or administrator supplies authorized keys;
  none are included here.
- **Domains:** every site-specific hostname is supplied through configuration.

## What ships

- An Ansible playbook that configures a stock Ubuntu server.
- A provisioning CLI for the supported server and DNS providers.
- A purpose-built caching must-use plugin containing Surge and Redis Object
  Cache. Managed-hosting operational features are not included.

The repository is checked for committed credentials and private infrastructure
identifiers. Runtime credentials remain local, and certificates are issued on
the target server.

Possible future additions include provider-neutral backup and security tooling
and an opt-in Cloudflare Origin CA TLS path.
