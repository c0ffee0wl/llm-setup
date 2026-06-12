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
# AppArmor (bwrap)
#############################################################################

# Configure AppArmor to allow bwrap to create user namespaces
# Ubuntu 24.04+ restricts unprivileged user namespaces via AppArmor by default,
# which breaks bwrap sandboxing (used by workflow engine and code execution tools)
# Idempotent: only creates profile if not already present
configure_bwrap_apparmor() {
    if command -v apparmor_parser &> /dev/null && \
       [ -d /sys/module/apparmor ] && \
       [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] && \
       [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)" = "1" ] && \
       [ ! -f /etc/apparmor.d/bwrap ]; then
        log "Configuring AppArmor profile for bwrap..."
        if sudo tee /etc/apparmor.d/bwrap > /dev/null <<'APPARMOR'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
APPARMOR
        then
            sudo apparmor_parser -r /etc/apparmor.d/bwrap || warn "Failed to load AppArmor bwrap profile"
        else
            warn "Failed to write AppArmor bwrap profile"
        fi
    else
        log "AppArmor bwrap profile already configured or not needed"
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
        if ! { command -v pipx &> /dev/null && pipx upgrade uv 2>/dev/null; }; then
            log "Upgrading uv via standalone installer..."
            curl_secure -LsSf https://astral.sh/uv/install.sh | sh
        fi
    fi

    configure_uv_system_python
}

#############################################################################
# Version comparison
#############################################################################

# Compare two semantic versions
# Returns: 0 if equal, 1 if v1 > v2, 2 if v1 < v2
# Usage: compare_versions "1.85.0" "1.80.0"
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

# Check if version is at least minimum required
# Returns: 0 (true) if v1 >= v2, 1 (false) otherwise
# Usage: if version_at_least "$current" "1.85"; then
version_at_least() {
    compare_versions "$1" "$2"
    [[ $? -le 1 ]]
}

#############################################################################
# Standalone uv tools
#############################################################################

# Install or upgrade a uv tool with intelligent source detection.
# Usage: install_or_upgrade_uv_tool tool_name_or_source [python_version]
# Examples:
#   install_or_upgrade_uv_tool gitingest                             # PyPI package
#   install_or_upgrade_uv_tool "git+https://github.com/user/repo"    # Git package
#   install_or_upgrade_uv_tool toko 3.14                             # Pinned Python
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

    # Derive tool name from source. Bash ERE doesn't support non-greedy `+?`,
    # so use parameter expansion: strip trailing slash, take basename, strip .git.
    local tool_name
    if [ "$is_git_package" = "true" ]; then
        tool_name="${tool_source%/}"
        tool_name="${tool_name##*/}"
        tool_name="${tool_name%.git}"
    else
        tool_name="$tool_source"
    fi

    if uv tool list 2>/dev/null | grep -q "^$tool_name "; then
        if [ "$is_git_package" = "true" ]; then
            local tool_info=$(uv tool list --show-version-specifiers 2>/dev/null | grep "^$tool_name " || true)
            local current_git_url=$(echo "$tool_info" | grep -oP '\[required:\s+git\+\K[^\]]+' || echo "")
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

#############################################################################
# Go
#############################################################################

# Install Go from apt if missing or below MIN_GO_VERSION.
# Returns 0 if Go >= MIN_GO_VERSION is available, 1 otherwise.
install_go() {
    local MIN_GO_VERSION="1.22"

    if command -v go &> /dev/null; then
        local current_version=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+' || true)
        if version_at_least "$current_version" "$MIN_GO_VERSION"; then
            log "Go $current_version is already installed (>= $MIN_GO_VERSION)"
            return 0
        else
            warn "Go $current_version installed but >= $MIN_GO_VERSION required"
            return 1
        fi
    fi

    local repo_version=$(apt-cache policy golang-go 2>/dev/null | grep -oP 'Candidate:\s*(?:[0-9]+:)?\K[0-9]+\.[0-9]+' | head -1)
    if [ -n "$repo_version" ] && version_at_least "$repo_version" "$MIN_GO_VERSION"; then
        log "Installing Go $repo_version from apt..."
        sudo apt-get install -y golang-go
        return 0
    else
        warn "Go >= $MIN_GO_VERSION not available from apt (found: ${repo_version:-none})"
        return 1
    fi
}

#############################################################################
# blaude
#############################################################################

# Install/update tools shipped as raw files from the c0ffee0wl/blaude repo.
# Downloads to a temp file and moves into place only on success, so a mid-transfer
# failure never clobbers a previously-working binary with a truncated one.
install_blaude_repo_script() {
    local name="$1"
    local dest="$HOME/.local/bin/$name"
    local tmp
    tmp="$(mktemp)"
    log "Installing/updating $name..."
    if curl_secure -fsSL -H "Cache-Control: no-cache" \
        "https://raw.githubusercontent.com/c0ffee0wl/blaude/main/$name" -o "$tmp"; then
        chmod +x "$tmp"
        mv "$tmp" "$dest"
        log "$name installed to $dest"
    else
        rm -f "$tmp"
        warn "Failed to download $name"
    fi
}

#############################################################################
# Cache cleanup
#############################################################################

# Clear package-manager caches to reclaim disk space. Each cleaner is guarded by
# `command -v`, so this is safe to run regardless of which package managers exist
# on the box — it purges npm/go/pip/pipx/cargo/uv caches if (and only if) present.
# Invoked by `--clear-cache` and automatically at the end of every normal run.
clear_package_caches() {
    log "Clearing package manager caches..."

    # npm cache (~/.npm/_cacache)
    if command -v npm &>/dev/null; then
        log "Clearing npm cache..."
        npm cache clean --force 2>/dev/null || warn "npm cache clean failed"
    fi

    # Go module cache (~/go/pkg/mod)
    if command -v go &>/dev/null; then
        log "Clearing Go module cache..."
        go clean -modcache 2>/dev/null || warn "go clean -modcache failed"
    fi

    # pip cache (~/.cache/pip) — use `python3 -m pip` so it works even if only pip3 exists.
    if python3 -m pip --version &>/dev/null; then
        log "Clearing pip cache..."
        python3 -m pip cache purge 2>/dev/null || warn "pip cache purge failed"
    fi

    # pipx cache (~/.cache/pipx) — no built-in purge command yet.
    if command -v pipx &>/dev/null && [ -d "$HOME/.cache/pipx" ]; then
        log "Clearing pipx cache..."
        rm -rf "$HOME/.cache/pipx" 2>/dev/null || warn "pipx cache removal failed"
    fi

    # cargo cache (~/.cargo/registry, ~/.cargo/git) — `cargo clean gc` is still
    # nightly-only, so remove the cache dirs manually (works on all toolchains).
    if command -v cargo &>/dev/null; then
        log "Clearing cargo cache..."
        rm -rf "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/src" "$HOME/.cargo/git/checkouts" 2>/dev/null || warn "cargo cache removal failed"
    fi

    # uv cache
    if command -v uv &>/dev/null; then
        log "Clearing uv cache..."
        uv cache clean 2>/dev/null || warn "uv cache clean failed"
    fi

    log "Cache cleanup complete!"
}

#############################################################################
# Uninstall helpers
#############################################################################

# Prompt the user with a yes/no question; return 0 for yes, 1 for no.
# Usage: if ask_yes_no "Remove foo?" Y; then ...; fi
ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local hint response

    if [[ "$default" =~ ^[Yy] ]]; then
        hint="(Y/n)"
    else
        hint="(y/N)"
    fi

    read -p "$prompt $hint: " response
    response=${response:-$default}
    [[ "$response" =~ ^[Yy] ]]
}

# Run a destructive command, or merely describe it under DRY_RUN.
# Usage: do_or_dry "<description>" <command...>
do_or_dry() {
    local description="$1"; shift
    if [ "${DRY_RUN:-false}" = "true" ]; then
        log "[dry-run] $description"
        return 0
    fi
    log "$description"
    "$@"
}

# Prompt before uninstalling a group; auto-yes when FORCE_UNINSTALL=true.
# Returns 0 to proceed, 1 to skip. Records skipped groups in UNINSTALL_SKIPPED.
# Usage: if confirm_uninstall "Systemd user services"; then ...; fi
confirm_uninstall() {
    local label="$1"
    if [ "${FORCE_UNINSTALL:-false}" = "true" ]; then
        log "Uninstalling: $label"
        return 0
    fi
    if ask_yes_no "Uninstall $label?" Y; then
        return 0
    fi
    UNINSTALL_SKIPPED+=("$label")
    log "Skipped: $label"
    return 1
}

# Uninstall a uv tool if present. No-op if uv is missing or the tool isn't listed.
# Usage: uninstall_uv_tool <tool_name>
uninstall_uv_tool() {
    local tool="$1"
    if ! command -v uv >/dev/null 2>&1; then
        return 0
    fi
    if uv tool list 2>/dev/null | grep -qE "^${tool}( |$)"; then
        do_or_dry "uv tool uninstall $tool" uv tool uninstall "$tool" || warn "uv tool uninstall $tool failed"
    fi
}
