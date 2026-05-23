#!/bin/bash
#
# llm-setup
#
# Installs and updates Simon Willison's `llm` CLI (with a trimmed plugin set),
# Anthropic's Claude Code, and a set of Claude Code skills on Debian/Kali Linux.
#
# Runs as the current $USER. Idempotent: install-if-missing by default,
# upgrade with --upgrade. Self-updates from git on every run.
#
# Usage:
#   ./linux/setup.sh                    # install missing tools, configure on first run
#   ./linux/setup.sh --upgrade          # also upgrade llm + claude code if installed
#   ./linux/setup.sh --azure            # (re)configure Azure OpenAI provider
#   ./linux/setup.sh --gemini           # (re)configure Google Gemini provider
#   ./linux/setup.sh --yes              # auto-answer yes to all prompts
#   ./linux/setup.sh --no               # auto-answer no to all prompts
#

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"

#############################################################################
# Argument parsing
#############################################################################

ORIGINAL_ARGS=("$@")
UPGRADE_MODE=false
FORCE_AZURE_CONFIG=false
FORCE_GEMINI_CONFIG=false

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --upgrade        Upgrade llm + plugins and Claude Code if already installed
  --azure          (Re)configure Azure OpenAI provider
  --gemini         (Re)configure Google Gemini provider
  --yes, -y        Auto-answer yes to all prompts
  --no,  -n        Auto-answer no to all prompts
  --help, -h       Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upgrade)
            UPGRADE_MODE=true
            ;;
        --azure)
            FORCE_AZURE_CONFIG=true
            ;;
        --gemini)
            FORCE_GEMINI_CONFIG=true
            ;;
        --yes|-y)
            YES_MODE=true
            ;;
        --no|-n)
            NO_MODE=true
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
    shift
done

if [ "$FORCE_AZURE_CONFIG" = "true" ] && [ "$FORCE_GEMINI_CONFIG" = "true" ]; then
    error "--azure and --gemini cannot be used together"
fi

if [ "$EUID" -eq 0 ]; then
    error "Do not run this script as root. Run it as your normal user."
fi

#############################################################################
# Provider helpers
#############################################################################

LLM_CONFIG_DIR_DEFAULT="$HOME/.config/io.datasette.llm"
_LLM_CONFIG_DIR_CACHE=""

get_llm_config_dir() {
    if [ -z "$_LLM_CONFIG_DIR_CACHE" ]; then
        local result=""
        local llm_bin="$HOME/.local/bin/llm"
        if [ -x "$llm_bin" ]; then
            result="$("$llm_bin" logs path 2>/dev/null | tail -n1 | xargs dirname 2>/dev/null || true)"
        fi
        if [ -z "$result" ]; then
            result="$(command llm logs path 2>/dev/null | tail -n1 | xargs dirname 2>/dev/null || true)"
        fi
        if [ -z "$result" ]; then
            result="$LLM_CONFIG_DIR_DEFAULT"
        fi
        _LLM_CONFIG_DIR_CACHE="$result"
    fi
    echo "$_LLM_CONFIG_DIR_CACHE"
}

# Fetch a stored llm key (empty if missing).
get_llm_key() {
    local provider="$1"
    local llm_cmd="$HOME/.local/bin/llm"
    [ -x "$llm_cmd" ] || llm_cmd="llm"
    command -v "$llm_cmd" >/dev/null 2>&1 || { echo ""; return; }
    "$llm_cmd" keys get "$provider" 2>/dev/null || true
}

get_azure_api_base() {
    local extra_models_file="$(get_llm_config_dir)/extra-openai-models.yaml"
    grep -m 1 "^\s*api_base:" "$extra_models_file" 2>/dev/null \
        | sed 's/.*api_base:\s*//;s/\s*$//' || true
}

# Render a config template by substituting __AZURE_API_BASE__ and write to dest.
render_azure_config() {
    local src="$1" dest="$2" api_base="$3"
    local escaped_base
    # Escape sed special chars in the URL.
    escaped_base=$(printf '%s' "$api_base" | sed 's/[\&/]/\\&/g')
    sed "s|__AZURE_API_BASE__|${escaped_base}|g" "$src" > "$dest"
}

configure_azure_openai() {
    log "Configuring Azure OpenAI..."
    echo ""
    local api_base
    read -p "Enter your Azure Foundry resource URL (e.g., https://YOUR-RESOURCE.cognitiveservices.azure.com/openai/v1/): " api_base

    [ -z "$api_base" ] && error "Azure API base URL cannot be empty"
    [[ "$api_base" =~ ^https:// ]] || error "Azure API base URL must start with https://"

    command llm keys set azure
    if ! command llm keys get azure &>/dev/null; then
        warn "Azure API key was not set successfully"
        return 1
    fi

    local llm_cfg
    llm_cfg=$(get_llm_config_dir)
    mkdir -p "$llm_cfg"

    log "Writing $llm_cfg/extra-openai-models.yaml"
    render_azure_config \
        "$SCRIPT_DIR/configs/extra-openai-models.yaml" \
        "$llm_cfg/extra-openai-models.yaml" \
        "$api_base"

    log "Writing $llm_cfg/azure-embeddings-models.yaml"
    render_azure_config \
        "$SCRIPT_DIR/configs/azure-embeddings-models.yaml" \
        "$llm_cfg/azure-embeddings-models.yaml" \
        "$api_base"

    # Persist key + resource name to ~/.profile for downstream tools.
    local resource_name
    resource_name=$(echo "$api_base" | sed 's|https://\([^.]*\)\..*|\1|')
    local api_key
    api_key=$(get_llm_key azure)
    [ -n "$api_key" ] && update_profile_export "AZURE_OPENAI_API_KEY" "$api_key"
    [ -n "$resource_name" ] && update_profile_export "AZURE_RESOURCE_NAME" "$resource_name"

    # Set default model on first Azure setup; don't clobber an explicit user choice.
    local default_model_file="$llm_cfg/default_model.txt"
    if [ ! -f "$default_model_file" ]; then
        log "Setting default model to azure/gpt-4.1-mini..."
        command llm models default azure/gpt-4.1-mini
    fi
}

configure_gemini() {
    log "Configuring Google Gemini..."
    echo ""
    echo "Get your free API key from: https://ai.google.dev/gemini-api/docs/api-key"
    echo ""

    command llm keys set gemini
    if ! command llm keys get gemini &>/dev/null; then
        warn "Gemini API key was not set successfully"
        return 1
    fi

    local api_key
    api_key=$(get_llm_key gemini)
    [ -n "$api_key" ] && update_profile_export "GEMINI_API_KEY" "$api_key"
}

#############################################################################
# Phase 0: Self-Update
#############################################################################

log "Checking for script updates..."
cd "$REPO_DIR"

if git rev-parse --git-dir > /dev/null 2>&1; then
    if git remote 2>/dev/null | grep -q .; then
        git fetch origin 2>/dev/null || true
        BEHIND=$(git rev-list HEAD..@{u} 2>/dev/null | wc -l)
        if [ "$BEHIND" -gt 0 ]; then
            log "Updates found, pulling and re-executing..."
            git pull --ff-only
            exec "$0" "${ORIGINAL_ARGS[@]}"
        else
            log "Script is up to date"
        fi
    else
        warn "No git remote configured. Self-update disabled."
    fi
else
    warn "Not running from a git repository. Self-update disabled."
fi

#############################################################################
# Phase 1: Prerequisites
#############################################################################

log "Phase 1: Prerequisites"

install_apt_packages git curl jq ca-certificates build-essential poppler-utils
install_or_upgrade_uv
install_or_upgrade_nodejs

#############################################################################
# Phase 2: llm + trimmed plugin set
#############################################################################

log "Phase 2: llm + plugins"

REMOTE_PLUGINS=(
    # Plugin management (must be first - persists plugins across `uv tool upgrade llm`)
    "git+https://github.com/c0ffee0wl/llm-uv-tool"

    # Providers
    "git+https://github.com/c0ffee0wl/llm-gemini"
    "git+https://github.com/c0ffee0wl/llm-vertex"
    "llm-anthropic"
    "llm-openrouter"

    # Commands
    "git+https://github.com/c0ffee0wl/llm-cmd"

    # Daily-driver utilities
    "llm-git-commit"
    "llm-jq"
    "git+https://github.com/c0ffee0wl/llm-templates-fabric"

    # Fragment / content loaders
    "llm-fragments-github"
    "git+https://github.com/c0ffee0wl/llm-fragments-pdf"
    "pymupdf_layout"
    "llm-fragments-site-text"
    "llm-fragments-dir"
    "git+https://github.com/c0ffee0wl/llm-fragments-youtube-transcript"

    # Specialized utilities
    "llm-sort"
    "llm-classify"
)

LLM_SOURCE="git+https://github.com/c0ffee0wl/llm"

# Build --with arguments
WITH_ARGS=()
for plugin in "${REMOTE_PLUGINS[@]}"; do
    WITH_ARGS+=("--with" "$plugin")
done

if ! command -v llm &>/dev/null || ! uv tool list 2>/dev/null | grep -q '^llm '; then
    log "Installing llm with plugins..."
    uv tool install --force "${WITH_ARGS[@]}" "$LLM_SOURCE"
elif [ "$UPGRADE_MODE" = "true" ]; then
    log "Upgrading llm with plugins..."
    uv tool install --force "${WITH_ARGS[@]}" "$LLM_SOURCE"
else
    log "llm already installed (use --upgrade to refresh plugins)"
fi

#############################################################################
# Phase 3: Provider configuration
#############################################################################

log "Phase 3: Provider configuration"

HAS_AZURE_KEY=false
HAS_GEMINI_KEY=false
[ -n "$(get_llm_key azure)" ] && HAS_AZURE_KEY=true
[ -n "$(get_llm_key gemini)" ] && HAS_GEMINI_KEY=true

IS_FIRST_PROVIDER_RUN=false
if [ "$HAS_AZURE_KEY" = "false" ] && [ "$HAS_GEMINI_KEY" = "false" ]; then
    IS_FIRST_PROVIDER_RUN=true
fi

# Azure
if [ "$FORCE_AZURE_CONFIG" = "true" ]; then
    configure_azure_openai
elif [ "$HAS_AZURE_KEY" = "true" ]; then
    log "Azure OpenAI was previously configured (use --azure to reconfigure)"
elif [ "$IS_FIRST_PROVIDER_RUN" = "true" ]; then
    if ask_yes_no "Do you want to configure Azure OpenAI?" Y; then
        configure_azure_openai
    else
        log "Skipping Azure OpenAI configuration"
    fi
fi

# Refresh after possible Azure configuration
[ -n "$(get_llm_key azure)" ] && HAS_AZURE_KEY=true

# Gemini
if [ "$FORCE_GEMINI_CONFIG" = "true" ]; then
    configure_gemini
elif [ "$HAS_GEMINI_KEY" = "true" ]; then
    log "Google Gemini was previously configured (use --gemini to reconfigure)"
elif [ "$IS_FIRST_PROVIDER_RUN" = "true" ]; then
    if ask_yes_no "Do you want to configure Google Gemini?" N; then
        configure_gemini
    else
        log "Skipping Google Gemini configuration"
    fi
fi

#############################################################################
# Phase 4: Claude Code
#############################################################################

log "Phase 4: Claude Code"

NATIVE_CLAUDE="$HOME/.local/bin/claude"
if [ -x "$NATIVE_CLAUDE" ]; then
    if [ "$UPGRADE_MODE" = "true" ]; then
        log "Upgrading Claude Code..."
        "$NATIVE_CLAUDE" update || warn "Claude Code update failed, continuing..."
    else
        log "Claude Code already installed (use --upgrade to refresh)"
    fi
else
    log "Installing Claude Code..."
    curl_secure -fsSL https://claude.ai/install.sh | bash
fi

#############################################################################
# Phase 5: Skills + statusline
#############################################################################

log "Phase 5: Skills + statusline"

if command -v claude &>/dev/null || [ -x "$NATIVE_CLAUDE" ]; then
    SKILLS_SOURCE_DIR="$REPO_DIR/skills"
    SKILLS_DEST_DIR="$HOME/.claude/skills"

    if [ -x "$SKILLS_SOURCE_DIR/update-external-skills.sh" ]; then
        log "Refreshing external skills..."
        "$SKILLS_SOURCE_DIR/update-external-skills.sh" || warn "External skills refresh failed, continuing..."
    fi

    if [ -d "$SKILLS_SOURCE_DIR" ]; then
        log "Syncing skills to $SKILLS_DEST_DIR"
        mkdir -p "$SKILLS_DEST_DIR"
        for skill_dir in "$SKILLS_SOURCE_DIR"/*/; do
            [ -d "$skill_dir" ] || continue
            skill_name=$(basename "$skill_dir")
            log "  $skill_name"
            cp -rf "$skill_dir" "$SKILLS_DEST_DIR/"
        done
    fi

    STATUSLINE_SOURCE="$SCRIPT_DIR/scripts/statusline.sh"
    STATUSLINE_DEST="$HOME/.claude/statusline.sh"
    SETTINGS_FILE="$HOME/.claude/settings.json"

    if [ -f "$STATUSLINE_SOURCE" ]; then
        log "Installing Claude Code statusline..."
        mkdir -p "$HOME/.claude"
        cp -f "$STATUSLINE_SOURCE" "$STATUSLINE_DEST"
        chmod +x "$STATUSLINE_DEST"

        if [ -f "$SETTINGS_FILE" ]; then
            jq '.statusLine = {"type": "command", "command": "~/.claude/statusline.sh"}' \
                "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" \
                && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        else
            cat > "$SETTINGS_FILE" <<'SETTINGS_EOF'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
SETTINGS_EOF
        fi
    fi
else
    warn "Claude Code not on PATH yet — skipping skills + statusline. Re-run after a new shell."
fi

#############################################################################
# Summary
#############################################################################

log ""
log "Setup complete."
log ""
log "  llm:        $(command -v llm 2>/dev/null || echo 'not on PATH — open a new shell')"
log "  claude:     $(command -v claude 2>/dev/null || echo 'not on PATH — open a new shell')"
log "  skills:     $HOME/.claude/skills/"
log "  statusline: $HOME/.claude/statusline.sh"
log ""
[ "$HAS_AZURE_KEY" = "true" ] && log "  Azure key:  configured"
[ "$HAS_GEMINI_KEY" = "true" ] && log "  Gemini key: configured"
log ""
log "Open a new shell so PATH changes take effect, then try: llm 'hi'"
