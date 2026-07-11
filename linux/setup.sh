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
#   ./linux/setup.sh                  # install missing tools + upgrade installed ones
#   ./linux/setup.sh --skip-skills    # same, but skip the skills sync
#   ./linux/setup.sh --clear-cache    # purge package-manager caches and exit
#   ./linux/setup.sh --uninstall      # remove what this script installed (prompts per group)
#   ./linux/setup.sh --uninstall --dry-run   # preview the uninstall without changing anything
#   ./linux/setup.sh --uninstall --force     # uninstall everything without prompts
#
# Every normal run also purges package-manager caches at the end.
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
UNINSTALL=false
CLEAR_CACHE=false
DRY_RUN=false
FORCE_UNINSTALL=false

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Installed components (llm + plugins, Claude Code, gitingest) are upgraded
automatically on every run — there is no separate --upgrade flag. Every normal
run also purges package-manager caches at the end.

Options:
  --skip-skills    Skip the skills sync (statusline is still installed)
  --clear-cache    Purge package-manager caches (npm, go, pip, pipx, cargo, uv) and exit
  --uninstall      Remove what this script installed (prompts per group; keeps user data)
  --dry-run        With --uninstall: show what would be removed without changing anything
  --force          With --uninstall: skip per-group prompts and remove everything
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
        --clear-cache)
            CLEAR_CACHE=true
            ;;
        --uninstall)
            UNINSTALL=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --force)
            FORCE_UNINSTALL=true
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
# Shared definitions used by both install and uninstall
#############################################################################

# llm config dir (where llm-uv-tool reads its state) and the two Phase 2
# state files that live there. Shared so the uninstall path removes exactly
# what the install path writes.
LLM_CONFIG_DIR="$HOME/.config/io.datasette.llm"
LLM_FINGERPRINT_FILE="$LLM_CONFIG_DIR/llm-install-fingerprint"
LLM_PACKAGES_FILE="$LLM_CONFIG_DIR/uv-tool-packages.json"

# Claude Code user-state paths that Phase 5 writes and uninstall removes.
CLAUDE_DIR="$HOME/.claude"
CLAUDE_SKILLS_DIR="$CLAUDE_DIR/skills"
STATUSLINE_DEST="$CLAUDE_DIR/statusline.sh"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

# The settings.json we deploy on a fresh install (Phase 5). Defined once so the
# uninstall path can recognise an unmodified file and remove only that.
settings_template() {
    cat <<'SETTINGS_EOF'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
SETTINGS_EOF
}

#############################################################################
# Uninstall (footprint-scoped: removes only what this script installs)
#############################################################################

# Remove what this script installed. User data (API keys, default model, seeded
# Azure YAML), uv/uv.toml, a user-modified settings.json, apt packages, and
# runtimes (uv, pipx, go) are preserved. Honors DRY_RUN and FORCE_UNINSTALL.
run_uninstall() {
    UNINSTALL_SKIPPED=()
    local removed_anything=false

    log "llm-setup Uninstall"
    if [ "$DRY_RUN" = "true" ]; then
        log "Mode: DRY RUN — nothing will be changed"
    fi
    if [ "$FORCE_UNINSTALL" = "true" ]; then
        log "Mode: --force — no per-group prompts"
    fi
    echo ""
    log "User data is preserved (~/.config/io.datasette.llm keys/default model/seeded YAML,"
    log "~/.config/uv/uv.toml, a customised ~/.claude/settings.json). System apt packages and"
    log "runtimes (uv, pipx, go) are NOT removed."
    echo ""

    # 1. llm core + all plugins (single uv tool — removing llm drops the whole env),
    #    together with the install-state files that only describe that env. Kept in one
    #    group so a "keep llm" choice never strands llm-uv-tool's plugin manifest — a
    #    later run reads uv-tool-packages.json to preserve user-installed plugins.
    if confirm_uninstall "LLM core tool, all installed plugins (uv tool 'llm'), and its install state"; then
        uninstall_uv_tool llm
        remove_path "$LLM_FINGERPRINT_FILE"
        remove_path "$LLM_PACKAGES_FILE"
        removed_anything=true
    fi

    # 2. gitingest (the other uv tool this script installs)
    if confirm_uninstall "gitingest (uv tool)"; then
        uninstall_uv_tool gitingest
        removed_anything=true
    fi

    # 3. Claude Code native binary
    if confirm_uninstall "Claude Code native binary (~/.local/bin/claude)"; then
        remove_path "$HOME/.local/bin/claude" "(in use? try again from another shell)"
        removed_anything=true
    fi

    # 4. CLI binaries this script drops in ~/.local/bin
    if confirm_uninstall "CLI binaries (~/.local/bin/{imagemage,blaude})"; then
        local bin
        for bin in imagemage blaude; do
            remove_path "$HOME/.local/bin/$bin"
        done
        removed_anything=true
    fi

    # 5. Claude Code skills + statusline. Remove every skill this repo manages:
    #    committed local dirs PLUS the external-skills.yaml entries (and their
    #    `old_name` migration targets), so externals aren't orphaned when uninstalling
    #    from a checkout that never fetched them into skills/.
    if confirm_uninstall "Claude Code skills + statusline (~/.claude/skills/<managed>, ~/.claude/statusline.sh)"; then
        local manifest="$REPO_DIR/skills/external-skills.yaml"
        local -A managed_skills=()
        local name skill_dir
        if [ -d "$REPO_DIR/skills" ]; then
            for skill_dir in "$REPO_DIR"/skills/*/; do
                [ -d "$skill_dir" ] || continue
                managed_skills["$(basename "$skill_dir")"]=1
            done
        fi
        if [ -f "$manifest" ]; then
            # Pull `name:` / `old_name:` values without needing a YAML parser at
            # uninstall time. Comment lines start with `#`, so they don't match.
            while IFS= read -r name; do
                [ -n "$name" ] || continue
                # Skip traversal / absolute names so the rm -rf below stays under skills/.
                [[ "$name" == *..* || "$name" == */* ]] && continue
                managed_skills["$name"]=1
            done < <(grep -oE '^[[:space:]]*(-[[:space:]]+)?(name|old_name):[[:space:]]*[^[:space:]]+' "$manifest" 2>/dev/null \
                        | sed -E 's/.*:[[:space:]]*//')
        fi
        for name in "${!managed_skills[@]}"; do
            remove_path "$CLAUDE_SKILLS_DIR/$name"
        done
        remove_path "$STATUSLINE_DEST"
        # settings.json — remove only if byte-identical to our fresh-install template
        # (it may carry the user's trust/theme/permissions otherwise).
        if [ -f "$SETTINGS_FILE" ]; then
            if diff -q <(settings_template) "$SETTINGS_FILE" >/dev/null 2>&1; then
                remove_path "$SETTINGS_FILE"
            else
                warn "Keeping $SETTINGS_FILE — appears user-modified"
            fi
        fi
        removed_anything=true
    fi

    # 6. AppArmor bwrap profile (the only thing this script writes outside $HOME; sudo).
    #    Unload from the kernel BEFORE deleting the file: `apparmor_parser -R` reads the
    #    named profile to learn what to unload, so the file must still exist at that point.
    if confirm_uninstall "AppArmor bwrap profile (/etc/apparmor.d/bwrap — requires sudo)"; then
        if [ -f /etc/apparmor.d/bwrap ]; then
            if command -v apparmor_parser >/dev/null 2>&1; then
                do_or_dry "sudo apparmor_parser -R /etc/apparmor.d/bwrap" \
                    bash -c 'sudo apparmor_parser -R /etc/apparmor.d/bwrap 2>/dev/null || true'
            fi
            do_or_dry "sudo rm /etc/apparmor.d/bwrap" sudo rm -f /etc/apparmor.d/bwrap \
                || warn "Failed to remove /etc/apparmor.d/bwrap"
        fi
        removed_anything=true
    fi

    # Final report
    echo ""
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run complete. No changes were made."
    elif [ "$removed_anything" = "true" ]; then
        log "Uninstall complete."
    else
        log "Nothing to uninstall (or all groups skipped)."
    fi

    if [ "${#UNINSTALL_SKIPPED[@]}" -gt 0 ]; then
        echo ""
        log "Skipped groups (kept on system):"
        local s
        for s in "${UNINSTALL_SKIPPED[@]}"; do
            echo "  - $s"
        done
    fi

    echo ""
    log "Preserved (not touched by --uninstall):"
    echo "  - ~/.config/io.datasette.llm/   (keys.json, default_model.txt, seeded Azure YAML)"
    echo "  - ~/.config/uv/uv.toml          (python-preference)"
    echo "  - ~/.claude/settings.json       (when user-modified)"
    echo "  - System apt packages (git curl jq bubblewrap) and runtimes (uv, pipx, go)"
}

#############################################################################
# Standalone ops: --clear-cache / --uninstall
#############################################################################

# --clear-cache is a standalone utility op (no binary replacement), so it is safe
# during a live Claude Code session — run it before the session guard and exit.
if [ "$CLEAR_CACHE" = true ]; then
    clear_package_caches
    exit 0
fi

# --force / --dry-run only make sense alongside --uninstall. Use `if` blocks (not
# `&&`) so a false test isn't the script's exit status under `set -eo pipefail`.
if [ "$UNINSTALL" != true ]; then
    if [ "$FORCE_UNINSTALL" = true ]; then
        error "--force only applies to --uninstall. Use --uninstall --force to remove everything without prompts."
    fi
    if [ "$DRY_RUN" = true ]; then
        error "--dry-run only applies to --uninstall."
    fi
fi

#############################################################################
# Active-session guard
#############################################################################

# Refuse to run while Claude Code is active: Phase 0 self-update, Phase 4
# `claude update`, and --uninstall can replace or remove the binary mid-session.
if pgrep -u "$USER" -x claude &>/dev/null; then
    warn "Claude Code is running — refusing to update or remove tools mid-session."
    warn "Stop claude (or wait until it exits), then re-run this script."
    exit 0
fi

# --uninstall removes the claude binary, so it runs after the session guard.
# Standalone op — run and exit before any install / self-update work.
if [ "$UNINSTALL" = true ]; then
    run_uninstall
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

# The apt index is refreshed lazily (apt_update_once) just before an actual
# install, so a steady-state re-run pays no multi-second refresh.
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

# LLM_CONFIG_DIR and the state-file paths are defined in the shared section.
mkdir -p "$LLM_CONFIG_DIR"   # created once here; Phase 2/3 writers rely on it

# Fingerprint of the plugin list + source URL (not local code).
# Changes only when plugins are added/removed/changed — triggers full reinstall.
compute_plugin_list_fingerprint() {
    { printf 'llm:%s\n' "$LLM_SOURCE"
      printf '%s\n' "${REMOTE_PLUGINS[@]}" | sort
    } | sha256sum | awk '{print $1}'
}

# Detect user-installed plugins (added via `llm install`, not in REMOTE_PLUGINS).
# Reads uv-tool-packages.json before we overwrite it.
detect_user_plugins() {
    USER_PLUGINS=()
    [ -f "$LLM_PACKAGES_FILE" ] || return 0

    local p pkg
    local -A managed
    for p in "${REMOTE_PLUGINS[@]}"; do managed["$p"]=1; done

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        [ -z "${managed[$pkg]+_}" ] && USER_PLUGINS+=("$pkg")
    done < <(jq -r '.[]' "$LLM_PACKAGES_FILE" 2>/dev/null)

    if [ ${#USER_PLUGINS[@]} -gt 0 ]; then
        log "Preserving ${#USER_PLUGINS[@]} user-installed plugin(s)"
    fi
}

# Write uv-tool-packages.json so that future `llm install <user-plugin>` calls
# (handled by llm-uv-tool) preserve our git-fork URLs. llm-uv-tool's get_plugins()
# only sees distribution names (e.g. "llm-gemini"), not source URLs, so without
# this file it would fall back to PyPI on reinstall.
update_uv_tool_packages_json() {
    # Keep the `if` as the group's last command so the brace group exits 0 when
    # there are no user plugins — otherwise pipefail + set -e would abort here.
    {
        printf '%s\n' "${REMOTE_PLUGINS[@]}" | grep -v "llm-uv-tool"
        if [ ${#USER_PLUGINS[@]} -gt 0 ]; then printf '%s\n' "${USER_PLUGINS[@]}"; fi
    } | sort -u | jq -R . | jq -s . > "$LLM_PACKAGES_FILE"
}

LLM_PLUGIN_FINGERPRINT=$(compute_plugin_list_fingerprint)
STORED_FINGERPRINT=$(cat "$LLM_FINGERPRINT_FILE" 2>/dev/null || echo "")

if ! command -v llm &>/dev/null || ! uv_tool_installed llm || \
   [ "$LLM_PLUGIN_FINGERPRINT" != "$STORED_FINGERPRINT" ]; then

    # Full install: first run, llm missing, or the plugin list changed.
    detect_user_plugins

    INSTALL_ARGS=(uv tool install --force)
    for plugin in "${REMOTE_PLUGINS[@]}" "${USER_PLUGINS[@]}"; do
        INSTALL_ARGS+=(--with "$plugin")
    done
    INSTALL_ARGS+=("$LLM_SOURCE")

    log "Installing llm with $(( ${#REMOTE_PLUGINS[@]} + ${#USER_PLUGINS[@]} )) plugins..."
    "${INSTALL_ARGS[@]}"

    update_uv_tool_packages_json

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

# Every template in configs/ is seeded; a new file there needs no code change.
for src in "$SCRIPT_DIR"/configs/*.yaml; do
    [ -f "$src" ] || continue   # unmatched glob stays literal — skip it
    dst="$LLM_CONFIG_DIR/$(basename "$src")"
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

        if [ -x "$SKILLS_SOURCE_DIR/update-external-skills.sh" ]; then
            log "Refreshing external skills..."
            "$SKILLS_SOURCE_DIR/update-external-skills.sh" || warn "External skills refresh failed, continuing..."
        fi

        if [ -d "$SKILLS_SOURCE_DIR" ]; then
            log "Syncing skills to $CLAUDE_SKILLS_DIR"
            mkdir -p "$CLAUDE_SKILLS_DIR"
            for skill_dir in "$SKILLS_SOURCE_DIR"/*/; do
                [ -d "$skill_dir" ] || continue
                skill_name=$(basename "$skill_dir")
                log "  $skill_name"
                cp -rf "$skill_dir" "$CLAUDE_SKILLS_DIR/"
            done
        fi
    fi

    STATUSLINE_SOURCE="$SCRIPT_DIR/scripts/statusline.sh"

    if [ -f "$STATUSLINE_SOURCE" ]; then
        log "Installing Claude Code statusline..."
        mkdir -p "$CLAUDE_DIR"
        cp -f "$STATUSLINE_SOURCE" "$STATUSLINE_DEST"
        chmod +x "$STATUSLINE_DEST"

        # Deploy settings.json only on fresh install — never clobber the user's
        # existing file (it may carry trust, theme, permissions, etc.).
        if [ -f "$SETTINGS_FILE" ]; then
            log "$SETTINGS_FILE exists, leaving untouched (add statusLine manually if desired)"
        else
            settings_template > "$SETTINGS_FILE"
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
    install_go_tool_from_source https://github.com/c0ffee0wl/imagemage.git "$IMAGEMAGE_BIN"
    log "imagemage installed to $IMAGEMAGE_BIN"
else
    warn "Skipping imagemage (Go unavailable). Install Go >= 1.22 and re-run."
fi

# blaude — bubblewrap sandbox wrapper for Claude Code (raw script from the
# c0ffee0wl/blaude repo). Always re-fetched, so it is refreshed on every run.
# Requires bwrap (installed in Phase 1). The osc52-clipboard script from the
# same repo is intentionally NOT installed.
install_blaude_repo_script blaude

#############################################################################
# Reclaim disk space
#############################################################################

# Purge package-manager caches at the end of every run (mirrors llm-linux-setup).
# Non-fatal: a cache hiccup must never fail an otherwise-successful setup.
clear_package_caches || true

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
log "  skills:     $CLAUDE_SKILLS_DIR/"
log "  statusline: $STATUSLINE_DEST"
log ""
log "To use Azure or Gemini:"
log "  1. Edit $LLM_CONFIG_DIR/extra-openai-models.yaml (replace __AZURE_API_BASE__)"
log "  2. llm keys set azure          # or: llm keys set gemini"
log "  3. llm models default azure/gpt-4.1-mini"
log ""
log "Open a new shell so PATH changes take effect, then try: llm 'hi'"
