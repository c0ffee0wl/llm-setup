#!/bin/bash
#
# llm-setup
#
# Installs and updates Simon Willison's `llm` CLI (with a trimmed plugin set),
# Anthropic's Claude Code, and a set of Claude Code skills on Debian/Kali Linux.
#
# Runs as the current $USER. Idempotent: installs what is missing and upgrades
# whatever is already installed on every run. Self-updates from git on every run.
#
# Provider configuration (Azure / Gemini / etc.) is the user's job — see
# the README. Setup only seeds Azure model YAML templates the first time;
# never overwrites existing ones.
#
# Usage:
#   ./linux/setup.sh                # install missing tools + upgrade installed ones
#   ./linux/setup.sh --skip-skills  # same, but skip the skills sync
#

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"

#############################################################################
# Argument parsing
#############################################################################

ORIGINAL_ARGS=("$@")
SKIP_SKILLS=false

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Installed components (llm + plugins, Claude Code, gitingest) are upgraded
automatically on every run — there is no separate --upgrade flag.

Options:
  --skip-skills    Skip the skills sync (statusline is still installed)
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
        --skip-skills)
            SKIP_SKILLS=true
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
    warn "Running as root. This script is intended to run as your normal user; continuing anyway."
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

# bubblewrap (bwrap) is required by `blaude` (Phase 6) for Claude Code sandboxing.
install_apt_packages git curl jq ca-certificates bubblewrap

# On Ubuntu 24.04+/Kali, AppArmor restricts unprivileged user namespaces, which
# breaks bwrap. Install a permissive profile for bwrap (idempotent, sudo).
configure_bwrap_apparmor

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
ALL_PLUGINS=("${REMOTE_PLUGINS[@]}")

# State lives in the llm user config dir (where llm-uv-tool reads it).
LLM_CONFIG_DIR="$HOME/.config/io.datasette.llm"
LLM_FINGERPRINT_FILE="$LLM_CONFIG_DIR/llm-install-fingerprint"

# Fingerprint of the plugin list + source URL (not local code).
# Changes only when plugins are added/removed/changed — triggers full reinstall.
compute_plugin_list_fingerprint() {
    { printf 'llm:%s\n' "$LLM_SOURCE"
      printf '%s\n' "${ALL_PLUGINS[@]}" | sort
    } | sha256sum | awk '{print $1}'
}

# Detect user-installed plugins (added via `llm install`, not in ALL_PLUGINS).
# Reads uv-tool-packages.json before we overwrite it.
detect_user_plugins() {
    USER_PLUGINS=()
    local packages_file="$LLM_CONFIG_DIR/uv-tool-packages.json"
    [ -f "$packages_file" ] || return 0

    local p pkg
    local -A managed
    for p in "${ALL_PLUGINS[@]}"; do managed["$p"]=1; done
    managed["git+https://github.com/c0ffee0wl/llm-uv-tool"]=1

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        [ -z "${managed[$pkg]+_}" ] && USER_PLUGINS+=("$pkg")
    done < <(jq -r '.[]' "$packages_file" 2>/dev/null)

    if [ ${#USER_PLUGINS[@]} -gt 0 ]; then
        log "Preserving ${#USER_PLUGINS[@]} user-installed plugin(s)"
    fi
}

# Write uv-tool-packages.json so that future `llm install <user-plugin>` calls
# (handled by llm-uv-tool) preserve our git-fork URLs. llm-uv-tool's get_plugins()
# only sees distribution names (e.g. "llm-gemini"), not source URLs, so without
# this file it would fall back to PyPI on reinstall.
update_uv_tool_packages_json() {
    local packages_file="$LLM_CONFIG_DIR/uv-tool-packages.json"
    mkdir -p "$LLM_CONFIG_DIR"
    # Keep the `if` as the group's last command so the brace group exits 0 when
    # there are no user plugins — otherwise pipefail + set -e would abort here.
    {
        printf '%s\n' "${ALL_PLUGINS[@]}" | grep -v "llm-uv-tool"
        if [ ${#USER_PLUGINS[@]} -gt 0 ]; then printf '%s\n' "${USER_PLUGINS[@]}"; fi
    } | sort -u | jq -R . | jq -s . > "$packages_file"
}

LLM_PLUGIN_FINGERPRINT=$(compute_plugin_list_fingerprint)
STORED_FINGERPRINT=$(cat "$LLM_FINGERPRINT_FILE" 2>/dev/null || echo "")

if ! command -v llm &>/dev/null || ! uv tool list 2>/dev/null | grep -q '^llm ' || \
   [ "$LLM_PLUGIN_FINGERPRINT" != "$STORED_FINGERPRINT" ]; then

    # Full install: first run, llm missing, or the plugin list changed.
    detect_user_plugins

    INSTALL_ARGS=(uv tool install --force)
    for plugin in "${ALL_PLUGINS[@]}" "${USER_PLUGINS[@]}"; do
        INSTALL_ARGS+=(--with "$plugin")
    done
    INSTALL_ARGS+=("$LLM_SOURCE")

    log "Installing llm with $(( ${#ALL_PLUGINS[@]} + ${#USER_PLUGINS[@]} )) plugins..."
    "${INSTALL_ARGS[@]}"

    update_uv_tool_packages_json

    mkdir -p "$LLM_CONFIG_DIR"
    echo "$LLM_PLUGIN_FINGERPRINT" > "$LLM_FINGERPRINT_FILE"
    log "llm and plugins ready"
else
    # Incremental upgrade: pull latest git commits + PyPI updates, keep the venv
    # (llm-uv-tool preserves the plugin set across the upgrade). Non-fatal so a
    # transient network/registry failure doesn't abort the rest of setup.
    log "Upgrading llm and plugins..."
    uv tool upgrade llm || warn "llm upgrade failed, continuing..."
    log "llm and plugins upgraded"
fi

#############################################################################
# Phase 3: Seed llm provider config templates
#############################################################################
#
# We only seed the Azure model YAML templates on first run — never overwrite
# user edits. Provider keys (`llm keys set ...`) and the default model
# (`llm models default ...`) are the user's responsibility; see README.

log "Phase 3: Seed Azure config templates"

# LLM_CONFIG_DIR is defined in Phase 2.
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
    log "Updating Claude Code..."
    "$NATIVE_CLAUDE" update || warn "Claude Code update failed, continuing..."
else
    log "Installing Claude Code..."
    curl_secure -fsSL https://claude.ai/install.sh | bash
fi

#############################################################################
# Phase 5: Skills + statusline
#############################################################################

log "Phase 5: Skills + statusline"

if command -v claude &>/dev/null || [ -x "$NATIVE_CLAUDE" ]; then
    if [ "$SKIP_SKILLS" = "true" ]; then
        log "Skipping skills sync (--skip-skills)"
    else
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

# gitingest — Git repo → LLM-friendly text (helper auto-detects install vs upgrade)
install_or_upgrade_uv_tool gitingest

# imagemage — Gemini image-generation CLI (used by the image-generation skill).
# Install-if-missing only: a Go rebuild on every run would be wasteful.
IMAGEMAGE_BIN="$HOME/.local/bin/imagemage"
if [ -x "$IMAGEMAGE_BIN" ]; then
    log "imagemage already installed"
elif install_go; then
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

# blaude — bubblewrap sandbox wrapper for Claude Code (raw script from the
# c0ffee0wl/blaude repo). Always re-fetched, so it is refreshed on every run.
# Requires bwrap (installed in Phase 1). The osc52-clipboard script from the
# same repo is intentionally NOT installed.
mkdir -p "$HOME/.local/bin"
install_blaude_repo_script blaude

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
log "  blaude:     $([ -x "$HOME/.local/bin/blaude" ] && echo "$HOME/.local/bin/blaude" || echo 'not installed')"
log "  skills:     $HOME/.claude/skills/"
log "  statusline: $HOME/.claude/statusline.sh"
log ""
log "To use Azure or Gemini:"
log "  1. Edit $LLM_CONFIG_DIR/extra-openai-models.yaml (replace __AZURE_API_BASE__)"
log "  2. llm keys set azure          # or: llm keys set gemini"
log "  3. llm models default azure/gpt-4.1-mini"
log ""
log "Open a new shell so PATH changes take effect, then try: llm 'hi'"
