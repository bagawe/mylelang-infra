#!/usr/bin/env bash
# Bootstrap a blank Ubuntu/Debian VPS for My Lelang (dev).
#
# Typical flow on a fresh VPS:
#   sudo apt-get update && sudo apt-get install -y git
#   git clone <URL_REPO_INFRA> /opt/mylelang/mylelang-infra
#   cd /opt/mylelang/mylelang-infra
#   ./scripts/bootstrap-vps.sh
#
# Idempotent where practical. Safe to re-run.
set -euo pipefail

SWAP_SIZE_GB="${SWAP_SIZE_GB:-4}"
SWAPFILE="${SWAPFILE:-/swapfile}"
TARGET_USER="${SUDO_USER:-$USER}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Jalankan dengan sudo: sudo ./scripts/bootstrap-vps.sh"
  fi
}

detect_os() {
  [[ -f /etc/os-release ]] || die "Tidak menemukan /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ok "OS: ${PRETTY_NAME}" ;;
    *) die "OS tidak didukung otomatis (${PRETTY_NAME:-unknown}). Script ini untuk Ubuntu/Debian." ;;
  esac
  DOCKER_DISTRO="$ID"
  DOCKER_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$DOCKER_CODENAME" ]] || die "VERSION_CODENAME kosong; OS terlalu tua?"
}

install_base() {
  log "Update apt + install tool dasar"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg git ufw openssl
  ok "Base packages terpasang"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^docker\.service'; then
    ok "Docker sudah terpasang — skip install"
    return
  fi

  log "Install Docker Engine (repo resmi)"
  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 \
    podman-docker containerd runc 2>/dev/null || true

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/${DOCKER_DISTRO} \
    ${DOCKER_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  ok "Docker CE + Compose plugin terpasang"
}

enable_docker() {
  log "Enable & start docker.service"
  [[ -f /lib/systemd/system/docker.service || -f /usr/lib/systemd/system/docker.service ]] \
    || die "docker.service masih tidak ada setelah install"

  systemctl enable --now docker
  systemctl is-active --quiet docker || die "docker.service gagal start"
  ok "docker.service aktif"

  getent group docker >/dev/null || groupadd docker
  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    ok "User ${TARGET_USER} sudah di group docker"
  else
    usermod -aG docker "$TARGET_USER"
    ok "User ${TARGET_USER} ditambahkan ke group docker"
    warn "Logout/login SSH (atau newgrp docker) agar group aktif tanpa sudo"
  fi

  docker --version
  docker compose version
}

setup_swap() {
  log "Swap ${SWAP_SIZE_GB}G"
  if swapon --show | grep -q .; then
    ok "Swap sudah ada — skip"
    swapon --show
    free -h
    return
  fi

  if [[ -f "$SWAPFILE" ]]; then
    warn "${SWAPFILE} ada tapi belum aktif — mencoba swapon"
  else
    fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE" || \
      dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
  fi
  swapon "$SWAPFILE"
  grep -qF "$SWAPFILE" /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  ok "Swap aktif"
  free -h
}

setup_firewall() {
  log "Firewall UFW (OpenSSH + 80 + 443)"
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  ufw status
  ok "UFW aktif"
}

prepare_dirs() {
  log "Siapkan /opt/mylelang"
  mkdir -p /opt/mylelang
  chown "${TARGET_USER}:${TARGET_USER}" /opt/mylelang
  ok "/opt/mylelang milik ${TARGET_USER}"
}

print_next() {
  cat <<EOF

============================================================
Bootstrap VPS selesai.

Langkah berikutnya (sebagai user ${TARGET_USER}):
  1. Logout SSH lalu login lagi (agar group docker aktif)
  2. Verifikasi:  docker ps
  3. Clone backend + web di /opt/mylelang (lihat README §D)
  4. Siapkan env/dev.env (scp dari laptop atau dari example)
  5. Jalankan:  ./scripts/deploy.sh
============================================================
EOF
}

main() {
  need_root
  detect_os
  install_base
  install_docker
  enable_docker
  setup_swap
  setup_firewall
  prepare_dirs
  print_next
}

main "$@"
