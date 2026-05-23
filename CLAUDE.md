# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project Overview

`llm-setup` is a lean Linux deployment repo for Simon Willison's `llm` CLI, Anthropic's Claude Code, and a curated set of Claude Code skills. It is intentionally narrow — no daemons, no shell integrations, no desktop wrappers, **no interactive provider configuration**. The previous form lived as `llm-linux-setup` and was cut down for this variant; see `PLAN.md` for rationale.

There is no build system, test suite, or linter — it's a deployment automation repo of Bash scripts plus YAML configs.

## Architecture

Single execution context: Linux. Runs as the current `$USER`. `sudo` is invoked only for `apt-get`.

Entry point: `linux/setup.sh`. It sources `linux/common.sh` for utilities and runs six numbered phases (plus Phase 0 self-update).

Flags (not persisted across reruns):
- `--upgrade` — refresh `llm` (re-installs with `uv tool install --force --with ...`) and run `claude update`.

The script is fully non-interactive — it never prompts the user.

The script refuses to run when `pgrep -u "$USER" -x claude` finds an active Claude Code session — Phase 0 self-update and Phase 4 `claude update` can replace the binary mid-session.

## Setup Phases (`linux/setup.sh`)

| Phase | What |
|---|---|
| 0 | Self-update: `git fetch` + `git pull --ff-only` + `exec "$0" "$@"` if behind. Skipped when not in a git checkout or when no remote is configured. |
| 1 | apt: `git curl jq ca-certificates`; `install_or_upgrade_uv` (which also runs `configure_uv_system_python`). No Node.js — Claude Code is now a native binary, and `llm` is pure Python. |
| 2 | `llm` install (or refresh under `--upgrade`) with the trimmed plugin set, single `uv tool install --force --with ...` invocation. Plugin list lives at the top of Phase 2 in `linux/setup.sh`. |
| 3 | Seed Azure model YAML templates: copy `linux/configs/extra-openai-models.yaml` and `azure-embeddings-models.yaml` to `~/.config/io.datasette.llm/` only if those files do not already exist. User edits `__AZURE_API_BASE__`; user runs `llm keys set` / `llm models default` themselves. |
| 4 | Claude Code: official `https://claude.ai/install.sh` curl pipe on first install; `claude update` under `--upgrade`. |
| 5 | Sync top-level `skills/` → `~/.claude/skills/` (calls `skills/update-external-skills.sh` first if present); install `linux/scripts/statusline.sh` → `~/.claude/statusline.sh`; write `~/.claude/settings.json` with a statusLine pointer **only on fresh install** (never overwrite an existing file). |
| 6 | Additional CLI tools: `gitingest` (via `install_or_upgrade_uv_tool`) and `imagemage` (Go build of `c0ffee0wl/imagemage` → `~/.local/bin/imagemage`, via `install_go` from apt; skipped with a warning if Go ≥ 1.22 isn't available). Install-if-missing by default; `--upgrade` refreshes both. |

## Key Conventions

- **Idempotency**: every phase is safe to re-run. The seeded YAML templates, `~/.claude/settings.json`, and any user edits are never clobbered.
- **Install-if-missing-only by default**: `llm` and Claude Code are not auto-upgraded. Pass `--upgrade` to refresh.
- **Active-session guard**: pgrep for `claude` at the top of the script — exits cleanly if a session is running.
- **No interactive provider config**: the script deliberately does not prompt for Azure URLs, API keys, or default models. That state belongs to the user and lives in the `llm` config dir (`~/.config/io.datasette.llm/`) + the llm key store. README documents the manual steps.
- **Plugin list**: a single `REMOTE_PLUGINS=( ... )` array in Phase 2 of `linux/setup.sh` is the only source of truth. `llm-uv-tool` (c0ffee0wl fork) must be first so plugins persist across `uv tool upgrade llm`.
- **`llm` is a fork**: installed from `git+https://github.com/c0ffee0wl/llm` (markdown rendering enhancements). To revert to upstream, change `LLM_SOURCE` at the top of Phase 2.
- **Skills location**: `skills/` lives at the top level, not under `linux/`, because skills are platform-agnostic and a future `windows/` variant would consume the same directory.
- **Phase 6 tools are standalone**: `gitingest` and `imagemage` are independent CLIs — not plugins of `llm`. They use the `install_or_upgrade_uv_tool` / `install_go` helpers in `common.sh`. `imagemage` is required by the `image-generation` skill; without it the skill is non-functional.

## Important Paths

- `~/.local/bin/{llm,claude,gitingest,imagemage}` — CLI entry points
- `~/.local/share/uv/tools/llm/` — uv-managed virtualenv for `llm` and its plugins
- `~/.config/io.datasette.llm/` — llm config: seeded `extra-openai-models.yaml` and `azure-embeddings-models.yaml`; user-managed `default_model.txt` and `keys.json`
- `~/.config/uv/uv.toml` — `python-preference = "system"` (set by `configure_uv_system_python`)
- `~/.claude/{skills/, statusline.sh, settings.json}` — Claude Code user state (settings.json created only on fresh install)

## What's intentionally absent

- No `--azure` / `--gemini` flags, no `configure_*` provider functions, no `--yes` / `--no` flags. Users own provider state and the script never prompts.
- No CCR (Claude Code Router) — for Azure-routed Claude Code use [`claude-litellm`](https://github.com/c0ffee0wl/claude-litellm).
- No `~/.bashrc` / `~/.zshrc` modifications — no `@()` wrapper, no `wut`, no Ctrl+N keybinding, no zsh tab-completion plugin. Skills + statusline at `~/.claude/` don't need shell rc edits.
- No Node.js install. The `pretty-mermaid` and `last30days` skills need Node at runtime; users install Node + run `npm install` in those skill dirs themselves. (Go _is_ installed from apt for `imagemage` — see Phase 6.)
- No `llm-tools-*` plugins. Add individually post-install if needed (`uv tool install --force --with llm-tools-mcp ... llm`).
- No `llm` templates. The previous repo's `llm-wut.yaml` required the removed `context` tool. Users who want templates: `llm templates edit <name>`.

## Verification

```bash
bash -n linux/setup.sh && bash -n linux/common.sh        # syntax
./linux/setup.sh                                         # full first-run (non-interactive by design)
llm --version && llm plugins list                        # llm + plugin set
claude --version                                         # Claude Code
ls ~/.claude/skills/ && diff <(cat ~/.claude/statusline.sh) linux/scripts/statusline.sh
ls ~/.config/io.datasette.llm/extra-openai-models.yaml   # seeded template present
./linux/setup.sh                                         # re-run, expect no errors and no clobbering
```
