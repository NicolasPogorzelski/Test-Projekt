# Security policy

This repository documents an assessment project: a Docker-based work
environment (GitLab, XWiki, OpenProject) built in three days. It is not a
supported product and runs no public service on behalf of anyone.

- **What is protected and how** is described in
  [`docs/security.md`](docs/security.md), including what was verified from
  outside and the known gaps that were deliberately left open.
- **Found a problem in the configuration or the scripts?** Open a GitHub
  issue. If it concerns something that would expose a running instance of
  this design (a secret handling flaw, a bypass of the proxy or the gate),
  please describe it privately first via GitHub's "Report a vulnerability"
  form on this repository instead of a public issue.
- Secrets are never committed here; the repository is scanned on every commit
  and in CI (`.gitleaks.toml`). Certificates in `pki/` are the public CA
  certificate only.
