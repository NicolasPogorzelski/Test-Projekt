# ADR-0005: Reverse proxy — Caddy

## Status
Accepted

## Context
Four web applications (GitLab CE, XWiki, OpenProject, lldap web UI) must be
served from a single host over HTTPS on port 443, each under its own hostname
and with its own certificate issued by a private CA (task items 1 and 5). This
requires a single TLS termination point that routes by hostname (SNI/Host) and
forwards the correct proxy headers (`Host`, `X-Forwarded-Proto`,
`X-Forwarded-For`) to each backend. The backends stay on internal Docker
networks and are never published directly.

## Options considered
- **nginx** — explicit configuration of every header and TLS parameter, most
  widespread, no Docker socket needed; ~100–150 lines for four hosts.
- **Traefik** — dynamic configuration via container labels, but the Docker
  provider needs Docker API access. Traefik's documentation: an attacker
  compromising Traefik "might get access to the underlying host"; a socket
  proxy is recommended as mitigation
  (https://doc.traefik.io/traefik/reference/install-configuration/providers/docker/).
- **Caddy** — static Caddyfile, ~15 lines for four hosts, secure TLS
  defaults, automatic HTTP→HTTPS redirect, `X-Forwarded-*` headers and
  WebSocket pass-through without explicit configuration, own certificates via
  `tls <cert> <key>`.

## Decision
Caddy, configured with a static Caddyfile and explicitly supplied
certificates, running as the only container with published ports (80/443),
as a non-root process inside the container.

## Rationale
- **No Docker socket.** Traefik adds a component (socket proxy) to solve a
  problem nginx and Caddy do not have. Rejected.
- **Small, reviewable configuration.** Fewer lines mean fewer places for a
  misconfiguration in a time-boxed build; another admin can review the whole
  file.
- **Secure defaults, documented.** Caddy's implicit behaviour is listed in
  `docs/architecture.md` ("What Caddy does implicitly") with references to
  the Caddy documentation, so nothing security-relevant is hidden.
- **nginx is an equivalent alternative.** It was not chosen only because of
  the additional configuration effort within the three-day time box.
  Migrating to nginx later would not change the backend contracts.

## Consequences
- Caddy's automatic ACME/Let's Encrypt is unused: `.test` hostnames are not
  publicly resolvable and the task requires private-CA certificates.
- Caddy's built-in local CA (`tls internal`) is deliberately not used so that
  the PKI remains fully explainable (ADR-0007).
- The header contract with each backend must still be configured on the
  backend side: GitLab `nginx['listen_https'] = false` and `listen_port = 80`
  (https://docs.gitlab.com/omnibus/settings/ssl/), OpenProject
  `OPENPROJECT_HTTPS`/`OPENPROJECT_HOST__NAME`, XWiki Tomcat `RemoteIpValve`.
- Security headers: only the uncontroversial ones (HSTS,
  `X-Content-Type-Options`, `Referrer-Policy`) are set at the proxy; CSP is
  left to the applications, which ship their own.
- Git over SSH bypasses the proxy (host port 2222 → GitLab container).
- `admin off` disables the admin API; certificate renewal or Caddyfile changes
  therefore need `docker compose restart caddy` (about one second) instead of
  `caddy reload`. Accepted: less surface, and changes are rare.
- The official image carries the file capability `cap_net_bind_service=ep` on
  the binary; with `cap_drop: ALL` the container must `cap_add:
  NET_BIND_SERVICE` or the process cannot even be executed (P-005).
