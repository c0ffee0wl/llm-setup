# llm-setup

Lean Linux installer for [Simon Willison's `llm` CLI](https://github.com/simonw/llm), [Anthropic's Claude Code](https://claude.com/claude-code), and a curated set of Claude Code skills.

Runs as a regular user on Debian / Kali (no WSL ties, no system-level hardening, no GUI integrations). Self-updates from git on every run.

## Quick Start

```bash
git clone https://github.com/c0ffee0wl/llm-setup ~/llm-setup
cd ~/llm-setup
./linux/setup.sh
```

That installs `llm` with a trimmed plugin set, Claude Code, and copies the skills into `~/.claude/skills/`. Provider configuration (Azure / Gemini keys, default model) is the user's responsibility — see below.

## Provider setup

Setup seeds Azure model YAML templates into `~/.config/io.datasette.llm/` on first run. Configure your provider manually:

**Azure OpenAI:**

```bash
# 1. Replace __AZURE_API_BASE__ with your resource URL
#    e.g. https://YOUR-RESOURCE.cognitiveservices.azure.com/openai/v1/
nano ~/.config/io.datasette.llm/extra-openai-models.yaml
nano ~/.config/io.datasette.llm/azure-embeddings-models.yaml

# 2. Set your API key
llm keys set azure

# 3. Set the default model
llm models default azure/gpt-4.1-mini
```

**Google Gemini:**

```bash
llm keys set gemini
llm models default gemini-2.5-flash
```

**Anthropic, OpenRouter, etc.:** likewise, `llm keys set <provider>` then `llm models default <model>`.

Re-running `./linux/setup.sh` will never overwrite an existing YAML in `~/.config/io.datasette.llm/`, so your edits persist.

## Setup Modes

| Command | What it does |
|---|---|
| `./linux/setup.sh` | Install missing tools, upgrade already-installed ones, seed Azure YAML templates if absent |
| `./linux/setup.sh --skip-skills` | Same, but skip the skills sync (statusline still installed) |
| `./linux/setup.sh --clear-cache` | Purge package-manager caches (npm, go, pip, pipx, cargo, uv) and exit |
| `./linux/setup.sh --uninstall` | Remove what this script installed (prompts per group; keeps user data) |
| `./linux/setup.sh --uninstall --dry-run` | Preview the uninstall — list every action, change nothing |
| `./linux/setup.sh --uninstall --force` | Uninstall everything without per-group prompts |

The install/upgrade run is idempotent and non-interactive: re-running is safe; the script never prompts. There is **no `--upgrade` flag** — installed components (`llm` + plugins, Claude Code, `gitingest`) are upgraded automatically on every run. `llm` is fully reinstalled only when its plugin list changes (tracked by a fingerprint); otherwise it gets a fast `uv tool upgrade`. `imagemage` is install-if-missing only (no per-run Go rebuild). Every normal run also purges package-manager caches at the end (same as a standalone `--clear-cache`).

If `claude` is actively running, setup refuses to proceed (Phase 0 self-update, `claude update`, and `--uninstall` can swap or remove the binary under a live session). Stop your Claude session, then re-run. `--clear-cache` is exempt — it changes no binaries and works during a session.

### Uninstall

`--uninstall` removes only what this script installs, one group at a time (answer `Y`/`n` per group, or pass `--force` to remove all without asking; `--dry-run` previews):

- `llm` + all its plugins (the `llm` uv tool), together with its install-state files (`llm-install-fingerprint`, `uv-tool-packages.json`) — bundled so that *keeping* `llm` keeps its plugin manifest intact — and `gitingest`
- the Claude Code binary (`~/.local/bin/claude`) and `~/.local/bin/{imagemage,blaude}`
- this repo's skills under `~/.claude/skills/` (local **and** external ones listed in `skills/external-skills.yaml`) and `~/.claude/statusline.sh`
- the AppArmor `bwrap` profile (`/etc/apparmor.d/bwrap`, via sudo — unloaded from the kernel, then removed)

**Preserved:** your API keys, default model, and seeded Azure YAML in `~/.config/io.datasette.llm/`; `~/.config/uv/uv.toml`; a customised `~/.claude/settings.json` (removed only if byte-identical to the fresh-install template); system apt packages (`git curl jq bubblewrap`) and runtimes (`uv`, `pipx`, `go`).

## What's installed

- **`llm` CLI** (from the [c0ffee0wl/llm](https://github.com/c0ffee0wl/llm) fork) with: provider plugins (`llm-gemini`, `llm-vertex`, `llm-anthropic`, `llm-openrouter`), `llm-cmd`, `llm-git-commit`, `llm-jq`, `llm-templates-fabric`, fragment loaders (`llm-fragments-github`, `llm-fragments-pdf`, `llm-fragments-site-text`, `llm-fragments-dir`, `llm-fragments-youtube-transcript`), `llm-sort`, `llm-classify`, and `llm-uv-tool` (plugin persistence across `uv tool upgrade`).
- **Claude Code** via the official `claude.ai/install.sh` installer.
- **Claude Code skills** copied from this repo's `skills/` to `~/.claude/skills/`. External skills listed in `skills/external-skills.yaml` are refreshed on every run.
- **Claude Code statusline** at `~/.claude/statusline.sh` (a LiteLLM-aware variant shared with [claude-litellm](https://github.com/c0ffee0wl/claude-litellm); degrades gracefully without LiteLLM). `~/.claude/settings.json` is written only on first install — never clobbered.
- **`gitingest`** (uv tool) — turns a git repo into LLM-friendly text.
- **`imagemage`** (Go binary at `~/.local/bin/imagemage`) — Gemini image-generation CLI used by the `image-generation` skill. Needs Go ≥ 1.22 (installed from apt if missing); silently skipped if apt can't supply a recent enough Go.
- **`blaude`** (script at `~/.local/bin/blaude`) — a [bubblewrap](https://github.com/containers/bubblewrap) sandbox wrapper for Claude Code, fetched from [c0ffee0wl/blaude](https://github.com/c0ffee0wl/blaude). The `bubblewrap` package is installed from apt; on Kali/Ubuntu 24.04+ an AppArmor profile for `bwrap` is also written (`/etc/apparmor.d/bwrap`, via sudo) so unprivileged user namespaces work. The companion `osc52-clipboard` script is **not** installed.

## Layout

```
llm-setup/
├── README.md                # this file
├── CLAUDE.md                # agent guidance
├── skills/                  # Claude Code skills (platform-agnostic)
└── linux/
    ├── setup.sh             # entry point (6 phases)
    ├── common.sh            # helper library
    ├── configs/             # Azure model YAML templates
    └── scripts/statusline.sh
```
