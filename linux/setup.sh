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
# Provider configuration (Azure / Gemini / etc.) is the user's job — see
# the README. Setup only seeds Azure model YAML templates the first time;
# never overwrites existing ones.
#
# Usage:
#   ./linux/setup.sh             # install missing tools, seed configs
#   ./linux/setup.sh --upgrade   # also upgrade llm + claude code if installed
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

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --upgrade        Upgrade llm + plugins and Claude Code if already installed
  --help, -h       Show this help and exit

Provider keys, default model, and Azure URLs are NOT configured by this
script. After install, edit ~/.config/io.datasette.llm/extra-openai-models.yaml
(or azure-embeddings-models.yaml) to set your Azure resource URL, then:

    llm keys set azure         # or: llm keys set gemini
    llm models default azure/gpt-4.1-mini
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upgrade)
            UPGRADE_MODE=true
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

if [ "$EUID" -eq 0 ]; then
    error "Do not run this script as root. Run it as your normal user."
fi

#############################################################################
# Active-session guard
#############################################################################

# Refuse to run while Claude Code is active: Phase 0 self-update and Phase 4
# `claude update` can replace the binary mid-session.
if pgrep -u "$USER" -x claude &>/dev/null; then
    warn "Claude Code is running — refusing to update tools mid-session."
    warn "Stop claude (or wait until it exits), then re-run this script."
    exit 0
fi

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

log "Refreshing apt index..."
sudo apt-get update -qq

install_apt_packages git curl jq ca-certificates
install_or_upgrade_uv

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
# Phase 3: Seed llm provider config templates
#############################################################################
#
# We only seed the Azure model YAML templates on first run — never overwrite
# user edits. Provider keys (`llm keys set ...`) and the default model
# (`llm models default ...`) are the user's responsibility; see README.

log "Phase 3: Seed Azure config templates"

LLM_CONFIG_DIR="$HOME/.config/io.datasette.llm"
mkdir -p "$LLM_CONFIG_DIR"

for cfg in extra-openai-models.yaml azure-embeddings-models.yaml; do
    src="$SCRIPT_DIR/configs/$cfg"
    dst="$LLM_CONFIG_DIR/$cfg"
    if [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        log "Seeded $dst — edit to set your Azure resource URL"
    else
        log "$dst exists, leaving untouched"
    fi
done

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

        # Deploy settings.json only on fresh install — never clobber the user's
        # existing file (it may carry trust, theme, permissions, etc.).
        if [ -f "$SETTINGS_FILE" ]; then
            log "$SETTINGS_FILE exists, leaving untouched (add statusLine manually if desired)"
        else
            cat > "$SETTINGS_FILE" <<'SETTINGS_EOF'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
SETTINGS_EOF
            log "Wrote $SETTINGS_FILE with statusLine pointer"
        fi
    fi
else
    warn "Claude Code not on PATH yet — skipping skills + statusline. Re-run after a new shell."
fi

#############################################################################
# Phase 6: Additional CLI tools
#############################################################################

log "Phase 6: Additional CLI tools"

# gitingest — Git repo → LLM-friendly text
if ! command -v gitingest &>/dev/null; then
    install_or_upgrade_uv_tool gitingest
elif [ "$UPGRADE_MODE" = "true" ]; then
    install_or_upgrade_uv_tool gitingest
else
    log "gitingest already installed (use --upgrade to refresh)"
fi

# imagemage — Gemini image-generation CLI (used by the image-generation skill)
IMAGEMAGE_BIN="$HOME/.local/bin/imagemage"
NEED_IMAGEMAGE_BUILD=false
if [ ! -x "$IMAGEMAGE_BIN" ]; then
    NEED_IMAGEMAGE_BUILD=true
elif [ "$UPGRADE_MODE" = "true" ]; then
    NEED_IMAGEMAGE_BUILD=true
else
    log "imagemage already installed (use --upgrade to refresh)"
fi

if [ "$NEED_IMAGEMAGE_BUILD" = "true" ]; then
    if install_go; then
        log "Building imagemage from source..."
        mkdir -p "$(dirname "$IMAGEMAGE_BIN")"
        IMAGEMAGE_DIR="$(mktemp -d)"
        trap 'rm -rf "$IMAGEMAGE_DIR"' EXIT
        git clone --depth 1 https://github.com/c0ffee0wl/imagemage.git "$IMAGEMAGE_DIR"
        (cd "$IMAGEMAGE_DIR" && go build -o "$IMAGEMAGE_BIN" .)
        rm -rf "$IMAGEMAGE_DIR"
        trap - EXIT
        log "imagemage installed to $IMAGEMAGE_BIN"
    else
        warn "Skipping imagemage (Go unavailable). Install Go >= 1.22 and re-run."
    fi
fi

#############################################################################
# Summary
#############################################################################

log ""
log "Setup complete."
log ""
log "  llm:        $(command -v llm 2>/dev/null || echo 'not on PATH — open a new shell')"
log "  claude:     $(command -v claude 2>/dev/null || echo 'not on PATH — open a new shell')"
log "  gitingest:  $(command -v gitingest 2>/dev/null || echo 'not installed')"
log "  imagemage:  $([ -x "$HOME/.local/bin/imagemage" ] && echo "$HOME/.local/bin/imagemage" || echo 'not installed')"
log "  skills:     $HOME/.claude/skills/"
log "  statusline: $HOME/.claude/statusline.sh"
log ""
log "To use Azure or Gemini:"
log "  1. Edit $LLM_CONFIG_DIR/extra-openai-models.yaml (replace __AZURE_API_BASE__)"
log "  2. llm keys set azure          # or: llm keys set gemini"
log "  3. llm models default azure/gpt-4.1-mini"
log ""
log "Open a new shell so PATH changes take effect, then try: llm 'hi'"
