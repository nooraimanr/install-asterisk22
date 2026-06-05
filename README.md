# Asterisk 22 Installer

A production-ready, single-command shell script that installs **Asterisk 22 from source** on **Oracle Linux 9** with **MySQL 8.4** support.

---

## Requirements

| | |
|---|---|
| **OS** | Oracle Linux 9 (also compatible with RHEL 9, Rocky Linux 9, AlmaLinux 9) |
| **Database** | MySQL 8.4 |
| **Privileges** | Must be run as `root` or via `sudo` |
| **Disk space** | At least 4 GB free under `/usr/src` |
| **Tools** | `dnf`, `wget`, `rpm`, `tar`, `curl` (all present on a standard OL9 install) |

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/nooraimanr/install-asterisk22/refs/heads/main/install_asterisk22.sh | bash
```

You will be prompted to confirm before anything is installed.

---

## Usage

### Interactive (default)
```bash
curl -fsSL https://raw.githubusercontent.com/nooraimanr/install-asterisk22/refs/heads/main/install_asterisk22.sh | bash
```

### Unattended / CI
Skips the confirmation prompt — suitable for automated provisioning:
```bash
curl -fsSL https://raw.githubusercontent.com/nooraimanr/install-asterisk22/refs/heads/main/install_asterisk22.sh | bash -s -- --skip-confirm
```

### Dry run
Prints every command that *would* run without executing anything:
```bash
bash install_asterisk22.sh --dry-run
```

---

## What the Script Does

The installation runs in 6 clearly logged steps:

| Step | Action |
|------|--------|
| **1** | Install EPEL repository |
| **2** | Install core dependencies: OpenSSL, libxml2, libsrtp, unixODBC, MySQL 8.4 repo, mysql-devel, and related -devel RPMs |
| **3** | Download and verify the Asterisk 22 source tarball from `downloads.asterisk.org` |
| **4** | Run Asterisk's bundled `install_prereq` script |
| **5** | `./configure`, `menuselect`, parallel `make`, `make install`, `make samples`, `make config` |
| **6** | Write and enable the `asterisk.service` systemd unit, then verify the service starts |

### Enabled modules

The following modules are selected via `menuselect`:

- `format_mp3` — MP3 audio format support
- `res_config_mysql` — MySQL realtime configuration backend
- `codec_opus` — Opus audio codec
- `codec_silk` — SILK audio codec
- `codec_siren7` / `codec_siren14` — Siren codecs *(commercial; silently skipped if sources unavailable)*
- `codec_g729a` — G.729a codec *(commercial; silently skipped if sources unavailable)*
- `ENABLE_SRTP_AES_192` / `ENABLE_SRTP_AES_256` / `ENABLE_SRTP_AES_GCM` — Extended SRTP cipher suites

---

## Safety Features

- **`set -euo pipefail`** — script aborts immediately on any unhandled error, unset variable, or broken pipe
- **Preflight checks** — verifies root privileges, OS family, available disk space, and required base tools before touching anything
- **Idempotent installs** — EPEL, MySQL repo, and all RPM packages are checked before install; safe to re-run on a partially completed setup
- **Tarball integrity check** — `gzip -t` validates the download before extraction
- **SIGPIPE-safe directory resolution** — uses `grep -m1` instead of `head -1` when reading the tarball listing to avoid silent exits under `set -euo pipefail`
- **`curl | bash` compatible prompt** — reads confirmation from `/dev/tty` when stdin is a pipe, so the interactive prompt works correctly in all invocation modes
- **Existing service backup** — if `/etc/systemd/system/asterisk.service` already exists, it is backed up to `.bak` before being overwritten
- **Post-start health check** — waits 3 seconds after `systemctl enable --now` and verifies the service is active; dumps the last 30 journal lines if it fails
- **Parallel build** — uses `nproc` cores automatically to shorten compile time

---

## Logs

Every run writes a full timestamped log to:

```
/var/log/asterisk22_install_YYYYMMDD_HHMMSS.log
```

If anything fails, check this file first.

---

## Post-Installation

```bash
# Check service status
systemctl status asterisk

# Connect to the Asterisk CLI
asterisk -rvvv

# Configuration files
ls /etc/asterisk/

# Reload Asterisk config without restarting
systemctl reload asterisk
```

---

## Systemd Service

The script installs the following service unit at `/etc/systemd/system/asterisk.service`:

```ini
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
```

---

## Troubleshooting

**Script aborts silently after download**
Check the log file. A corrupt tarball will trigger `gzip -t` failure — delete `/usr/src/asterisk/asterisk-22-current.tar.gz` and re-run.

**"No interactive terminal detected" error**
You're running in a fully headless environment (no `/dev/tty`). Use `--skip-confirm`:
```bash
curl -fsSL ... | bash -s -- --skip-confirm
```

**`menuselect` shows a module as unavailable**
Commercial codecs (g729a, siren7, siren14) require separate source files not included in the Asterisk tarball. `menuselect` will skip them without failing the build — this is expected.

**Asterisk fails to start after install**
Run `journalctl -u asterisk -n 50 --no-pager` and check `/etc/asterisk/asterisk.conf` for misconfigured paths or missing files.

---

## License

MIT
