# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`llm-setup` is a lean Linux deployment repo for Simon Willison's `llm` CLI, Anthropic's Claude Code, and a curated set of Claude Code skills. It is intentionally narrow — no daemons, no shell integrations, no desktop wrappers, **no interactive provider configuration**. The previous form lived as `llm-linux-setup` and was cut down for this variant; see `PLAN.md` for rationale.

There is no build system, test suite, or linter — it's a deployment automation repo of Bash scripts plus YAML configs.

## Architecture

Single execution context: Linux. Runs as the current `$USER`. `sudo` is invoked only for `apt-get` and for the bwrap AppArmor profile (`configure_bwrap_apparmor` in Phase 1).

Entry point: `linux/setup.sh`. It sources `linux/common.sh` for utilities and runs six numbered phases (plus Phase 0 self-update).

There is **no `--upgrade` flag**: installed components are upgraded automatically on every run (see "Key Conventions"). The only flag (not persisted across reruns):
- `--skip-skills` — skip the Phase 5 skills sync (`update-external-skills.sh` + copying `skills/*/`). The statusline + `settings.json` install still runs.

The script is fully non-interactive — it never prompts the user.

The script refuses to run when `pgrep -u "$USER" -x claude` finds an active Claude Code session — Phase 0 self-update and Phase 4 `claude update` can replace the binary mid-session.

## Setup Phases (`linux/setup.sh`)

| Phase | What |
|---|---|
| 0 | Self-update: `git fetch` + `git pull --ff-only` + `exec "$0" "$@"` if behind. Skipped when not in a git checkout or when no remote is configured. |
| 1 | apt: `git curl jq ca-certificates bubblewrap`; `configure_bwrap_apparmor` (writes `/etc/apparmor.d/bwrap` when unprivileged userns is AppArmor-restricted — for `blaude`); `install_or_upgrade_uv` (which also runs `configure_uv_system_python`). No Node.js — Claude Code is now a native binary, and `llm` is pure Python. |
| 2 | `llm` install/upgrade with the trimmed plugin set. A `sha256` fingerprint of the plugin list + source is stored at `~/.config/io.datasette.llm/llm-install-fingerprint`. If `llm` is missing or the fingerprint changed → full `uv tool install --force --with ...` (preserving user-installed plugins via `detect_user_plugins` + `uv-tool-packages.json`); otherwise → fast `uv tool upgrade llm`. Plugin list lives at the top of Phase 2 in `linux/setup.sh`. |
| 3 | Seed Azure model YAML templates: copy `linux/configs/extra-openai-models.yaml` and `azure-embeddings-models.yaml` to `~/.config/io.datasette.llm/` only if those files do not already exist. User edits `__AZURE_API_BASE__`; user runs `llm keys set` / `llm models default` themselves. |
| 4 | Claude Code: official `https://claude.ai/install.sh` curl pipe on first install; `claude update` on every subsequent run. |
| 5 | Sync top-level `skills/` → `~/.claude/skills/` (calls `skills/update-external-skills.sh` first if present) — skipped under `--skip-skills`; install `linux/scripts/statusline.sh` → `~/.claude/statusline.sh` (always, even with `--skip-skills`); write `~/.claude/settings.json` with a statusLine pointer **only on fresh install** (never overwrite an existing file). |
| 6 | Additional CLI tools: `gitingest` (via `install_or_upgrade_uv_tool`, auto-upgrades); `imagemage` (Go build of `c0ffee0wl/imagemage` → `~/.local/bin/imagemage`, via `install_go` from apt; skipped with a warning if Go ≥ 1.22 isn't available — **install-if-missing only**); `blaude` (raw script from `c0ffee0wl/blaude` → `~/.local/bin/blaude`, via `install_blaude_repo_script`, re-fetched every run). The repo's `osc52-clipboard` script is deliberately not installed. |

## Key Conventions

- **Idempotency**: every phase is safe to re-run. The seeded YAML templates, `~/.claude/settings.json`, and any user edits are never clobbered.
- **Auto-upgrade on every run**: there is no `--upgrade` flag. `llm` + plugins, Claude Code, and `gitingest` are upgraded automatically when already installed. Two exceptions remain install-if-missing-only: `imagemage` (avoids a Go rebuild every run) and the seeded YAML templates. `blaude` is re-fetched every run (cheap raw-script download).
- **Active-session guard**: pgrep for `claude` at the top of the script — exits cleanly if a session is running.
- **No interactive provider config**: the script deliberately does not prompt for Azure URLs, API keys, or default models. That state belongs to the user and lives in the `llm` config dir (`~/.config/io.datasette.llm/`) + the llm key store. README documents the manual steps.
- **Plugin list**: a single `REMOTE_PLUGINS=( ... )` array in Phase 2 of `linux/setup.sh` is the only source of truth. `llm-uv-tool` (c0ffee0wl fork) must be first so plugins persist across `uv tool upgrade llm`.
- **`llm` is a fork**: installed from `git+https://github.com/c0ffee0wl/llm` (markdown rendering enhancements). To revert to upstream, change `LLM_SOURCE` at the top of Phase 2.
- **Skills location**: `skills/` lives at the top level, not under `linux/`, because skills are platform-agnostic and a future `windows/` variant would consume the same directory.
- **Local vs. external skills**: `skills/` mixes two kinds. *Local* skills are committed to this repo (`image-generation`, `youtube-transcript`). *External* skills are vendored from upstream GitHub repos, listed in `skills/external-skills.yaml`, cloned into `skills/<name>/` by `skills/update-external-skills.sh`, and gitignored via `skills/.gitignore` (`humanizer`, `last30days`, `pretty-mermaid`, `smart-illustrator`). Never edit an external skill in place — the next run clobbers it — and never commit it. To add one, append an entry to `external-skills.yaml` (fields: `repo`, optional `ref`/`path`/`old_name` for renames) and run the update script. Phase 5 runs that script, then copies **all** `skills/*/` to `~/.claude/skills/`.
- **Phase 6 tools are standalone**: `gitingest`, `imagemage`, and `blaude` are independent CLIs — not plugins of `llm`. They use the `install_or_upgrade_uv_tool` / `install_go` / `install_blaude_repo_script` helpers in `common.sh`. `imagemage` is required by the `image-generation` skill; without it the skill is non-functional. `blaude` needs `bwrap` (apt `bubblewrap`, Phase 1) at runtime or it exits with an error.
- **`configure_bwrap_apparmor` is the only non-apt sudo**: it writes `/etc/apparmor.d/bwrap` + reloads it, but only when `apparmor_restrict_unprivileged_userns=1` and the profile is absent (idempotent). Ported verbatim from `llm-linux-setup`.

## Important Paths

- `~/.local/bin/{llm,claude,gitingest,imagemage,blaude}` — CLI entry points
- `~/.local/share/uv/tools/llm/` — uv-managed virtualenv for `llm` and its plugins
- `~/.config/io.datasette.llm/` — llm config: seeded `extra-openai-models.yaml` and `azure-embeddings-models.yaml`; user-managed `default_model.txt` and `keys.json`; Phase 2 state `llm-install-fingerprint` + `uv-tool-packages.json`
- `/etc/apparmor.d/bwrap` — permissive AppArmor profile for `bwrap` (written by `configure_bwrap_apparmor`, root-owned)
- `~/.config/uv/uv.toml` — `python-preference = "system"` (set by `configure_uv_system_python`)
- `~/.claude/{skills/, statusline.sh, settings.json}` — Claude Code user state (settings.json created only on fresh install)

## What's intentionally absent

- No `--azure` / `--gemini` flags, no `configure_*` provider functions, no `--yes` / `--no` / `--upgrade` flags. Users own provider state and the script never prompts; upgrades are automatic.
- No `osc52-clipboard`: the `c0ffee0wl/blaude` repo also ships an OSC 52 clipboard PTY proxy for VTE terminals — we install `blaude` only, not that script.
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
command -v blaude bwrap                                  # blaude + bubblewrap present
ls ~/.local/bin/osc52-clipboard 2>/dev/null && echo BAD  # should be absent (osc bit excluded)
ls ~/.claude/skills/ && diff <(cat ~/.claude/statusline.sh) linux/scripts/statusline.sh
ls ~/.config/io.datasette.llm/{extra-openai-models.yaml,llm-install-fingerprint,uv-tool-packages.json}
./linux/setup.sh                                         # re-run: auto-upgrades, fingerprint unchanged → fast `uv tool upgrade`, no clobbering
```
