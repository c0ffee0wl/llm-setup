# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project Overview

`llm-setup` is a lean Linux deployment repo for Simon Willison's `llm` CLI, Anthropic's Claude Code, and a curated set of Claude Code skills. It is intentionally narrow — no daemons, no shell integrations, no desktop wrappers. The previous form lived as `llm-linux-setup` and was cut down for this variant; see `PLAN.md` for rationale.

There is no build system, test suite, or linter — it's a deployment automation repo of Bash scripts plus YAML configs.

## Architecture

Single execution context: Linux. Runs as the current `$USER`. `sudo` is invoked only for `apt-get`.

Entry point: `linux/setup.sh`. It sources `linux/common.sh` for utilities and runs five numbered phases (plus Phase 0 self-update).

Flags (not persisted across reruns):
- `--upgrade` — refresh `llm` (re-installs with `uv tool install --force --with ...`) and run `claude update`.
- `--azure` — (re)configure Azure OpenAI: sets the key, writes `extra-openai-models.yaml` + `azure-embeddings-models.yaml` to `~/.config/io.datasette.llm/`, persists `AZURE_OPENAI_API_KEY` + `AZURE_RESOURCE_NAME` to `~/.profile`, sets default model on first setup.
- `--gemini` — (re)configure Gemini: sets the key, persists `GEMINI_API_KEY` to `~/.profile`. Mutually exclusive with `--azure`.
- `--yes` / `--no` — non-interactive answers to prompts.

## Setup Phases (`linux/setup.sh`)

| Phase | What |
|---|---|
| 0 | Self-update: `git fetch` + `git pull --ff-only` + `exec "$0" "$@"` if behind. Skipped when not in a git checkout or when no remote is configured. |
| 1 | apt: `git curl jq ca-certificates build-essential poppler-utils`; `install_or_upgrade_uv`; `install_or_upgrade_nodejs` (apt if repo has Node 20+, else nvm Node 22). |
| 2 | `llm` install (or refresh under `--upgrade`) with the trimmed plugin set, single `uv tool install --force --with ...` invocation. Plugin list lives at the top of Phase 2 in `linux/setup.sh`. |
| 3 | Provider config: prompts for Azure / Gemini on first run (when neither key exists); `--azure` / `--gemini` flags force re-prompt. Templates in `linux/configs/` use `__AZURE_API_BASE__` substitution. |
| 4 | Claude Code: official `https://claude.ai/install.sh` curl pipe on first install; `claude update` under `--upgrade`. |
| 5 | Sync top-level `skills/` → `~/.claude/skills/` (calls `skills/update-external-skills.sh` first if present); install `linux/scripts/statusline.sh` → `~/.claude/statusline.sh`; merge `statusLine` into `~/.claude/settings.json` via `jq`. |

## Key Conventions

- **Idempotency**: every phase is safe to re-run.
- **Install-if-missing-only by default**: `llm` and Claude Code are not auto-upgraded. Pass `--upgrade` to refresh.
- **Profile management**: use `update_profile_export` in `common.sh` for env-var changes — handles idempotency and proper shell escaping. Never edit `~/.profile` with raw `sed`/`echo`.
- **Template substitution**: `linux/configs/*.yaml` use `__AZURE_API_BASE__` tokens. `render_azure_config` in `setup.sh` runs `sed` over them before writing to `~/.config/io.datasette.llm/`. New tokens follow the same `__UPPER_CASE__` pattern.
- **Skills location**: `skills/` lives at the top level, not under `linux/`, because skills are platform-agnostic and a future `windows/` variant would consume the same directory.
- **Plugin list**: a single `REMOTE_PLUGINS=( ... )` array in Phase 2 of `linux/setup.sh` is the only source of truth. `llm-uv-tool` (c0ffee0wl fork) must be first so plugins persist across `uv tool upgrade llm`.
- **`llm` is a fork**: installed from `git+https://github.com/c0ffee0wl/llm` (markdown rendering enhancements). To revert to upstream, change `LLM_SOURCE` at the top of Phase 2.

## Important Paths

- `~/.local/bin/{llm,claude}` — CLI entry points
- `~/.local/share/uv/tools/llm/` — uv-managed virtualenv for `llm` and its plugins
- `~/.config/io.datasette.llm/` — llm config (extra-openai-models.yaml, azure-embeddings-models.yaml, default_model.txt, keys.json)
- `~/.config/uv/uv.toml` — `python-preference = "system"` (set by `configure_uv_system_python`)
- `~/.claude/{skills/, statusline.sh, settings.json}` — Claude Code user state
- `~/.profile` — `AZURE_OPENAI_API_KEY`, `AZURE_RESOURCE_NAME`, `GEMINI_API_KEY` (written via `update_profile_export`)

## What's intentionally absent

- No CCR (Claude Code Router) — for Azure-routed Claude Code use [`claude-litellm`](https://github.com/c0ffee0wl/claude-litellm).
- No `~/.bashrc` / `~/.zshrc` modifications — no `@()` wrapper, no `wut`, no Ctrl+N keybinding, no zsh tab-completion plugin. Skills + statusline at `~/.claude/` don't need shell rc edits.
- No `llm-tools-*` plugins. Add individually post-install if needed (`uv tool install --force --with llm-tools-mcp ... llm`).
- No `llm` templates. The previous repo's `llm-wut.yaml` required the removed `context` tool; `llm.yaml` referenced removed tools. Users who want them: `llm templates edit <name>`.

## Verification

```bash
bash -n linux/setup.sh && bash -n linux/common.sh        # syntax
./linux/setup.sh --yes                                   # full first-run, non-interactive
llm --version && llm plugins list                        # llm + plugin set
claude --version                                         # Claude Code
ls ~/.claude/skills/ && diff <(cat ~/.claude/statusline.sh) linux/scripts/statusline.sh
diff <(grep -c '^export AZURE\|^export GEMINI' ~/.profile)
./linux/setup.sh                                         # re-run, expect no errors
```
