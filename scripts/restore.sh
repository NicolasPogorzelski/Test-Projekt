#!/usr/bin/env bash

set -euo pipefail

# Restore one backup set produced by backup.sh onto a freshly bootstrapped host.
# Usage: sudo ./scripts/restore.sh /srv/backups/<stamp>.tar.age <age identity file>
#        sudo ./scripts/restore.sh /srv/backups/<stamp>              (already decrypted set)
#
# Preconditions (README runbook): admin account, repo cloned at the commit the set
# was taken from (or a compatible one), bootstrap.sh has run (packages, userns,
# /srv layout with owners), the .tar.age copied back to /srv/backups, the age
# identity on the host (temporarily - remove it afterwards).
#
# Guards, in this order, before anything is written (docs/adr/0008, decision 8):
#   1. sha256sum -c over the set            - transport damage, truncated files
#   2. image tags in manifest == compose.yaml - a dump only fits the version it came from
#   3. /srv targets empty, no stack containers, no .env - never overwrite a live system
# Then host artifacts, and the stacks in dependency order: lldap (all three
# applications bind to it) -> proxy -> OpenProject and XWiki (database container
# alone -> pg_restore -> files -> rest of the stack; the app must not start before
# the restore, its migrations would create the schema first) -> GitLab (secrets +
# tar in place -> start -> gitlab-backup restore -> restart). Ends with a machine
# check: every container healthy/running, every hostname answers over TLS.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRV=/srv
BACKUP_ROOT=$SRV/backups
ADMIN_USER="${SUDO_USER:-}"                 # owner of the .env files, like bootstrap.sh
REMAP_BASE=100000                           # container UID 0 -> host UID 100000 (ADR-0002)
HOSTS=(git.lab.test wiki.lab.test pm.lab.test ldap.lab.test)
STACKS=(proxy lldap gitlab openproject xwiki)
SET=""                                      # plaintext set directory, resolved in resolve_set
DECRYPTED=0                                 # 1 = we created $SET from a .tar.age and remove it at the end
START=$SECONDS

log()  { printf '%s ==> %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

compose() {
    local stack="$1" dir; shift
    if [[ "$stack" == proxy ]]; then dir="$REPO/proxy"; else dir="$REPO/services/$stack"; fi
    docker compose -f "$dir/compose.yaml" "$@"
}

# wait_for <container> <healthy|running> <timeout seconds>
wait_for() {
    local c="$1" want="$2" left="$3" state=""
    while ((left > 0)); do
        if [[ "$want" == healthy ]]; then
            state="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || true)"
        else
            state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
        fi
        [[ "$state" == "$want" ]] && return 0
        sleep 5
        left=$((left - 5))
    done
    die "$c did not become $want in time (last state: ${state:-none})"
}

# untar <archive> <parent dir>   archives carry their top-level dir (archive() in backup.sh)
untar() {
    tar --numeric-owner -xzf "$1" -C "$2"
}

# pg_restore_into <db container> <role=db> <dump>
pg_restore_into() {
    wait_for "$1" healthy 90
    # --no-owner: objects belong to the connecting role (the dump names the same one, but
    # this keeps the restore independent of it); -1: one transaction, no half-restored state
    docker exec -i "$1" pg_restore -U "$2" -d "$2" --no-owner -1 <"$3"
}

check_preconditions() {
    log "preconditions"
    [[ $EUID -eq 0 ]] || die "run with sudo"
    [[ -n "$ADMIN_USER" && "$ADMIN_USER" != root ]] || die "run via sudo from the admin account"
    [[ $# -ge 1 ]] || die "usage: restore.sh <set>.tar.age <identity file> | restore.sh <set dir>"
    command -v age >/dev/null && command -v docker >/dev/null && command -v curl >/dev/null \
        || die "age, docker and curl are required - run bootstrap.sh first"
    docker info >/dev/null 2>&1 || die "docker daemon not reachable"
    [[ -f "$REPO/pki/ca.crt" ]] || die "$REPO/pki/ca.crt missing"
}

resolve_set() {
    local src="$1" identity="${2:-}" name
    if [[ -d "$src" ]]; then
        SET="${src%/}"
    elif [[ "$src" == *.tar.age ]]; then
        [[ -f "$src" ]] || die "$src not found"
        [[ -n "$identity" && -f "$identity" ]] || die "encrypted set: pass the age identity file as second argument"
        name="$(basename "$src" .tar.age)"
        SET="$BACKUP_ROOT/$name"
        [[ -e "$SET" ]] && die "$SET already exists - remove it or pass the directory"
        log "decrypt $src -> $SET"
        # the archive holds <stamp>/..., so it unpacks into exactly $SET; root-only while it exists
        age -d -i "$identity" "$src" | tar --numeric-owner -x -C "$BACKUP_ROOT"
        chmod 700 "$SET"
        DECRYPTED=1
    else
        die "$src is neither a directory nor a .tar.age file"
    fi
    [[ -f "$SET/manifest.txt" && -f "$SET/SHA256SUMS" ]] || die "$SET is not a backup set (manifest/SHA256SUMS missing)"
}

guard_checksums() {
    log "guard 1/3: checksums"
    (cd "$SET" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch in $SET"
}

guard_versions() {
    log "guard 2/3: image tags in manifest match compose.yaml"
    # read the tags straight from compose.yaml: .env does not exist yet, so
    # `docker compose config` would refuse to interpolate ${...:?} variables
    local s want have dir
    for s in "${STACKS[@]}"; do
        if [[ "$s" == proxy ]]; then dir="$REPO/proxy"; else dir="$REPO/services/$s"; fi
        want="$(sed -n "s/^images\[$s\]: //p" "$SET/manifest.txt" | xargs -n1 | LC_ALL=C sort -u | tr '\n' ' ')"
        have="$(awk '$1 == "image:" { print $2 }' "$dir/compose.yaml" | LC_ALL=C sort -u | tr '\n' ' ')"
        [[ -n "$want" ]] || die "manifest has no images for $s"
        [[ "$want" == "$have" ]] || die "$s: set was taken with [$want] but compose.yaml has [$have] - check out the matching commit or bump deliberately"
    done
}

guard_empty_targets() {
    log "guard 3/3: nothing to overwrite"
    local d f s existing
    for d in proxy/certs proxy/config proxy/data lldap gitlab/config gitlab/logs gitlab/data \
             xwiki/data xwiki/db openproject/assets openproject/db; do
        [[ -d "$SRV/$d" ]] || die "$SRV/$d missing - run bootstrap.sh first"
        f="$(find "$SRV/$d" -mindepth 1 -type f -print -quit)"    # empty subdirs (trusted-certs/) are fine
        [[ -z "$f" ]] || die "$SRV/$d is not empty (found $f) - refusing to restore over existing data"
    done
    [[ ! -e "$SRV/xwiki/cacerts" ]] || die "$SRV/xwiki/cacerts exists"
    for s in gitlab lldap openproject xwiki; do
        [[ ! -e "$REPO/services/$s/.env" ]] || die "$REPO/services/$s/.env exists - refusing to overwrite secrets"
    done
    existing="$(docker ps -a --format '{{.Names}}' | grep -xE 'caddy|lldap|gitlab|openproject(-.*)?|xwiki(-db)?' || true)"
    [[ -z "$existing" ]] || die "stack containers already exist: $(tr '\n' ' ' <<<"$existing")"
}

restore_host_artifacts() {
    log "host artifacts: .env files, certificates, proxy state, truststore, GitLab CA copy"
    local s
    for s in gitlab lldap openproject xwiki; do
        install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$SET/env/$s.env" "$REPO/services/$s/.env"
    done
    untar "$SET/proxy/certs.tar.gz"  "$SRV/proxy"
    untar "$SET/proxy/config.tar.gz" "$SRV/proxy"
    untar "$SET/proxy/data.tar.gz"   "$SRV/proxy"
    install -m 644 -o root -g root "$SET/xwiki/cacerts" "$SRV/xwiki/cacerts"
    # not in the set, comes from the repo: GitLab trusts the lab CA via trusted-certs (P-010)
    install -m 644 -o "$REMAP_BASE" -g "$REMAP_BASE" "$REPO/pki/ca.crt" "$SRV/gitlab/config/trusted-certs/ca.crt"
}

restore_lldap() {
    log "lldap: unpack, start"
    untar "$SET/lldap/data.tar.gz" "$SRV"
    compose lldap up -d
    wait_for lldap healthy 60
}

restore_proxy() {
    log "proxy: start"
    compose proxy up -d
    wait_for caddy running 30
}

restore_openproject() {
    log "openproject: db alone -> pg_restore -> assets -> full stack"
    compose openproject up -d db
    pg_restore_into openproject-db openproject "$SET/openproject/db.dump"
    untar "$SET/openproject/assets.tar.gz" "$SRV/openproject"
    compose openproject up -d                 # seeder runs again (idempotent), then web + worker
    wait_for openproject healthy 300
}

restore_xwiki() {
    log "xwiki: db alone -> pg_restore -> data -> full stack"
    compose xwiki up -d db
    pg_restore_into xwiki-db xwiki "$SET/xwiki/db.dump"
    untar "$SET/xwiki/data.tar.gz" "$SRV/xwiki"
    compose xwiki up -d
    wait_for xwiki healthy 300
}

restore_gitlab() {
    local tar_name backup_id
    tar_name="$(sed -n 's/^gitlab_backup: //p' "$SET/manifest.txt")"
    [[ -n "$tar_name" && -f "$SET/gitlab/$tar_name" ]] || die "gitlab backup tar missing in set"
    backup_id="${tar_name%_gitlab_backup.tar}"     # gitlab-backup restore BACKUP=<this>
    log "gitlab: secrets, host keys and $tar_name in place, first start (reconfigure takes minutes)"
    install -m 600 -o "$REMAP_BASE" -g "$REMAP_BASE" "$SET/gitlab/gitlab-secrets.json" "$SRV/gitlab/config/gitlab-secrets.json"
    install -m 600 -o "$REMAP_BASE" -g "$REMAP_BASE" "$SET/gitlab/gitlab.rb" "$SRV/gitlab/config/gitlab.rb"
    untar "$SET/gitlab/ssh-host-keys.tar.gz" "$SRV/gitlab/config"
    install -d -m 700 -o "$REMAP_BASE" -g "$REMAP_BASE" "$SRV/gitlab/data/backups"
    install -m 600 -o "$REMAP_BASE" -g "$REMAP_BASE" "$SET/gitlab/$tar_name" "$SRV/gitlab/data/backups/$tar_name"
    compose gitlab up -d
    wait_for gitlab healthy 600
    log "gitlab: gitlab-backup restore BACKUP=$backup_id (docs: stop puma + sidekiq first)"
    docker exec gitlab chown git:git "/var/opt/gitlab/backups/$tar_name"   # restore runs as git
    docker exec gitlab gitlab-ctl stop puma
    docker exec gitlab gitlab-ctl stop sidekiq
    docker exec -e GITLAB_ASSUME_YES=1 gitlab gitlab-backup restore "BACKUP=$backup_id"
    log "gitlab: restart and self-check"
    compose gitlab restart
    wait_for gitlab healthy 600
    docker exec gitlab gitlab-rake gitlab:check SANITIZE=true || warn "gitlab:check reported problems - read the output above"
}

verify() {
    log "verify: containers"
    local c code fails=0 h
    for c in lldap caddy gitlab openproject openproject-db xwiki xwiki-db; do
        wait_for "$c" healthy 60 2>/dev/null || { warn "$c not healthy"; fails=$((fails + 1)); }
    done
    for c in openproject-worker openproject-cache; do
        wait_for "$c" running 30 2>/dev/null || { warn "$c not running"; fails=$((fails + 1)); }
    done
    log "verify: TLS endpoints through Caddy (expect 302, ldap 401)"
    for h in "${HOSTS[@]}"; do
        # --resolve pins the name to the local proxy; the CA from the repo validates the leaf
        code="$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$REPO/pki/ca.crt" \
                --resolve "$h:443:127.0.0.1" "https://$h/" || echo 000)"
        printf '    %-14s %s\n' "$h" "$code"
        [[ "$code" =~ ^(200|302|401)$ ]] || fails=$((fails + 1))
    done
    ((fails == 0)) || die "$fails verification check(s) failed"
}

cleanup_set() {
    if ((DECRYPTED)); then
        rm -rf "$SET"                       # plaintext copy of every secret; the .tar.age stays
        log "removed decrypted set $SET"
    fi
}

check_preconditions "$@"
resolve_set "$@"
guard_checksums
guard_versions
guard_empty_targets
restore_host_artifacts
restore_lldap
restore_proxy
restore_openproject
restore_xwiki
restore_gitlab
verify
cleanup_set
log "done in $(( (SECONDS - START) / 60 )) min $(( (SECONDS - START) % 60 )) s - now the functional checklist in docs/backup-restore.md"
