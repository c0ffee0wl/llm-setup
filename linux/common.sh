#!/bin/bash
#
# Shared utility functions for llm-setup
#
# Usage: source "$SCRIPT_DIR/common.sh"
#
# Required variables (set by caller before sourcing):
#   SCRIPT_DIR - Directory containing this file
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
# Mode flags (callers may set before sourcing)
#############################################################################

YES_MODE=${YES_MODE:-false}
NO_MODE=${NO_MODE:-false}

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
# Version comparison
#############################################################################

# 0 if v1 == v2, 1 if v1 > v2, 2 if v1 < v2
compare_versions() {
    [[ $# -lt 2 ]] && return 2
    [[ "$1" == "$2" ]] && return 0
    local IFS=.
    local i v1=($1) v2=($2)
    for ((i=0; i<${#v1[@]} || i<${#v2[@]}; i++)); do
        local n1=${v1[i]:-0}
        local n2=${v2[i]:-0}
        ((n1 > n2)) && return 1
        ((n1 < n2)) && return 2
    done
    return 0
}

version_at_least() {
    compare_versions "$1" "$2"
    [[ $? -le 1 ]]
}

version_less_than() {
    compare_versions "$1" "$2"
    [[ $? -eq 2 ]]
}

#############################################################################
# Prompts
#############################################################################

# ask_yes_no <prompt> [Y|N]
# Respects YES_MODE / NO_MODE.
ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local hint response

    if [[ "$YES_MODE" == "true" ]]; then
        log "Yes mode: Auto-answering 'Yes' to: $prompt"
        return 0
    fi
    if [[ "$NO_MODE" == "true" ]]; then
        log "No mode: Auto-answering 'No' to: $prompt"
        return 1
    fi

    if [[ "$default" =~ ^[Yy] ]]; then
        hint="(Y/n)"
    else
        hint="(y/N)"
    fi

    read -p "$prompt $hint: " response
    response=${response:-$default}
    [[ "$response" =~ ^[Yy] ]]
}

#############################################################################
# Files / profile
#############################################################################

backup_file() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.backup.$(date +'%Y-%m-%d_%H-%M-%S')"
        cp "$file_path" "$backup_path"
        log "Backed up to: $backup_path"
    fi
}

# Idempotently set `export VAR="value"` in ~/.profile.
# Handles commented-out lines and properly escapes special chars.
update_profile_export() {
    local var_name="$1"
    local var_value="$2"
    local profile_file="$HOME/.profile"

    [ ! -f "$profile_file" ] && touch "$profile_file"

    local escaped_value="$var_value"
    escaped_value="${escaped_value//\\/\\\\}"
    escaped_value="${escaped_value//\"/\\\"}"
    escaped_value="${escaped_value//\$/\\\$}"
    escaped_value="${escaped_value//\`/\\\`}"

    local sed_value="$escaped_value"
    sed_value="${sed_value//&/\\&}"

    if grep -q "^export ${var_name}=" "$profile_file" 2>/dev/null; then
        sed -i "s|^export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$profile_file"
    elif grep -q "^#[[:space:]]*export ${var_name}=" "$profile_file" 2>/dev/null; then
        sed -i "s|^#[[:space:]]*export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$profile_file"
    else
        echo "export ${var_name}=\"${escaped_value}\"" >> "$profile_file"
    fi
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

#############################################################################
# Node.js
#############################################################################

MINIMUM_NODE_VERSION="20"

# Install Node.js from apt if the repo has >= 20, otherwise via nvm (Node 22).
install_or_upgrade_nodejs() {
    log "Checking Node.js version in repositories..."
    local repo_node_version
    repo_node_version=$(apt-cache policy nodejs 2>/dev/null | grep -oP 'Candidate:\s*\K[0-9]+' | head -1)

    if [ -z "$repo_node_version" ]; then
        repo_node_version="0"
        warn "Could not determine repository Node.js version"
    fi

    log "Repository has Node.js version: $repo_node_version (minimum required: $MINIMUM_NODE_VERSION)"

    if ! command -v node &> /dev/null; then
        if version_at_least "$repo_node_version" "$MINIMUM_NODE_VERSION"; then
            log "Installing Node.js from repositories (version $repo_node_version)..."
            sudo apt-get install -y nodejs
            if ! command -v npm &> /dev/null; then
                log "Installing npm..."
                sudo apt-get install -y npm
            fi
        else
            log "Repository version $repo_node_version is < $MINIMUM_NODE_VERSION, installing Node 22 via nvm..."
            if [ ! -d "$HOME/.nvm" ]; then
                log "Installing nvm..."
                curl_secure -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
            else
                log "nvm is already installed"
            fi

            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

            log "Installing Node.js 22 via nvm..."
            nvm install 22
            nvm use 22
            nvm alias default 22
        fi
    else
        local current_node_version
        current_node_version=$(node --version | grep -oP 'v\K[0-9]+' || true)
        log "Node.js is already installed (version $current_node_version)"

        if version_less_than "$current_node_version" "$MINIMUM_NODE_VERSION"; then
            warn "Installed Node.js version $current_node_version is < $MINIMUM_NODE_VERSION. Consider upgrading to Node 22 via nvm."
            warn "Run: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash"
            warn "Then: nvm install 22 && nvm use 22 && nvm alias default 22"
        fi

        if ! command -v npm &> /dev/null; then
            if which node 2>/dev/null | grep -q "\.nvm"; then
                warn "Node.js is from nvm but npm is not found. Try: nvm reinstall \$(node --version | tr -d 'v')"
            else
                log "npm is not installed, installing from repository..."
                sudo apt-get install -y npm
            fi
        fi
    fi
}

#############################################################################
# llm plugin install
#############################################################################

# install_or_upgrade_uv_tool <source> [python_version]
# Source can be a PyPI name or a git+ URL. Auto-detects migration between
# PyPI and git sources and uses --force when the source changes.
install_or_upgrade_uv_tool() {
    local tool_source="$1"
    local python_version="${2:-}"

    local is_git_package=false
    if [[ "$tool_source" =~ ^git\+ ]]; then
        is_git_package=true
    fi

    local python_flag=""
    if [ -n "$python_version" ]; then
        python_flag="--python $python_version"
    fi

    local tool_name
    if [[ "$tool_source" =~ git\+https://.+/([^/]+?)(\.git)?$ ]]; then
        tool_name="${BASH_REMATCH[1]}"
    else
        tool_name="$tool_source"
    fi

    if uv tool list 2>/dev/null | grep -q "^$tool_name "; then
        if [ "$is_git_package" = "true" ]; then
            local tool_info
            tool_info=$(uv tool list --show-version-specifiers 2>/dev/null | grep "^$tool_name " || true)
            local current_git_url
            current_git_url=$(echo "$tool_info" | grep -oP '\[required:\s+git\+\K[^\]]+' || echo "")
            local new_git_url="${tool_source#git+}"

            if [ -n "$current_git_url" ] && [ "$current_git_url" = "$new_git_url" ]; then
                log "$tool_name is already from git source, checking for updates..."
                uv tool upgrade $python_flag "$tool_name"
            else
                if [ -n "$current_git_url" ]; then
                    log "Migrating $tool_name git source:"
                    log "  Old: $current_git_url"
                    log "  New: $new_git_url"
                else
                    log "Migrating $tool_name from PyPI to git source..."
                    log "  Git: $new_git_url"
                fi
                uv tool install --force $python_flag "$tool_source"
            fi
        else
            log "$tool_name is already installed, upgrading..."
            uv tool upgrade $python_flag "$tool_name"
        fi
    else
        log "Installing $tool_name..."
        uv tool install $python_flag "$tool_source"
    fi
}
