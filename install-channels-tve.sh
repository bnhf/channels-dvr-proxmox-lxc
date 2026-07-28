#!/usr/bin/env bash
#
# install-channels-tve.sh
#
# Installs and configures Channels DVR (TV Everywhere edition) natively on
# Debian 13 (Trixie), intended for use inside a Proxmox Debian LXC container.
#
#   * Native install (no Docker assumptions)
#   * Channels DVR lives in /channels-dvr; its engine data (database, guide
#     data, tuner config) lives in /channels-dvr/data, matching the -dir
#     argument the official Docker image passes
#   * /channels-data is a separate empty directory, selected later from the
#     web UI as the recordings / imported media location
#   * Optional Google Chrome (required for TV Everywhere logins)
#   * Optional Samba shares for /channels-dvr and /channels-data
#   * Windows network discovery via wsdd (Samba implements no WS-Discovery)
#   * Intel Quick Sync (VA-API) detection and reporting
#
# The script is idempotent: re-running it will update configuration without
# duplicating users, repositories, timezone entries or Samba includes.
#
# Usage:
#   ./install-channels-tve.sh
#
# Non-interactive usage (all prompts answered from the environment):
#   NONINTERACTIVE=1 \
#   TIMEZONE=America/New_York \
#   CHANNELS_PORT=8089 \
#   INSTALL_CHROME=yes \
#   INSTALL_SAMBA=yes \
#   SAMBA_USER=channels \
#   SAMBA_PASSWORD='secret' \
#   INSTALL_TAILSCALE=yes \
#   ./install-channels-tve.sh
#

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="${0##*/}"

# Channels DVR application directory (created by the official installer).
readonly CHANNELS_DIR="/channels-dvr"
# Channels DVR's own internal data directory - database, guide data and tuner
# configuration live here. The official installer creates it as a sibling of
# the versioned binary directories, and the official Docker image's run.sh
# passes this same path via -dir and runs with it as the working directory;
# this script does the same for parity (see install_systemd_unit).
readonly CHANNELS_ENGINE_DATA_DIR="${CHANNELS_DIR}/data"
# Separate, empty directory offered to the user for recordings / imported
# media - unrelated to CHANNELS_ENGINE_DATA_DIR above, selected later from the
# web UI.
readonly CHANNELS_DATA_DIR="/channels-data"

# Runtime configuration consumed by the systemd unit.
readonly CHANNELS_DEFAULTS="/etc/default/channels-dvr"
readonly CHANNELS_UNIT="/etc/systemd/system/channels-dvr.service"
readonly CHANNELS_SERVICE="channels-dvr.service"

# Official Channels DVR bootstrap installer.
readonly CHANNELS_SETUP_URL="https://getchannels.com/dvr/setup.sh"

# Google Chrome APT repository. The paths below intentionally match the ones
# the google-chrome-stable package manages itself, so its post-install hook
# rewrites our files rather than adding a second, duplicate source.
readonly CHROME_KEY_URL="https://dl.google.com/linux/linux_signing_key.pub"
readonly CHROME_KEYRING="/etc/apt/keyrings/google-chrome.gpg"
readonly CHROME_SOURCE="/etc/apt/sources.list.d/google-chrome.list"

# Samba configuration.
readonly SMB_CONF="/etc/samba/smb.conf"
readonly SMB_CHANNELS_CONF="/etc/samba/smb-channels.conf"
readonly SMB_INCLUDE_LINE="include = ${SMB_CHANNELS_CONF}"
readonly SMB_INCLUDE_MARKER="# --- Channels DVR shares (managed by ${SCRIPT_NAME}) ---"

# Windows discovery daemon. Trixie's native 'wsdd2' puts its WS-Discovery
# metadata endpoint on TCP 3702 instead of the standard TCP 5357; Windows'
# built-in "Network Discovery" firewall rule never allows that port outbound,
# so wsdd2 answers every Probe correctly but Explorer still never shows the
# share. The Python 'wsdd' package uses the standard port and works, but was
# removed from Trixie's own repos entirely - not even present as a candidate -
# so it is fetched directly from the Debian archive pool, which still serves
# old builds after a package is dropped from every active suite.
readonly WSDD_PACKAGE="wsdd"
readonly WSDD_DEB_URL="http://deb.debian.org/debian/pool/main/w/wsdd/wsdd_0.7.0-2.1_all.deb"

# Official Tailscale installer (adds the repo and installs the package).
readonly TAILSCALE_INSTALL_URL="https://tailscale.com/install.sh"
# tailscaled cannot build a tunnel without this device; in an LXC it must be
# exposed from the Proxmox host.
readonly TUN_DEVICE="/dev/net/tun"

# Reference for mounting remote CIFS/SMB shares into an unprivileged LXC. The
# whole procedure is host-side, so the installer only points at it.
readonly CIFS_TUTORIAL_URL="https://forum.proxmox.com/threads/tutorial-unprivileged-lxcs-mount-cifs-shares.101795/post-555014"

# Packages required for Intel Quick Sync (VA-API) hardware transcoding.
readonly QSV_PACKAGES=(intel-media-va-driver vainfo)

# Minimal package set required before third-party repositories can be added.
readonly BOOTSTRAP_PACKAGES=(ca-certificates curl gnupg)

# Render node inspected for Intel Quick Sync support.
readonly DRI_RENDER_NODE="/dev/dri/renderD128"

# Defaults for interactive prompts.
readonly DEFAULT_PORT="8089"
readonly DEFAULT_HOST="0.0.0.0"

# ---------------------------------------------------------------------------
# Global state (populated by the prompt phase, reported in the summary)
# ---------------------------------------------------------------------------

TIMEZONE="${TIMEZONE:-}"
CHANNELS_PORT="${CHANNELS_PORT:-}"
CHANNELS_HOST="${CHANNELS_HOST:-}"
INSTALL_CHROME="${INSTALL_CHROME:-}"
INSTALL_SAMBA="${INSTALL_SAMBA:-}"
INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-}"
SAMBA_USER="${SAMBA_USER:-}"
SAMBA_PASSWORD="${SAMBA_PASSWORD:-}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
ALLOW_UNSUPPORTED_OS="${ALLOW_UNSUPPORTED_OS:-0}"

CHANNELS_BINARY=""      # Resolved path used for ExecStart=
QUICKSYNC_DETECTED="no" # Reported in the final summary
WSDD_STATUS="not installed" # Windows discovery daemon state, reported in summary
TAILSCALE_STATUS="not installed" # Tailscale state, reported in summary
APT_UPDATED=0           # Guard so `apt-get update` runs at most once per phase

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# Colours are only emitted when stdout is an interactive terminal.
if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_CYAN=$'\033[36m'
else
    readonly C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

section() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"; }
msg_info() { printf '%s  ->%s %s\n' "${C_CYAN}" "${C_RESET}" "$*"; }
msg_ok()   { printf '%s  OK%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
msg_warn() { printf '%s  !!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
msg_err()  { printf '%s  XX%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }

die() {
    msg_err "$*"
    exit 1
}

# Reports the failing command and line number for any unhandled error.
on_error() {
    local exit_code=$1 line=$2 command=$3
    msg_err "Failed at line ${line}: '${command}' exited with status ${exit_code}"
    msg_err "Installation aborted. Nothing was started; re-run the script after fixing the issue."
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

# Returns success when the script may prompt the user.
interactive() {
    [[ "${NONINTERACTIVE}" != "1" && -t 0 ]]
}

# ask <prompt> <default> -> echoes the answer (or the default)
ask() {
    local prompt=$1 default=$2 answer=""

    if ! interactive; then
        printf '%s' "${default}"
        return 0
    fi

    read -r -p "${C_BOLD}${prompt}${C_RESET} [${default}]: " answer || true
    printf '%s' "${answer:-${default}}"
}

# ask_yes_no <prompt> <default: yes|no> -> echoes "yes" or "no"
ask_yes_no() {
    local prompt=$1 default=$2 hint answer

    [[ "${default}" == "yes" ]] && hint="Y/n" || hint="y/N"

    if ! interactive; then
        printf '%s' "${default}"
        return 0
    fi

    while true; do
        read -r -p "${C_BOLD}${prompt}${C_RESET} [${hint}]: " answer || true
        answer="${answer:-${default}}"
        case "${answer,,}" in
            y|yes) printf 'yes'; return 0 ;;
            n|no)  printf 'no';  return 0 ;;
            *)     msg_warn "Please answer yes or no." ;;
        esac
    done
}

# ask_secret <prompt> -> echoes a non-empty password confirmed twice
ask_secret() {
    local prompt=$1 first="" second="" attempt

    for attempt in 1 2 3; do
        read -r -s -p "${C_BOLD}${prompt}${C_RESET}: " first || true
        printf '\n' >&2
        read -r -s -p "${C_BOLD}Verify ${prompt,}${C_RESET}: " second || true
        printf '\n' >&2

        if [[ -z "${first}" ]]; then
            msg_warn "Password must not be empty."
        elif [[ "${first}" != "${second}" ]]; then
            msg_warn "Passwords did not match."
        else
            printf '%s' "${first}"
            return 0
        fi
    done

    die "Failed to read a matching password after 3 attempts."
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "This installer must be run as root."
    msg_ok "Running as root."
}

require_debian_13() {
    local id="" version_id=""

    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported system."

    # shellcheck disable=SC1091
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    # shellcheck disable=SC1091
    version_id="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"

    if [[ "${id}" == "debian" && "${version_id%%.*}" == "13" ]]; then
        msg_ok "Debian 13 (Trixie) detected."
        return 0
    fi

    if [[ "${ALLOW_UNSUPPORTED_OS}" == "1" ]]; then
        msg_warn "Detected '${id} ${version_id:-unknown}' instead of Debian 13 - continuing because ALLOW_UNSUPPORTED_OS=1."
        return 0
    fi

    die "Debian 13 (Trixie) is required; detected '${id} ${version_id:-unknown}'. Set ALLOW_UNSUPPORTED_OS=1 to override."
}

require_amd64() {
    local arch
    arch="$(dpkg --print-architecture)"
    [[ "${arch}" == "amd64" ]] || die "amd64 architecture is required; detected '${arch}'."
    msg_ok "Architecture amd64 confirmed."
}

preflight() {
    section "Pre-flight checks"
    require_root
    require_debian_13
    require_amd64

    if ! interactive; then
        msg_warn "Running non-interactively; prompts will use defaults or environment variables."
    fi
}

# ---------------------------------------------------------------------------
# APT helpers
# ---------------------------------------------------------------------------

# Runs `apt-get update` at most once, unless forced after a repository change.
apt_refresh() {
    local force="${1:-}"

    if [[ "${APT_UPDATED}" -eq 1 && "${force}" != "force" ]]; then
        return 0
    fi

    msg_info "Refreshing package lists..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    APT_UPDATED=1
}

# apt_install <package>...
# Installs only the packages that are not already present, letting APT resolve
# every dependency on its own.
apt_install() {
    local pkg missing=()

    for pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'ok installed'; then
            continue
        fi
        missing+=("${pkg}")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        msg_ok "Already installed: $*"
        return 0
    fi

    apt_refresh
    msg_info "Installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    msg_ok "Installed: ${missing[*]}"
}

update_system_packages() {
    section "Updating the LXC"
    apt_refresh force
    msg_info "Upgrading installed packages..."
    DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    msg_ok "System packages are up to date."
}

# ---------------------------------------------------------------------------
# Interactive configuration (all questions are asked before anything changes)
# ---------------------------------------------------------------------------

current_timezone() {
    if [[ -L /etc/localtime ]]; then
        # /etc/localtime -> /usr/share/zoneinfo/<Region>/<City>
        readlink -f /etc/localtime | sed 's|^/usr/share/zoneinfo/||'
    elif [[ -s /etc/timezone ]]; then
        tr -d '[:space:]' < /etc/timezone
    else
        printf 'Etc/UTC'
    fi
}

prompt_timezone() {
    local default candidate

    default="${TIMEZONE:-$(current_timezone)}"
    [[ -n "${default}" ]] || default="Etc/UTC"

    while true; do
        candidate="$(ask "Timezone (Linux/IANA, e.g. America/New_York)" "${default}")"

        # A valid zone is always a regular file below /usr/share/zoneinfo.
        if [[ -n "${candidate}" && -f "/usr/share/zoneinfo/${candidate}" ]]; then
            TIMEZONE="${candidate}"
            return 0
        fi

        msg_warn "Unknown timezone '${candidate}' (not found in /usr/share/zoneinfo)."
        interactive || die "Cannot continue with an invalid timezone in non-interactive mode."
    done
}

prompt_port() {
    local candidate

    while true; do
        candidate="$(ask "Channels DVR web port" "${CHANNELS_PORT:-${DEFAULT_PORT}}")"

        if [[ "${candidate}" =~ ^[0-9]+$ ]] && (( candidate >= 1 && candidate <= 65535 )); then
            CHANNELS_PORT="${candidate}"
            return 0
        fi

        msg_warn "'${candidate}' is not a valid TCP port (1-65535)."
        interactive || die "Cannot continue with an invalid port in non-interactive mode."
    done
}

prompt_chrome() {
    INSTALL_CHROME="$(ask_yes_no "Install Google Chrome (required for TV Everywhere)?" "${INSTALL_CHROME:-yes}")"
}

prompt_samba() {
    INSTALL_SAMBA="$(ask_yes_no "Install Samba?" "${INSTALL_SAMBA:-yes}")"
    [[ "${INSTALL_SAMBA}" == "yes" ]] || return 0

    while true; do
        SAMBA_USER="$(ask "Samba username" "${SAMBA_USER:-channels}")"
        # Conservative POSIX user name check.
        if [[ "${SAMBA_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            break
        fi
        msg_warn "'${SAMBA_USER}' is not a valid Linux username."
        interactive || die "Cannot continue with an invalid Samba username in non-interactive mode."
    done

    if [[ -z "${SAMBA_PASSWORD}" ]]; then
        interactive || die "SAMBA_PASSWORD must be set when running non-interactively with INSTALL_SAMBA=yes."
        SAMBA_PASSWORD="$(ask_secret "Samba password for '${SAMBA_USER}'")"
    fi
}

prompt_tailscale() {
    INSTALL_TAILSCALE="$(ask_yes_no "Install Tailscale?" "${INSTALL_TAILSCALE:-no}")"
}

collect_configuration() {
    section "Configuration"
    prompt_timezone
    prompt_port
    prompt_chrome
    prompt_samba
    prompt_tailscale

    CHANNELS_HOST="${CHANNELS_HOST:-${DEFAULT_HOST}}"

    printf '\n'
    msg_info "Timezone .......... ${TIMEZONE}"
    msg_info "Channels port ..... ${CHANNELS_PORT}"
    msg_info "Google Chrome ..... ${INSTALL_CHROME}"
    msg_info "Samba ............. ${INSTALL_SAMBA}${SAMBA_USER:+ (user: ${SAMBA_USER})}"
    msg_info "Tailscale ......... ${INSTALL_TAILSCALE}"
}

# ---------------------------------------------------------------------------
# Timezone configuration
# ---------------------------------------------------------------------------

# Ensures /etc/environment holds exactly one TZ= line, replacing any existing
# entry while preserving every other variable and the file's ordering.
write_tz_environment() {
    local tmp
    tmp="$(mktemp)"

    if [[ -f /etc/environment ]]; then
        grep -v -E '^[[:space:]]*TZ=' /etc/environment > "${tmp}" || true
    fi

    # Guarantee a trailing newline before appending the TZ entry.
    if [[ -s "${tmp}" && "$(tail -c1 "${tmp}")" != "" ]]; then
        printf '\n' >> "${tmp}"
    fi

    printf 'TZ=%s\n' "${TIMEZONE}" >> "${tmp}"

    install -m 0644 -o root -g root "${tmp}" /etc/environment
    rm -f "${tmp}"
}

configure_timezone() {
    section "Configuring timezone"

    # /etc/localtime is a symlink into the tzdata database; -f forces a
    # replacement so repeated runs are harmless.
    ln -sfn "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    printf '%s\n' "${TIMEZONE}" > /etc/timezone
    write_tz_environment

    # Keep systemd's view in sync when it is available (may be a no-op in
    # unprivileged containers - never fatal).
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone "${TIMEZONE}" >/dev/null 2>&1 || true
    fi

    msg_ok "Timezone set to ${TIMEZONE}."
}

# ---------------------------------------------------------------------------
# Base packages
# ---------------------------------------------------------------------------

install_bootstrap_packages() {
    section "Installing bootstrap packages"
    # ca-certificates and curl are needed for the Channels installer; gnupg is
    # needed to dearmor Google's signing key. Installed up front so third-party
    # repositories can be added safely.
    apt_install "${BOOTSTRAP_PACKAGES[@]}"
}

install_quicksync_packages() {
    section "Installing Intel Quick Sync support"
    apt_install "${QSV_PACKAGES[@]}"
}

# ---------------------------------------------------------------------------
# Google Chrome (TV Everywhere)
# ---------------------------------------------------------------------------

install_google_chrome() {
    section "Installing Google Chrome"

    if [[ "${INSTALL_CHROME}" != "yes" ]]; then
        msg_info "Skipped by request."
        return 0
    fi

    if dpkg-query -W -f='${Status}' google-chrome-stable 2>/dev/null | grep -q 'ok installed'; then
        msg_ok "google-chrome-stable is already installed."
        return 0
    fi

    # --- Signing key -------------------------------------------------------
    install -d -m 0755 /etc/apt/keyrings
    if [[ ! -s "${CHROME_KEYRING}" ]]; then
        msg_info "Fetching Google signing key..."
        curl -fsSL "${CHROME_KEY_URL}" | gpg --dearmor --yes --output "${CHROME_KEYRING}"
        chmod 0644 "${CHROME_KEYRING}"
        msg_ok "Signing key stored at ${CHROME_KEYRING}."
    else
        msg_ok "Signing key already present."
    fi

    # --- Repository --------------------------------------------------------
    # Written only when the contents differ, so re-runs never duplicate the
    # entry or needlessly invalidate the APT cache.
    local desired="deb [arch=amd64 signed-by=${CHROME_KEYRING}] https://dl.google.com/linux/chrome/deb/ stable main"
    if [[ ! -f "${CHROME_SOURCE}" ]] || ! grep -qxF "${desired}" "${CHROME_SOURCE}"; then
        printf '%s\n' "${desired}" > "${CHROME_SOURCE}"
        chmod 0644 "${CHROME_SOURCE}"
        msg_ok "Repository written to ${CHROME_SOURCE}."
        apt_refresh force
    else
        msg_ok "Repository already configured."
    fi

    # --- Package -----------------------------------------------------------
    # No explicit dependency libraries: APT resolves everything Chrome needs.
    apt_install google-chrome-stable
}

# ---------------------------------------------------------------------------
# Channels DVR
# ---------------------------------------------------------------------------

# Echoes the path of the channels-dvr binary that systemd should execute.
# The `latest` symlink is preferred because Channels maintains it across
# self-updates; a versioned directory is used only as a fallback.
find_channels_binary() {
    local candidate

    if [[ -x "${CHANNELS_DIR}/latest/channels-dvr" ]]; then
        printf '%s' "${CHANNELS_DIR}/latest/channels-dvr"
        return 0
    fi

    candidate="$(find "${CHANNELS_DIR}" -maxdepth 2 -type f -name 'channels-dvr' -perm -u+x 2>/dev/null | sort -V | tail -n 1)"
    [[ -n "${candidate}" ]] || return 1

    printf '%s' "${candidate}"
}

install_channels_dvr() {
    section "Installing Channels DVR"

    if CHANNELS_BINARY="$(find_channels_binary)"; then
        msg_ok "Channels DVR already present at ${CHANNELS_BINARY} - skipping download."
    else
        # DOWNLOAD_ONLY=1 makes the official installer extract into ./channels-dvr
        # without registering its own service or starting the daemon. Running it
        # from / therefore produces exactly /channels-dvr.
        msg_info "Downloading Channels DVR into ${CHANNELS_DIR}..."
        ( cd / && curl -fsSL "${CHANNELS_SETUP_URL}" | DOWNLOAD_ONLY=1 sh )

        CHANNELS_BINARY="$(find_channels_binary)" \
            || die "Channels DVR binary not found under ${CHANNELS_DIR} after running the official installer."

        msg_ok "Channels DVR installed at ${CHANNELS_BINARY}."
    fi

    if [[ "${CHANNELS_BINARY}" != "${CHANNELS_DIR}/latest/channels-dvr" ]]; then
        msg_warn "Using ${CHANNELS_BINARY}; the 'latest' symlink is missing, so the unit may need editing after a self-update."
    fi

    # Engine data directory: the official installer already creates this as a
    # sibling of the versioned binary directories, but ensure it exists here
    # too in case a re-run skipped the download step entirely.
    if [[ -d "${CHANNELS_ENGINE_DATA_DIR}" ]]; then
        msg_ok "${CHANNELS_ENGINE_DATA_DIR} already exists."
    else
        install -d -m 0775 -o root -g root "${CHANNELS_ENGINE_DATA_DIR}"
        msg_ok "Created ${CHANNELS_ENGINE_DATA_DIR}."
    fi

    # Data directory: created empty and never populated here. It is selected
    # from the Channels web UI as the recordings / imported media location.
    if [[ -d "${CHANNELS_DATA_DIR}" ]]; then
        msg_ok "${CHANNELS_DATA_DIR} already exists."
    else
        install -d -m 0775 -o root -g root "${CHANNELS_DATA_DIR}"
        msg_ok "Created empty ${CHANNELS_DATA_DIR}."
    fi
}

# Writes /etc/default/channels-dvr, preserving any custom CHANNELS_HOST that
# is already configured while applying the port chosen during this run.
write_channels_defaults() {
    section "Writing ${CHANNELS_DEFAULTS}"

    local existing_host=""
    if [[ -f "${CHANNELS_DEFAULTS}" ]]; then
        existing_host="$(sed -n 's/^[[:space:]]*CHANNELS_HOST=//p' "${CHANNELS_DEFAULTS}" | tail -n 1)"
        existing_host="${existing_host%\"}"
        existing_host="${existing_host#\"}"
    fi
    [[ -n "${existing_host}" ]] && CHANNELS_HOST="${existing_host}"

    cat > "${CHANNELS_DEFAULTS}" <<EOF
# Channels DVR runtime configuration.
# Managed by ${SCRIPT_NAME}; read by ${CHANNELS_SERVICE} via EnvironmentFile.

# Address the web interface binds to (0.0.0.0 = all interfaces).
CHANNELS_HOST=${CHANNELS_HOST}

# TCP port for the web interface.
CHANNELS_PORT=${CHANNELS_PORT}
EOF

    chmod 0644 "${CHANNELS_DEFAULTS}"
    msg_ok "CHANNELS_HOST=${CHANNELS_HOST} CHANNELS_PORT=${CHANNELS_PORT}"
}

# ---------------------------------------------------------------------------
# systemd unit
# ---------------------------------------------------------------------------

install_systemd_unit() {
    section "Installing systemd unit"

    cat > "${CHANNELS_UNIT}" <<EOF
# ${CHANNELS_SERVICE} - managed by ${SCRIPT_NAME}
[Unit]
Description=Channels DVR
Documentation=https://getchannels.com/dvr/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CHANNELS_DEFAULTS}
WorkingDirectory=${CHANNELS_ENGINE_DATA_DIR}
ExecStart=${CHANNELS_BINARY} -dir ${CHANNELS_ENGINE_DATA_DIR}
Restart=always
RestartSec=5
TimeoutStopSec=30
# Channels DVR handles large libraries and many concurrent streams.
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "${CHANNELS_UNIT}"
    systemctl daemon-reload

    # Enabled, but deliberately NOT started: the service is launched only after
    # the installer has completed successfully.
    systemctl enable "${CHANNELS_SERVICE}" >/dev/null
    msg_ok "${CHANNELS_SERVICE} installed and enabled (not started yet)."
}

# ---------------------------------------------------------------------------
# Intel Quick Sync detection
# ---------------------------------------------------------------------------

check_quicksync() {
    section "Checking Intel Quick Sync"

    if [[ ! -e "${DRI_RENDER_NODE}" ]]; then
        QUICKSYNC_DETECTED="no"
        msg_warn "${DRI_RENDER_NODE} not found - hardware transcoding is unavailable."
        cat <<'EOF'

  To expose the Intel iGPU to this LXC, edit the container configuration on the
  Proxmox HOST (this script will not change the host):

    1. Find the render node's device numbers on the host:

         ls -l /dev/dri/renderD128

    2. Stop the container and edit /etc/pve/lxc/<CTID>.conf, adding:

         # Privileged container:
         lxc.cgroup2.devices.allow: c 226:0 rwm
         lxc.cgroup2.devices.allow: c 226:128 rwm
         lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir

         # Unprivileged container (add this as well):
         lxc.idmap: u 0 100000 65536
         lxc.idmap: g 0 100000 65536

       On an unprivileged container the simplest supported alternative is a
       device passthrough entry from the Proxmox UI:

         Resources -> Add -> Device Passthrough -> /dev/dri/renderD128

    3. Start the container and re-run this installer (or simply run):

         vainfo --display drm --device /dev/dri/renderD128

EOF
        return 0
    fi

    QUICKSYNC_DETECTED="yes"
    msg_ok "${DRI_RENDER_NODE} is present."
    msg_info "Querying VA-API capabilities..."

    # vainfo is informational only; a non-zero exit must not abort the install.
    if ! vainfo --display drm --device "${DRI_RENDER_NODE}"; then
        QUICKSYNC_DETECTED="present, but vainfo failed"
        msg_warn "vainfo reported an error; hardware transcoding may not work."
    fi
}

# ---------------------------------------------------------------------------
# Samba
# ---------------------------------------------------------------------------

# Creates the Linux account only when it does not already exist.
ensure_samba_user() {
    if id -u "${SAMBA_USER}" >/dev/null 2>&1; then
        msg_ok "Linux user '${SAMBA_USER}' already exists."
        return 0
    fi

    useradd --create-home --shell /usr/sbin/nologin "${SAMBA_USER}"
    msg_ok "Created Linux user '${SAMBA_USER}'."
}

# Adds or updates the Samba account, then makes sure it is enabled.
ensure_samba_account() {
    if pdbedit -L 2>/dev/null | cut -d: -f1 | grep -x "${SAMBA_USER}" >/dev/null; then
        msg_info "Updating Samba password for '${SAMBA_USER}'..."
    else
        msg_info "Creating Samba account for '${SAMBA_USER}'..."
    fi

    # -a adds the account or updates the password of an existing one;
    # -s reads both password entries from stdin.
    printf '%s\n%s\n' "${SAMBA_PASSWORD}" "${SAMBA_PASSWORD}" | smbpasswd -s -a "${SAMBA_USER}" >/dev/null
    smbpasswd -e "${SAMBA_USER}" >/dev/null
    msg_ok "Samba account '${SAMBA_USER}' is active."
}

write_samba_shares() {
    cat > "${SMB_CHANNELS_CONF}" <<EOF
# Channels DVR shares - managed by ${SCRIPT_NAME}
#
# Included from ${SMB_CONF}. Do not edit by hand: this file is rewritten
# every time the installer runs.
#
# 'force user = root' is used because Channels DVR runs as root and owns every
# file it writes; without it, clients could read but not modify the library.

# This file is included at the END of smb.conf, so the [global] block below
# reopens global context and overrides anything set earlier in smb.conf.
[global]
   # Refuse SMBv1 (NT1) outright. This is already Samba's default since 4.11,
   # but stating it explicitly keeps the guarantee from silently changing and
   # documents the intent for anyone reading the config later.
   server min protocol = SMB2
   # Applies to outbound connections made from this host (smbclient, etc.).
   client min protocol = SMB2

[channels-dvr]
   comment = Channels DVR application directory
   path = ${CHANNELS_DIR}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SAMBA_USER}
   force user = root
   force group = root
   create mask = 0664
   directory mask = 0775

[channels-data]
   comment = Channels DVR recordings and imported media
   path = ${CHANNELS_DATA_DIR}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SAMBA_USER}
   force user = root
   force group = root
   create mask = 0664
   directory mask = 0775
EOF

    chmod 0644 "${SMB_CHANNELS_CONF}"
    msg_ok "Wrote ${SMB_CHANNELS_CONF}."
}

# Appends the include directive to smb.conf exactly once. The included file
# opens with a section header, so appending at the end of smb.conf is safe.
ensure_samba_include() {
    if [[ ! -f "${SMB_CONF}" ]]; then
        die "${SMB_CONF} is missing; the samba package did not install correctly."
    fi

    if grep -qE "^[[:space:]]*include[[:space:]]*=[[:space:]]*${SMB_CHANNELS_CONF//\//\\/}[[:space:]]*$" "${SMB_CONF}"; then
        msg_ok "Include directive already present in ${SMB_CONF}."
        return 0
    fi

    # Back up the distribution file once, before the first modification.
    [[ -f "${SMB_CONF}.orig" ]] || cp -a "${SMB_CONF}" "${SMB_CONF}.orig"

    printf '\n%s\n%s\n' "${SMB_INCLUDE_MARKER}" "   ${SMB_INCLUDE_LINE}" >> "${SMB_CONF}"
    msg_ok "Added include directive to ${SMB_CONF}."
}

restart_samba() {
    local unit failed=0

    for unit in smbd nmbd; do
        # Skip units that are not shipped or not installed on this system.
        systemctl cat "${unit}.service" >/dev/null 2>&1 || continue

        systemctl enable "${unit}.service" >/dev/null 2>&1 || true

        if systemctl restart "${unit}.service"; then
            msg_ok "Restarted ${unit}."
        else
            # A failed restart must be loud: a silent failure here would leave
            # the installer reporting success with no working file sharing.
            msg_err "Failed to restart ${unit}."
            systemctl status "${unit}.service" --no-pager --lines=20 || true
            failed=1
        fi
    done

    [[ "${failed}" -eq 0 ]] || die "Samba failed to restart; see the status output above."
}

# ---------------------------------------------------------------------------
# Windows network discovery (wsdd)
# ---------------------------------------------------------------------------

# Samba implements no WS-Discovery responder, and modern Windows no longer uses
# the NetBIOS browsing that nmbd provides. Without a WSD daemon the shares work
# perfectly by UNC path but never appear under "Network" in Explorer.
#
# wsdd is not in Trixie's own repos at all (see the comment on WSDD_PACKAGE),
# so it can't be resolved through apt's normal index the way wsdd2 can - it is
# downloaded directly from the Debian archive pool and installed as a local
# .deb instead, letting apt still resolve its dependencies normally.
configure_wsdd() {
    section "Configuring Windows network discovery"

    if dpkg-query -W -f='${Status}' "${WSDD_PACKAGE}" 2>/dev/null | grep 'ok installed' >/dev/null; then
        msg_ok "${WSDD_PACKAGE} is already installed."
    else
        local tmp_deb
        tmp_deb="$(mktemp --suffix=.deb)"

        # Never fatal: a failed download should not abort an otherwise good install.
        if ! curl -fsSL -o "${tmp_deb}" "${WSDD_DEB_URL}"; then
            rm -f "${tmp_deb}"
            WSDD_STATUS="unavailable (failed to download ${WSDD_PACKAGE})"
            msg_warn "Could not download ${WSDD_PACKAGE} from ${WSDD_DEB_URL}; shares will work by UNC path but will not appear in Explorer's Network view."
            return 0
        fi

        msg_info "Installing ${WSDD_PACKAGE} from ${WSDD_DEB_URL}..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${tmp_deb}"
        rm -f "${tmp_deb}"
        msg_ok "${WSDD_PACKAGE} installed."
    fi

    systemctl enable "${WSDD_PACKAGE}.service" >/dev/null 2>&1 || true
    systemctl restart "${WSDD_PACKAGE}.service" >/dev/null 2>&1 || true

    if systemctl is-active --quiet "${WSDD_PACKAGE}.service"; then
        WSDD_STATUS="running"
        msg_ok "${WSDD_PACKAGE} is running; the container should appear under Network in Explorer."
        msg_info "Discovery also requires multicast (UDP 3702) to reach this container."
    else
        WSDD_STATUS="installed, but not running"
        msg_warn "${WSDD_PACKAGE} is installed but not active - file sharing is unaffected."
        msg_warn "Inspect with: journalctl -u ${WSDD_PACKAGE} -n 20 --no-pager"
    fi
}

configure_samba() {
    section "Configuring Samba"

    if [[ "${INSTALL_SAMBA}" != "yes" ]]; then
        WSDD_STATUS="skipped (Samba not installed)"
        msg_info "Skipped by request."
        return 0
    fi

    apt_install samba samba-common-bin

    ensure_samba_user
    ensure_samba_account
    write_samba_shares
    ensure_samba_include

    # Validate before restarting so a bad edit never takes the service down.
    msg_info "Validating Samba configuration with testparm -s..."
    if ! testparm -s "${SMB_CONF}" >/dev/null; then
        die "testparm reported an invalid Samba configuration; not restarting Samba."
    fi
    msg_ok "Samba configuration is valid."

    restart_samba

    # Discovery is only meaningful once the shares are actually being served.
    configure_wsdd
}

# ---------------------------------------------------------------------------
# Tailscale
# ---------------------------------------------------------------------------

# Prints host-side instructions for exposing /dev/net/tun into the container.
print_tun_instructions() {
    cat <<'EOF'

  tailscaled needs a TUN device, which is not exposed to this container yet.
  Add it from the Proxmox WebUI (no host shell required):

    1. Select this container in the Proxmox WebUI.
    2. Go to Resources.
    3. Add -> Device Passthrough.
    4. Set Device Path to:

         /dev/net/tun

    5. Reboot the container so the device appears.
    6. Back in this container, bring Tailscale online:

         tailscale up

EOF
}

install_tailscale() {
    section "Installing Tailscale"

    if [[ "${INSTALL_TAILSCALE}" != "yes" ]]; then
        TAILSCALE_STATUS="skipped"
        msg_info "Skipped by request."
        return 0
    fi

    # --- Package -----------------------------------------------------------
    if command -v tailscale >/dev/null 2>&1; then
        msg_ok "Tailscale is already installed."
    else
        msg_info "Running the official Tailscale installer..."
        curl -fsSL "${TAILSCALE_INSTALL_URL}" | sh
        command -v tailscale >/dev/null 2>&1 \
            || die "Tailscale installation failed; 'tailscale' is not on PATH."
        msg_ok "Tailscale installed."
    fi

    # --- TUN device --------------------------------------------------------
    # Without /dev/net/tun the daemon installs cleanly but can never connect,
    # so report it rather than leaving a service that fails in the background.
    if [[ ! -c "${TUN_DEVICE}" ]]; then
        TAILSCALE_STATUS="installed; ${TUN_DEVICE} not passed through yet"
        msg_warn "${TUN_DEVICE} not found - Tailscale cannot connect from this container."
        print_tun_instructions
        return 0
    fi
    msg_ok "${TUN_DEVICE} is present."

    # --- Daemon ------------------------------------------------------------
    systemctl enable tailscaled >/dev/null 2>&1 || true
    if ! systemctl restart tailscaled; then
        TAILSCALE_STATUS="installed, but tailscaled failed to start"
        msg_warn "tailscaled did not start; inspect with: journalctl -u tailscaled -n 20 --no-pager"
        return 0
    fi
    msg_ok "tailscaled is running."

    # --- Authentication ----------------------------------------------------
    # 'tailscale up' blocks on an interactive browser login, so it is never run
    # from the installer; it is left to the operator once setup is complete.
    if tailscale ip -4 >/dev/null 2>&1; then
        TAILSCALE_STATUS="connected"
        msg_ok "Tailscale is already authenticated."
    else
        TAILSCALE_STATUS="installed (run 'tailscale up' to connect)"
        msg_info "Run 'tailscale up' to authenticate this node."
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

primary_ip() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "${ip:-127.0.0.1}"
}

print_summary() {
    local host
    host="$(primary_ip)"

    printf '\n%s============================================================%s\n' "${C_BOLD}${C_GREEN}" "${C_RESET}"
    printf '%s Channels DVR installation complete%s\n' "${C_BOLD}${C_GREEN}" "${C_RESET}"
    printf '%s============================================================%s\n\n' "${C_BOLD}${C_GREEN}" "${C_RESET}"

    printf '  %sChannels URL%s      http://%s:%s\n' "${C_BOLD}" "${C_RESET}" "${host}" "${CHANNELS_PORT}"
    printf '  %sTimezone%s          %s\n' "${C_BOLD}" "${C_RESET}" "${TIMEZONE}"
    printf '  %sGoogle Chrome%s     %s\n' "${C_BOLD}" "${C_RESET}" "${INSTALL_CHROME}"
    printf '  %sSamba%s             %s\n' "${C_BOLD}" "${C_RESET}" "${INSTALL_SAMBA}"
    printf '  %sIntel Quick Sync%s  %s\n' "${C_BOLD}" "${C_RESET}" "${QUICKSYNC_DETECTED}"
    printf '  %sTailscale%s         %s\n' "${C_BOLD}" "${C_RESET}" "${TAILSCALE_STATUS}"

    # Show the tailnet address when the node is actually up: it is the URL most
    # useful for reaching Channels remotely.
    if [[ "${TAILSCALE_STATUS}" == "connected" ]]; then
        local ts_ip
        ts_ip="$(tailscale ip -4 2>/dev/null | head -n 1)"
        [[ -n "${ts_ip}" ]] && printf '  %sTailscale URL%s     http://%s:%s\n' "${C_BOLD}" "${C_RESET}" "${ts_ip}" "${CHANNELS_PORT}"
    fi

    if [[ "${INSTALL_SAMBA}" == "yes" ]]; then
        printf '  %sWindows discovery%s %s (%s)\n' "${C_BOLD}" "${C_RESET}" "${WSDD_STATUS}" "${WSDD_PACKAGE}"
        printf '\n  %sSamba shares%s (user: %s)\n' "${C_BOLD}" "${C_RESET}" "${SAMBA_USER}"
        printf '    \\\\%s\\channels-dvr    -> %s\n' "${host}" "${CHANNELS_DIR}"
        printf '    \\\\%s\\channels-data   -> %s\n' "${host}" "${CHANNELS_DATA_DIR}"
        printf '    smb://%s/channels-dvr\n' "${host}"
        printf '    smb://%s/channels-data\n' "${host}"
    fi

    printf '\n  %sNext steps%s\n' "${C_BOLD}" "${C_RESET}"
    printf '    1. Open the web UI and complete first-time setup.\n'
    printf '    2. Set the recordings / imported media location to %s.\n' "${CHANNELS_DATA_DIR}"

    if [[ "${INSTALL_TAILSCALE}" == "yes" && "${TAILSCALE_STATUS}" != "connected" ]]; then
        if [[ "${TAILSCALE_STATUS}" == *"not passed through"* ]]; then
            printf '    3. Add %s via Resources -> Add -> Device Passthrough in the\n' "${TUN_DEVICE}"
            printf '       Proxmox WebUI, reboot the container, then run: tailscale up\n'
        else
            printf '    3. Run: tailscale up\n'
        fi
    fi

    printf '\n  %sUseful commands%s\n' "${C_BOLD}" "${C_RESET}"
    printf '    systemctl status channels-dvr\n'
    printf '    journalctl -u channels-dvr -f\n'

    # Accessing SMB shares elsewhere on the LAN is done entirely on the Proxmox
    # host (host fstab mount + an mp0: bind mount), never inside the container.
    printf '\n  %sTo reach CIFS/SMB shares elsewhere on your LAN%s\n' "${C_BOLD}" "${C_RESET}"
    printf '    Mount the share on the Proxmox host in /etc/fstab, then bind-mount it\n'
    printf '    into this LXC with an "mp0:" line in /etc/pve/lxc/<CTID>.conf.\n'
    printf '    Channels DVR runs as root here, so use uid=100000,gid=100000 in the\n'
    printf '    host fstab entry for an unprivileged container.\n'
    printf '    %s\n\n' "${CIFS_TUTORIAL_URL}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    preflight
    update_system_packages
    collect_configuration

    configure_timezone
    install_bootstrap_packages
    install_quicksync_packages
    install_google_chrome

    install_channels_dvr
    write_channels_defaults
    install_systemd_unit

    check_quicksync
    configure_samba
    install_tailscale

    # Everything succeeded: safe to start the service now.
    section "Starting Channels DVR"
    systemctl restart "${CHANNELS_SERVICE}"
    sleep 2
    if systemctl is-active --quiet "${CHANNELS_SERVICE}"; then
        msg_ok "${CHANNELS_SERVICE} is running."
    else
        msg_warn "${CHANNELS_SERVICE} is not active; check 'journalctl -u channels-dvr -n 50'."
    fi

    print_summary
}

main "$@"
