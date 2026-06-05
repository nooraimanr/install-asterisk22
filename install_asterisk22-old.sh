#!/usr/bin/env bash
# =============================================================================
#  Asterisk 22 Installer — Oracle Linux 9 / MySQL 8.4
#  Usage:  curl -fsSL https://your-host/install_asterisk22.sh | bash
#          -- or --
#          bash install_asterisk22.sh [--dry-run] [--skip-confirm]
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${GREEN}▶  $*${RESET}"; }

# ── argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_CONFIRM=false
for arg in "$@"; do
  case $arg in
    --dry-run)      DRY_RUN=true ;;
    --skip-confirm) SKIP_CONFIRM=true ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

run() {
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} $*"
  else
    eval "$@"
  fi
}

# ── log file ──────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/asterisk22_install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Full log → $LOG_FILE"

# ── preflight checks ──────────────────────────────────────────────────────────
step "Preflight checks"

[[ $EUID -eq 0 ]] || die "This script must be run as root (or via sudo)."

# OS check
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == "ol" || "${ID:-}" == "rhel" || "${ID:-}" == "centos" || "${ID:-}" == "rocky" || "${ID:-}" == "almalinux" ]] \
    || warn "Detected OS '${ID:-unknown}' — this script targets Oracle/RHEL 9 variants."
  [[ "${VERSION_ID:-0}" == 9* ]] \
    || warn "Detected OS version '${VERSION_ID:-?}' — targeting v9.x."
else
  warn "/etc/os-release not found; skipping OS check."
fi

# Required base tools
for cmd in dnf wget rpm tar curl; do
  command -v "$cmd" &>/dev/null || die "Required command '$cmd' not found."
done

# Disk space: require at least 4 GB free in /usr/src
AVAILABLE_KB=$(df --output=avail /usr/src 2>/dev/null | tail -1 || echo 0)
(( AVAILABLE_KB >= 4194304 )) || warn "Less than 4 GB free under /usr/src (${AVAILABLE_KB} kB). Build may fail."

success "Preflight passed."

# ── confirmation prompt ───────────────────────────────────────────────────────
if ! $SKIP_CONFIRM && ! $DRY_RUN; then
  echo
  echo -e "${BOLD}This script will:${RESET}"
  echo "  • Install EPEL, MySQL 8.4 repos & various -devel packages"
  echo "  • Download & compile Asterisk 22 from source"
  echo "  • Install Asterisk system-wide and enable it via systemd"
  echo
  read -rp "Continue? [y/N] " _CONFIRM
  [[ "${_CONFIRM,,}" == "y" || "${_CONFIRM,,}" == "yes" ]] || { info "Aborted."; exit 0; }
fi

# ── helper: safe dnf install ──────────────────────────────────────────────────
dnf_install() {
  run dnf install -y "$@" || die "dnf install failed for: $*"
}

rpm_install() {
  local pkg="$1"
  local url="$2"
  local dest="/usr/src/asterisk/$(basename "$url")"
  if rpm -q "$pkg" &>/dev/null; then
    info "$pkg already installed — skipping."
    return 0
  fi
  run wget -q -O "$dest" "$url" || die "wget failed: $url"
  run rpm -Uvh "$dest"          || die "rpm install failed: $dest"
}

# ── 1. EPEL ───────────────────────────────────────────────────────────────────
step "1/6  Installing EPEL"
if rpm -q epel-release &>/dev/null; then
  info "EPEL already installed — skipping."
else
  dnf_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
fi
success "EPEL ready."

# ── 2. Core dependencies ──────────────────────────────────────────────────────
step "2/6  Installing core dependencies"
dnf_install \
  openssl openssl-devel libxml2-devel cryptopp-devel \
  libpcap libsrtp unixODBC \
  htop iftop lynx mlocate screen

# MySQL 8.4 repo + devel
if ! rpm -q mysql84-community-release &>/dev/null; then
  dnf_install "https://dev.mysql.com/get/mysql84-community-release-el9-2.noarch.rpm"
else
  info "MySQL 8.4 repo already present."
fi
dnf_install mysql-devel mysql-connector-odbc

# Packages not in standard repos — fetched as RPMs
run mkdir -p /usr/src/asterisk

rpm_install unixODBC-devel \
  "https://mirror.stream.centos.org/9-stream/CRB/x86_64/os/Packages/unixODBC-devel-2.3.9-4.el9.x86_64.rpm"

rpm_install libpcap-devel \
  "https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/x86_64/codeready-builder/os/Packages/l/libpcap-devel-1.10.0-4.el9.x86_64.rpm"

rpm_install libsrtp-devel \
  "https://mirror.stream.centos.org/9-stream/CRB/x86_64/os/Packages/libsrtp-devel-2.3.0-8.el9.x86_64.rpm"

success "Core dependencies installed."

# ── 3. Download & extract Asterisk 22 ────────────────────────────────────────
step "3/6  Downloading Asterisk 22"
cd /usr/src/asterisk

TARBALL="asterisk-22-current.tar.gz"

if [[ ! -f "$TARBALL" ]]; then
  run wget -q --show-progress \
    "https://downloads.asterisk.org/pub/telephony/asterisk/${TARBALL}" \
    || die "Failed to download Asterisk tarball."
else
  info "Tarball already present — skipping download."
fi

# Verify tarball is a valid gzip before extracting
if ! $DRY_RUN; then
  gzip -t "$TARBALL" 2>/dev/null || die "Tarball appears corrupt. Delete it and re-run."
fi

run tar -zxf "$TARBALL" || die "Extraction failed."

# Resolve the actual extracted directory name
# Using grep -m1 instead of head -1 to avoid SIGPIPE under set -euo pipefail
if ! $DRY_RUN; then
  AST_DIR=$(tar -tzf "$TARBALL" 2>/dev/null | grep -m1 '.' | cut -d/ -f1 || true)
  [[ -n "$AST_DIR" ]] || die "Could not determine extracted directory name from tarball."
  [[ -d "$AST_DIR" ]] || die "Expected source directory '$AST_DIR' not found after extraction."
  info "Asterisk source directory: $AST_DIR"
else
  AST_DIR="asterisk-22-x.x"   # placeholder for dry-run
fi

success "Source ready in /usr/src/asterisk/${AST_DIR}."

# ── 4. Install Asterisk prerequisites ────────────────────────────────────────
step "4/6  Running install_prereq"
if ! $DRY_RUN; then
  cd "/usr/src/asterisk/${AST_DIR}/contrib/scripts"
  run ./install_prereq install || die "install_prereq failed."
  cd "/usr/src/asterisk/${AST_DIR}"
else
  run cd "/usr/src/asterisk/${AST_DIR}"
fi
success "install_prereq complete."

# ── 5. Configure, menuselect & build ─────────────────────────────────────────
step "5/6  Configuring & building Asterisk"

run ./configure --with-jansson-bundled \
  || die "./configure failed. Check $LOG_FILE for details."

run make menuselect.makeopts \
  || die "menuselect.makeopts failed. Check $LOG_FILE for details."

# menuselect: enable desired modules
# Codecs g729a / siren7 / siren14 are commercial — they will be silently
# skipped by menuselect if the sources are unavailable; no build error results.
run /usr/src/asterisk/asterisk-22.9.0/menuselect/menuselect \
  --enable format_mp3 \
  --enable res_config_mysql \
  --enable codec_opus \
  --enable codec_silk \
  --enable codec_siren7 \
  --enable codec_siren14 \
  --enable codec_g729a \
  --enable ENABLE_SRTP_AES_192 \
  --enable ENABLE_SRTP_AES_256 \
  --enable ENABLE_SRTP_AES_GCM \
  menuselect.makeopts \
  || die "menuselect failed."

# Use all available CPU cores for the build
NPROC=$(nproc 2>/dev/null || echo 1)
info "Building with ${NPROC} parallel job(s)…"
run make -j"${NPROC}"        || die "'make' failed. Check $LOG_FILE."
run make install              || die "'make install' failed."
run make samples              || die "'make samples' failed."
run make config               || die "'make config' failed."
success "Asterisk built and installed."

# ── 6. Systemd service ────────────────────────────────────────────────────────
step "6/6  Configuring systemd service"

SVCFILE="/etc/systemd/system/asterisk.service"

if [[ -f "$SVCFILE" ]]; then
  warn "$SVCFILE already exists — backing up to ${SVCFILE}.bak"
  run cp "$SVCFILE" "${SVCFILE}.bak"
fi

if ! $DRY_RUN; then
cat > "$SVCFILE" << 'SVCEOF'
[Unit]
Description=Asterisk PBX And Telephony Daemon
Wants=network.target
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
ExecStop=/usr/sbin/asterisk -rx 'core stop now'
ExecReload=/usr/sbin/asterisk -rx 'core reload'
LimitNOFILE=65535
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
else
  run "cat > $SVCFILE << 'SVCEOF' ... SVCEOF"
fi

run systemctl daemon-reload            || die "systemctl daemon-reload failed."
run systemctl enable --now asterisk    || die "Failed to enable/start asterisk service."

# Brief wait then verify
if ! $DRY_RUN; then
  sleep 3
  if systemctl is-active --quiet asterisk; then
    success "asterisk.service is running."
  else
    warn "asterisk.service did not start cleanly. Checking journal…"
    journalctl -u asterisk -n 30 --no-pager || true
    die "Asterisk failed to start. Review the journal output above."
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Asterisk 22 installation complete!            ${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════${RESET}"
echo
echo -e "  Service status : ${CYAN}systemctl status asterisk${RESET}"
echo -e "  CLI access     : ${CYAN}asterisk -rvvv${RESET}"
echo -e "  Config dir     : ${CYAN}/etc/asterisk/${RESET}"
echo -e "  Full log       : ${CYAN}${LOG_FILE}${RESET}"
echo
