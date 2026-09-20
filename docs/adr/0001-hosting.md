# ADR-0001: Hosting on a disposable cloud VPS

## Status
Accepted

## Context
The task requires all components on one Docker host, with an emphasis on
reproducible reinstallation (task item 3) and a documented security baseline
(item 2). The build is time-boxed to three days. The author's private
infrastructure (Proxmox, Tailscale-based homelab, Bazzite workstation) exists but
is not designed to be thrown away and rebuilt.

## Options considered
- **Bare metal on the workstation (Bazzite, immutable Fedora)** — ample
  resources, but a full reinstall test is impossible by design, the OS differs
  from the realistic target (Debian/Ubuntu server), and it mixes a private
  system with an assessment system.
- **VM on the workstation (libvirt/KVM)** — free, snapshot-able, but setting up
  virtualisation on an immutable OS carries an unpredictable time risk (see
  ublue-os/bazzite issue #2103) and the environment stays offline, so the
  threat model remains theoretical.
- **Cloud VPS (Hetzner Cloud)** — shell in minutes, "rebuild" makes the
  reinstall test a button press, public IP makes hardening a real requirement,
  German provider, hourly billing.

## Decision
Hetzner Cloud VPS, shared vCPU, 8 vCPU / 16 GB RAM, Debian 13 image, with a
Hetzner Cloud Firewall in front of the host.

## Rationale
- Minimises time risk in a three-day budget.
- Reinstallation can only be *proven* on a disposable host.
- A public IP turns the security requirement into a real one: SSH key-only
  access, no exposed backend ports, firewall — all of it demonstrable.
- 16 GB is the GitLab single-node baseline (see [ADR-0004](0004-git-server.md)); OpenProject, XWiki
  (JVM), lldap, Caddy and three PostgreSQL instances fit alongside.
- Costs for the three-day build are around ten euros (CPX42 at about 0.13 EUR/h,
  hourly billing); the server is deleted after the final backup.

## Consequences
- Only test data is processed; no personal data of third parties.
- The private CA key and the SSH private key never leave the workstation.
- The Cloud Firewall allows inbound TCP 22, 80, 443 and 2222 (Git SSH) only.
- If the Hetzner account had not been activated in time, the fallback would
  have been a VM on the workstation.
