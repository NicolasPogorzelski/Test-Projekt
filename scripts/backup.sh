#!/usr/bin/env bash

set -euo pipefail

# Application-consistent backup of all lab.test stacks into one timestamped set.
# Usage: sudo ./scripts/backup.sh       (from the admin account, like bootstrap.sh)
#
# Set layout under /srv/backups/<UTC timestamp>/ (docs/backup-restore.md, ADR-0008):
#   gitlab/       <ts>_gitlab_backup.tar + gitlab-secrets.json + gitlab.rb + ssh-host-keys.tar.gz
#                 (gitlab-backup covers none of the three - GitLab docs, "Storing configuration files";
#                 without the host keys every git@ client warns after a rebuild)
#   openproject/  db.dump (pg_dump -Fc) + assets.tar.gz
#   xwiki/        db.dump + data.tar.gz + cacerts
#   lldap/        data.tar.gz (SQLite users.db + lldap_config.toml)
#   proxy/        certs.tar.gz + config.tar.gz + data.tar.gz
#   env/          the four .env files
#   manifest.txt  image tags per stack, repo commit, host   SHA256SUMS  for sha256sum -c
# The finished directory is packed and encrypted to /srv/backups/<UTC timestamp>.tar.age
# (age, recipients from scripts/backup-recipients.txt) and the plaintext is removed:
# the set holds every secret of the installation, so nothing readable stays on disk
# and the off-host copy can live on an unencrypted workstation. Decrypt on restore:
#   age -d -i <identity file> <set>.tar.age | tar -x --numeric-owner
#
# Consistency rule (ADR-0008, amended 2026-09-20): application containers are
# stopped while their files are read, database containers keep running and are
# dumped with pg_dump (one MVCC snapshot); GitLab is never stopped because
# gitlab-backup is consistent on its own. An EXIT trap restarts whatever this
# script stopped, also after a failure. The set is written as <name>.partial and
# renamed last, so prune and restore.sh never mistake a half-written set for a
# complete one. Plaintext exists only while this script runs (root:backup 0750/0640).

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRV=/srv
BACKUP_ROOT=$SRV/backups
KEEP=7                                # sets to keep (ADR-0008)
BACKUP_GROUP=backup                   # Debian's delegated-backup group; the admin is added by bootstrap.sh
RECIPIENTS="$REPO/scripts/backup-recipients.txt"   # age public keys, one per line; private keys never touch the host
STACKS=(proxy lldap gitlab openproject xwiki)
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"    # UTC, sorts lexically, no ':' (rsync/tar friendly)
SET="$BACKUP_ROOT/$STAMP"
WORK="$SET.partial"
STOPPED=()                            # "<stack> <service>..." lines the trap has to start again
GITLAB_TAR=""                         # set by backup_gitlab, written to the manifest

log() { printf '%s ==> %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# compose <stack> <args...>   the project directory gives compose its name and .env
compose() {
    local stack="$1" dir; shift
    if [[ "$stack" == proxy ]]; then dir="$REPO/proxy"; else dir="$REPO/services/$stack"; fi
    docker compose -f "$dir/compose.yaml" "$@"
}

# stop_app <stack> <service...>   remembered, so the trap can undo it
stop_app() {
    compose "$1" stop "${@:2}"
    STOPPED+=("$*")
}

start_stopped() {
    local entry parts rc=0
    for entry in "${STOPPED[@]}"; do
        read -ra parts <<<"$entry"
        compose "${parts[0]}" start "${parts[@]:1}" || rc=1
    done
    STOPPED=()
    return $rc
}

cleanup() {
    local rc=$?
    start_stopped || printf 'error: a stopped service did not start again - check docker compose ps\n' >&2
    if ((rc != 0)) && [[ -d "$WORK" ]]; then
        printf 'error: backup failed (exit %d), %s left for inspection\n' "$rc" "$WORK" >&2
    fi
}
trap cleanup EXIT

# archive <dir> <dst.tar.gz>   numeric ids: the remapped UIDs (100000+) have no names on any host
archive() {
    tar --numeric-owner -C "$(dirname "$1")" -czf "$2" "$(basename "$1")"
}

# dump_db <container> <role=db> <dst>   Unix socket inside the container: no password (image pg_hba "local trust")
dump_db() {
    docker exec "$1" pg_dump -Fc -U "$2" "$2" >"$3"
    [[ -s "$3" ]] || die "empty dump from $1"
}

check_preconditions() {
    log "preconditions"
    [[ $EUID -eq 0 ]] || die "run with sudo"
    [[ -d "$BACKUP_ROOT" ]] || die "$BACKUP_ROOT missing - run bootstrap.sh first"
    getent group "$BACKUP_GROUP" >/dev/null || die "group $BACKUP_GROUP does not exist"
    command -v age >/dev/null || die "age not installed - run bootstrap.sh"
    [[ -s "$RECIPIENTS" ]] || die "no age recipients in $RECIPIENTS"
    docker info >/dev/null 2>&1 || die "docker daemon not reachable"
    local s
    for s in gitlab lldap openproject xwiki; do
        [[ -f "$REPO/services/$s/.env" ]] || die "missing $REPO/services/$s/.env"
    done
    [[ "$(docker inspect -f '{{.State.Health.Status}}' gitlab 2>/dev/null)" == healthy ]] \
        || die "container gitlab is not healthy - gitlab-backup needs a running instance"
    install -d -m 700 "$WORK"                     # parent first: the systemd umask would give it 755
    install -d -m 750 "$WORK"/{gitlab,openproject,xwiki,lldap,proxy,env}
    log "set: $WORK"
}

backup_lldap() {
    log "lldap: stop, archive /srv/lldap, start"
    stop_app lldap lldap
    archive "$SRV/lldap" "$WORK/lldap/data.tar.gz"
    start_stopped
}

backup_openproject() {
    log "openproject: stop web+worker, pg_dump, archive assets, start"
    stop_app openproject web worker
    dump_db openproject-db openproject "$WORK/openproject/db.dump"
    archive "$SRV/openproject/assets" "$WORK/openproject/assets.tar.gz"
    start_stopped
}

backup_xwiki() {
    log "xwiki: stop xwiki, pg_dump, archive data, copy cacerts, start"
    stop_app xwiki xwiki
    dump_db xwiki-db xwiki "$WORK/xwiki/db.dump"
    archive "$SRV/xwiki/data" "$WORK/xwiki/data.tar.gz"
    cp -p "$SRV/xwiki/cacerts" "$WORK/xwiki/cacerts"
    start_stopped
}

backup_gitlab() {
    log "gitlab: gitlab-backup create (instance keeps running)"
    local marker="$WORK/.gitlab-marker" gl_tar
    touch "$marker"
    # STRATEGY=copy: snapshot to a temp dir first, avoids "file changed as we read it";
    # CRON=1: quiet output. Result lands in /var/opt/gitlab/backups = /srv/gitlab/data/backups.
    docker exec gitlab gitlab-backup create STRATEGY=copy CRON=1
    gl_tar="$(find "$SRV/gitlab/data/backups" -maxdepth 1 -name '*_gitlab_backup.tar' -newer "$marker")"
    [[ -n "$gl_tar" && -f "$gl_tar" ]] || die "no new gitlab backup tar found in $SRV/gitlab/data/backups"
    mv "$gl_tar" "$WORK/gitlab/"       # out of the data volume: one copy, in the set
    rm -f "$marker"
    GITLAB_TAR="$(basename "$gl_tar")"
    install -m 600 "$SRV/gitlab/config/gitlab-secrets.json" "$WORK/gitlab/gitlab-secrets.json"
    install -m 600 "$SRV/gitlab/config/gitlab.rb" "$WORK/gitlab/gitlab.rb"
    # subshell: the glob must expand inside config/, tar does not glob member names itself
    (cd "$SRV/gitlab/config" && tar --numeric-owner -czf "$WORK/gitlab/ssh-host-keys.tar.gz" ssh_host_*)
}

backup_proxy_and_env() {
    log "proxy: archive certs, config, data (Caddy keeps running, files are static)"
    archive "$SRV/proxy/certs"  "$WORK/proxy/certs.tar.gz"
    archive "$SRV/proxy/config" "$WORK/proxy/config.tar.gz"
    archive "$SRV/proxy/data"   "$WORK/proxy/data.tar.gz"
    log "env: copy the four .env files"
    local s
    for s in gitlab lldap openproject xwiki; do
        install -m 600 "$REPO/services/$s/.env" "$WORK/env/$s.env"
    done
}

write_manifest() {
    log "manifest and checksums"
    local s
    {
        printf 'created: %s\n' "$STAMP"
        printf 'host: %s\n' "$(hostname)"
        # safe.directory: the clone belongs to the admin, this runs as root
        printf 'repo_commit: %s\n' "$(git -C "$REPO" -c safe.directory="$REPO" rev-parse HEAD)"
        printf 'gitlab_backup: %s\n' "$GITLAB_TAR"
        for s in "${STACKS[@]}"; do
            printf 'images[%s]: %s\n' "$s" "$(compose "$s" config --images | sort -u | tr '\n' ' ')"
        done
    } >"$WORK/manifest.txt"
    # relative paths so that `sha256sum -c SHA256SUMS` works from inside the set
    (cd "$WORK" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort \
        | xargs -d '\n' sha256sum >SHA256SUMS)
}

finalize() {
    chown -R "root:$BACKUP_GROUP" "$WORK"
    chmod -R u=rwX,g=rX,o= "$WORK"     # dirs 750, files 640 (X: execute bit on directories only)
    mv "$WORK" "$SET"                  # rename is atomic: the set is either complete or absent
    log "plaintext set complete: $SET ($(du -sh "$SET" | cut -f1))"
}

encrypt_set() {
    log "encrypt: $STAMP.tar.age (recipients: $RECIPIENTS)"
    # tar keeps the <stamp>/ prefix, so a restore unpacks into a directory of the same name.
    # pipefail makes a tar error fail the pipeline; .partial keeps prune away until the mv.
    tar --numeric-owner -C "$BACKUP_ROOT" -cf - "$STAMP" | age -R "$RECIPIENTS" -o "$SET.tar.age.partial"
    chown "root:$BACKUP_GROUP" "$SET.tar.age.partial"
    chmod 640 "$SET.tar.age.partial"
    mv "$SET.tar.age.partial" "$SET.tar.age"
    rm -rf "$SET"                      # the only readable copy of the secrets - gone once encrypted
    log "encrypted set: $SET.tar.age ($(du -sh "$SET.tar.age" | cut -f1))"
}

prune() {
    log "prune: keep the $KEEP newest sets"
    local sets old
    mapfile -t sets < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type f \
        -name '[0-9]*T[0-9]*Z.tar.age' -printf '%f\n' | sort -r)   # by name, never by mtime
    for old in "${sets[@]:$KEEP}"; do
        rm -f "${BACKUP_ROOT:?}/$old"
        log "removed $old"
    done
    # leftovers of earlier failed runs (everything still *.partial is older than this set)
    local stale
    while IFS= read -r stale; do
        rm -rf "$stale"
        log "removed stale $(basename "$stale")"
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -name '*.partial' ! -newer "$SET.tar.age")
}

check_preconditions
backup_lldap
backup_openproject
backup_xwiki
backup_gitlab
backup_proxy_and_env
write_manifest
finalize
encrypt_set
prune
log "done"
