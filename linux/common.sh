#!/bin/bash
#
# Shared utility functions for llm-setup
#
# Usage: source "$SCRIPT_DIR/common.sh"
#

# Source guard
[[ -n "${_LLM_COMMON_SOURCED:-}" ]] && return
_LLM_COMMON_SOURCED=1

#############################################################################
# Colors
#############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

#############################################################################
# Hardened curl
#############################################################################

# Enforce TLS 1.2+ and HTTPS-only for external requests
curl_secure() {
    curl --proto '=https' --tlsv1.2 "$@"
}

#############################################################################
# Logging
#############################################################################

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

#############################################################################
# APT
#############################################################################

# install_apt_package <package> [command]
# If command is given, checks for the command instead of the package name.
install_apt_package() {
    local package="$1"
    local command="${2:-$1}"
    if ! command -v "$command" &> /dev/null; then
        log "Installing $package..."
        sudo apt-get install -y "$package"
    else
        log "$package is already installed"
    fi
}

# install_apt_packages pkg1 pkg2 ...
# Checks each via dpkg, installs the missing ones in one apt call.
install_apt_packages() {
    local missing=()
    for pkg in "$@"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "Installing ${missing[*]}..."
        sudo apt-get install -y "${missing[@]}"
    else
        log "All packages already installed: $*"
    fi
}

#############################################################################
# uv
#############################################################################

# Configure uv to prefer system Python (avoids issues with bleeding-edge
# Python versions that lack package wheels).
configure_uv_system_python() {
    local uv_config_dir="$HOME/.config/uv"
    local uv_config_file="$uv_config_dir/uv.toml"

    if [ -f "$uv_config_file" ] && grep -q "python-preference" "$uv_config_file" 2>/dev/null; then
        return 0
    fi

    log "Configuring uv to prefer system Python..."
    mkdir -p "$uv_config_dir"

    if [ -f "$uv_config_file" ] && [ -s "$uv_config_file" ] && [ -n "$(tail -c1 "$uv_config_file")" ]; then
        echo "" >> "$uv_config_file"
    fi

    echo 'python-preference = "system"' >> "$uv_config_file"
}

# Install or upgrade uv itself (via pipx, falling back to the standalone installer).
install_or_upgrade_uv() {
    export PATH=$HOME/.local/bin:$PATH
    if ! command -v uv &> /dev/null; then
        log "Installing uv via pipx..."
        if ! command -v pipx &> /dev/null; then
            sudo apt-get install -y -qq pipx
        fi
        pipx install uv
    else
        log "uv is already installed, upgrading..."
        if command -v pipx &> /dev/null; then
            pipx upgrade uv 2>/dev/null || {
                log "Upgrading uv via standalone installer..."
                curl_secure -LsSf https://astral.sh/uv/install.sh | sh
            }
        else
            curl_secure -LsSf https://astral.sh/uv/install.sh | sh
        fi
    fi

    configure_uv_system_python
}
