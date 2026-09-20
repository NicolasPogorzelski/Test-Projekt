#!/usr/bin/env bash

set -euo pipefail

# Host baseline for the lab.test stack on Debian 13 (trixie).
# Usage: sudo ./bootstrap.sh          (from the admin account, never as plain root)
#
# Turns a fresh host into the state described in docs/security.md "Host":
# sshd hardening, unattended-upgrades incl. Docker origin, Docker CE from the
# Docker repository (key fingerprint verified), apt pin, userns-remap with a
# fixed subordinate range, read-only sudoers rule, /srv layout, Docker networks,
# group backup for the admin, nightly backup timer.
# Every step checks first and only acts when needed, so re-running is safe and
# reports "skip" everywhere on a host that is already prepared.
#
# NOT done here (see README runbook): admin user + SSH key, Hetzner firewall,
# deploy key, certificates, .env files.

ADMIN_USER="${SUDO_USER:-}"          # the account that keeps SSH access (AllowUsers)
REMAP_USER="dockremap"
REMAP_BASE=100000                    # container UID 0 -> host UID 100000; bind mounts use BASE + container UID
REMAP_COUNT=65536
SRV=/srv
KEYRING=/etc/apt/keyrings/docker.asc
# Primary fingerprint of "Docker Release (CE deb) <docker@docker.com>" (key ID 0EBFCD88).
# The Docker docs no longer print it; value verified on the reference host 2026-09-18.
DOCKER_GPG_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
FAILS=0

log()  { printf '==> %s\n' "$*"; }
skip() { printf '    skip: %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# write_if_changed <path> <mode>   content on stdin
# Returns 0 if the file was (re)written, 1 if content and mode already match,
# so the caller decides whether a reload/restart is needed.
write_if_changed() {
    local dst="$1" mode="$2" tmp
    tmp="$(mktemp)"
    cat >"$tmp"
    if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst" && [[ "$(stat -c %a "$dst")" == "$mode" ]]; then
        rm -f "$tmp"
        skip "$dst"
        return 1
    fi
    install -m "$mode" "$tmp" "$dst"
    rm -f "$tmp"
    log "wrote $dst (mode $mode)"
    return 0
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# ensure_pkgs <pkg>...   installs only what is missing
ensure_pkgs() {
    local missing=() p
    for p in "$@"; do
        pkg_installed "$p" || missing+=("$p")
    done
    if ((${#missing[@]} == 0)); then
        skip "packages present: $*"
        return
    fi
    log "installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
}

# t <description> <command...>   one self-test line, counts failures
t() {
    if "${@:2}" >/dev/null 2>&1; then
        printf '  PASS  %s\n' "$1"
    else
        printf '  FAIL  %s\n' "$1"
        FAILS=$((FAILS + 1))
    fi
}

check_preconditions() {
    log "preconditions"
    [[ $EUID -eq 0 ]] || die "run with sudo"
    [[ -n "$ADMIN_USER" && "$ADMIN_USER" != root ]] \
        || die "run via sudo from the admin account (SUDO_USER is used for AllowUsers)"
    id "$ADMIN_USER" >/dev/null 2>&1 || die "user $ADMIN_USER does not exist"
    local home
    home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [[ -s "$home/.ssh/authorized_keys" ]] \
        || die "$home/.ssh/authorized_keys is empty - sshd hardening would lock you out"
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "${VERSION_CODENAME:-}" == trixie ]] || die "expected Debian 13 (trixie), got ${VERSION_CODENAME:-unknown}"
    [[ "$(dpkg --print-architecture)" == amd64 ]] || die "expected amd64"
    CODENAME="$VERSION_CODENAME"
}

harden_sshd() {
    log "sshd hardening"
    local dst=/etc/ssh/sshd_config.d/10-hardening.conf
    if write_if_changed "$dst" 644 <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
AllowUsers $ADMIN_USER
EOF
    then
        # an unknown keyword is a syntax error: test before the running sshd sees it
        if sshd -t; then
            systemctl reload ssh          # reload keeps the current session open
            log "sshd reloaded"
        else
            rm -f "$dst"
            die "sshd -t rejected $dst - removed it, running sshd untouched"
        fi
    fi
}

configure_unattended_upgrades() {
    log "unattended-upgrades"
    ensure_pkgs unattended-upgrades
    write_if_changed /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    # 50unattended-upgrades stays at the package default (Debian origins);
    # the Docker origin is added in its own drop-in so package upgrades never clash.
    write_if_changed /etc/apt/apt.conf.d/52unattended-upgrades-docker 644 <<'EOF' || true
Unattended-Upgrade::Origins-Pattern {
    "origin=Docker";
};
EOF
}

add_docker_repo() {
    log "Docker apt repository"
    ensure_pkgs ca-certificates curl gnupg
    install -d -m 755 /etc/apt/keyrings
    local tmp fpr
    tmp="$(mktemp)"
    curl -fsSL https://download.docker.com/linux/debian/gpg -o "$tmp"
    # first "fpr" record = primary key; must match the pinned value before the key is trusted
    fpr="$(gpg --show-keys --with-colons --with-fingerprint "$tmp" | awk -F: '$1 == "fpr" { print $10; exit }')"
    if [[ "$fpr" != "$DOCKER_GPG_FPR" ]]; then
        rm -f "$tmp"
        die "Docker GPG key fingerprint mismatch: got ${fpr:-none}, expected $DOCKER_GPG_FPR"
    fi
    write_if_changed "$KEYRING" 644 <"$tmp" || true
    rm -f "$tmp"

    local changed=0
    if write_if_changed /etc/apt/sources.list.d/docker.sources 644 <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $CODENAME
Components: stable
Signed-By: $KEYRING
EOF
    then changed=1; fi

    # only docker-ce/-cli follow the 5:29.* scheme; containerd.io and the plugins
    # have their own versioning and are deliberately not pinned (docs/problems.md)
    write_if_changed /etc/apt/preferences.d/docker-ce 644 <<'EOF' || true
Package: docker-ce docker-ce-cli
Pin: version 5:29.*
Pin-Priority: 990
EOF
    if ((changed)) || ! pkg_installed docker-ce; then
        apt-get -qq update
    fi
}

prepare_userns() {
    log "userns-remap user and subordinate ranges"
    if getent passwd "$REMAP_USER" >/dev/null; then
        skip "user $REMAP_USER exists"
    else
        useradd --system --shell /usr/sbin/nologin --home-dir /nonexistent --no-create-home "$REMAP_USER"
        log "created user $REMAP_USER"
    fi
    # Fixed range so that every documented host UID (e.g. 101000 for Caddy) stays
    # valid after a rebuild; Docker's own allocation would pick "the next free" one.
    local f line="${REMAP_USER}:${REMAP_BASE}:${REMAP_COUNT}"
    for f in /etc/subuid /etc/subgid; do
        if grep -q "^${REMAP_USER}:" "$f" 2>/dev/null; then
            grep -qx "$line" "$f" || die "$f: $REMAP_USER has a different range than $line - fix by hand"
            skip "$f has $line"
        else
            echo "$line" >>"$f"
            log "added $line to $f"
        fi
        if grep -v "^${REMAP_USER}:" "$f" | grep -q ":${REMAP_BASE}:"; then
            warn "$f: another user shares the range starting at $REMAP_BASE (see docs/problems.md P-008)"
        fi
    done
}

install_docker() {
    log "Docker CE"
    local was_installed=0 daemon_changed=0
    pkg_installed docker-ce && was_installed=1
    install -d -m 755 /etc/docker
    # written BEFORE the package: the postinst starts dockerd, which then runs with
    # userns-remap from its first second - no image ever lands in the unmapped store
    if write_if_changed /etc/docker/daemon.json 644 <<EOF
{
  "userns-remap": "$REMAP_USER",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
    then daemon_changed=1; fi
    ensure_pkgs "${DOCKER_PKGS[@]}"
    if ((was_installed && daemon_changed)); then
        systemctl restart docker
        log "docker restarted (daemon.json changed; live-restore keeps containers up)"
    fi
    # docker group = root without password or sudo log (ADR-0002)
    if id -nG "$ADMIN_USER" | grep -qw docker; then
        gpasswd -d "$ADMIN_USER" docker
        warn "removed $ADMIN_USER from group docker"
    fi
}

configure_sudoers() {
    log "sudoers docker-readonly"
    local dst=/etc/sudoers.d/docker-readonly tmp
    tmp="$(mktemp)"
    printf '%s ALL=(root) NOPASSWD: %s\n' "$ADMIN_USER" \
        "/usr/bin/docker ps, /usr/bin/docker ps -a, /usr/bin/docker info, /usr/bin/docker images, /usr/bin/docker logs *, /usr/bin/docker compose ls" \
        >"$tmp"
    visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers syntax check failed"; }
    write_if_changed "$dst" 440 <"$tmp" || true
    rm -f "$tmp"
    if [[ -f /etc/sudoers.d/90-cloud-init-users ]]; then
        log "note: /etc/sudoers.d/90-cloud-init-users present (cloud-init, root-only rule, left as is)"
    fi
}

create_srv_layout() {
    log "$SRV layout"
    # <relative dir>:<owner uid>  - owner 0 until the stack that uses it is added.
    # Under userns-remap host UID 0 is invisible to containers, so a directory a
    # container must write to belongs to REMAP_BASE + its container UID:
    # Caddy, lldap and OpenProject run as 1000, PostgreSQL (alpine) as 70;
    # GitLab Omnibus and XWiki (Tomcat) run as root (0) inside their containers.
    local u1000=$((REMAP_BASE + 1000))
    local dirs=(
        "proxy/certs:0"
        "proxy/data:$u1000"
        "proxy/config:$u1000"
        "lldap:$u1000"
        "gitlab/config:$REMAP_BASE"
        "gitlab/config/trusted-certs:$REMAP_BASE"    # pre-created: reconfigure writes rehash symlinks here
        "gitlab/logs:$REMAP_BASE"
        "gitlab/data:$REMAP_BASE"
        "xwiki/data:$REMAP_BASE"                    # XWiki runs as container root (image has no user)
        "xwiki/db:$((REMAP_BASE + 70))"             # postgres user in the alpine image
        "openproject/assets:$u1000"                 # OpenProject app user
        "openproject/db:$((REMAP_BASE + 70))"       # postgres user in the alpine image
        "backups:0"
    )
    local entry dir owner
    for entry in "${dirs[@]}"; do
        dir="$SRV/${entry%%:*}"
        owner="${entry##*:}"
        if [[ -d "$dir" && "$(stat -c %u "$dir")" == "$owner" ]]; then
            skip "$dir"
        else
            install -d -m 755 "$dir"
            chown "$owner:$owner" "$dir"       # not recursive: existing service data keeps its owner
            log "created $dir (owner $owner)"
        fi
    done
}

create_networks() {
    log "Docker networks"
    if docker network inspect edge >/dev/null 2>&1; then
        skip "network edge"
    else
        docker network create --driver bridge edge >/dev/null    # publishes ports -> must NOT be internal (P-004)
        log "created network edge"
    fi
    if docker network inspect ldap >/dev/null 2>&1; then
        skip "network ldap"
    else
        docker network create --driver bridge --internal ldap >/dev/null
        log "created network ldap (internal)"
    fi
}

install_tools() {
    log "tools"
    ensure_pkgs git rsync age          # git: clone via deploy key; rsync: off-host copy; age: backup encryption
}

delegate_backup_group() {
    log "backup group"
    # backup.sh writes every set as root:backup 0750/0640 (ADR-0008). Debian's
    # system group "backup" (GID 34) exists for exactly this delegation; membership
    # lets the admin pull sets off-host without root. Takes effect at the next login.
    if id -nG "$ADMIN_USER" | grep -qw backup; then
        skip "$ADMIN_USER in group backup"
    else
        usermod -aG backup "$ADMIN_USER"
        log "added $ADMIN_USER to group backup (re-login required)"
    fi
}

install_backup_timer() {
    log "backup timer"
    # The unit needs the absolute path of this checkout, which contains the admin's
    # home; writing it here keeps that path out of the repository. A missed run
    # (host down at 03:00) is made up after boot (Persistent); the random delay is
    # the usual courtesy so that several hosts never start at the same second.
    local repo changed=0
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if write_if_changed /etc/systemd/system/backup.service 644 <<EOF
[Unit]
Description=Application-consistent backup of the lab.test stacks (scripts/backup.sh)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$repo/scripts/backup.sh
Nice=10
EOF
    then changed=1; fi
    if write_if_changed /etc/systemd/system/backup.timer 644 <<'EOF'
[Unit]
Description=Nightly run of backup.service

[Timer]
OnCalendar=*-*-* 03:00:00 UTC
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    then changed=1; fi
    ((changed)) && systemctl daemon-reload
    if systemctl is-enabled --quiet backup.timer && systemctl is-active --quiet backup.timer; then
        skip "backup.timer enabled and active"
    else
        systemctl enable --now backup.timer
        log "backup.timer enabled and started"
    fi
}

self_test() {
    log "self-test"
    local info nets sshd_cfg
    info="$(docker info --format '{{.SecurityOptions}} {{.LoggingDriver}} {{.LiveRestoreEnabled}}')"
    t "docker: userns-remap active" grep -q 'name=userns' <<<"$info"
    t "docker: log driver json-file" grep -q 'json-file' <<<"$info"
    t "docker: live-restore enabled" grep -q 'true' <<<"$info"
    t "docker: remapped root /var/lib/docker/$REMAP_BASE.$REMAP_BASE" test -d "/var/lib/docker/$REMAP_BASE.$REMAP_BASE"
    nets="$(docker network ls --format '{{.Name}} {{.Internal}}')"
    t "network edge, not internal" grep -qx 'edge false' <<<"$nets"
    t "network ldap, internal" grep -qx 'ldap true' <<<"$nets"
    t "$ADMIN_USER not in group docker" [ "$(id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -cx docker)" = 0 ]
    t "$ADMIN_USER in group backup" grep -qw backup <<<"$(id -nG "$ADMIN_USER")"
    t "backup.timer active" systemctl is-active --quiet backup.timer
    sshd_cfg="$(sshd -T)"
    t "sshd: passwordauthentication no" grep -qx 'passwordauthentication no' <<<"$sshd_cfg"
    t "sshd: permitrootlogin no" grep -qx 'permitrootlogin no' <<<"$sshd_cfg"
    t "sshd: allowusers $ADMIN_USER" grep -qx "allowusers $ADMIN_USER" <<<"$sshd_cfg"
    t "sudoers: NOPASSWD docker ps for $ADMIN_USER" grep -q 'NOPASSWD: /usr/bin/docker ps' <<<"$(sudo -l -U "$ADMIN_USER")"
    t "apt: docker-ce 5:29.* pinned at 990" grep -Eq '5:29\.[^ ]+ +990$' <<<"$(apt-cache policy docker-ce)"
    echo "  $(docker --version)"
    echo "  $(docker compose version)"
    ((FAILS == 0)) || die "$FAILS self-test check(s) failed"
    log "done"
}

check_preconditions
harden_sshd
configure_unattended_upgrades
add_docker_repo
prepare_userns
install_docker
configure_sudoers
create_srv_layout
create_networks
install_tools
delegate_backup_group
install_backup_timer
self_test
