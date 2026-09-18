# Problems and peculiarities

Chronological. Format: symptom → verification → cause → fix / decision.

## P-001 — Flatpak browsers do not use the system CA trust store
- **Symptom:** (anticipated) after `update-ca-trust` on the Fedora-based
  workstation, Firefox/Chrome still show a certificate warning for
  `*.lab.test`.
- **Verification:** `flatpak list --app` shows Firefox and Chrome installed as
  Flatpaks; Flatpak sandboxes ship their own trust store.
- **Cause:** Flatpak applications do not read `/etc/pki/ca-trust`.
- **Fix:** import `pki/ca.crt` in the browser's own certificate manager
  (Firefox: Settings → Privacy & Security → Certificates → Authorities →
  Import). Documented in the README for other admins.
