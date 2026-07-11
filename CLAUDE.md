# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`llm-setup` is a lean Linux deployment repo for Simon Willison's `llm` CLI, Anthropic's Claude Code, and a curated set of Claude Code skills. It is intentionally narrow — no daemons, no shell integrations, no desktop wrappers, **no interactive provider configuration**. The previous form lived as `llm-linux-setup` and was cut down for this variant.

There is no build system, test suite, or linter — it's a deployment automation repo of Bash scripts plus YAML configs.

## Architecture

Single execution context: Linux. Runs as the current `$USER`. `sudo` is invoked only for `apt-get` and for the bwrap AppArmor profile (`configure_bwrap_apparmor` in Phase 1).

Entry point: `linux/setup.sh`. It sources `linux/common.sh` for utilities and runs six numbered phases (plus Phase 0 self-update).

There is **no `--upgrade` flag**: installed components are upgraded automatically on every run (see "Key Conventions"). Flags (none persisted across reruns):
- `--skip-skills` — skip the Phase 5 skills sync (`update-external-skills.sh` + copying `skills/*/`). The statusline + `settings.json` install still runs.
- `--clear-cache` — standalone op: run `clear_package_caches` (purge npm/go/pip/pipx/cargo/uv caches) and `exit 0`. Dispatched *before* the active-session guard (it replaces no binaries, so it's safe during a live session).
- `--uninstall` — standalone op: run `run_uninstall` and `exit 0`. Footprint-scoped (removes only what this script installs); dispatched *after* the session guard (it removes the `claude` binary). Prompts per group unless `--force`.
- `--dry-run` / `--force` — only valid with `--uninstall` (the script `error`s otherwise, via `if` blocks to stay `set -e`-safe). `--dry-run` previews via `do_or_dry`; `--force` skips the per-group `confirm_uninstall` prompts.

The install/upgrade path is fully non-interactive — it never prompts. **`--uninstall` is the one exception**: it asks `ask_yes_no` per group (default *yes*) unless `--force` is given.

The script refuses to run when `pgrep -u "$USER" -x claude` finds an active Claude Code session — Phase 0 self-update, Phase 4 `claude update`, and `--uninstall` can replace or remove the binary mid-session. `--clear-cache` is exempt (dispatched before the guard).

## Setup Phases (`linux/setup.sh`)

| Phase | What |
|---|---|
| 0 | Self-update: `git fetch` + `git pull --ff-only` + `exec "$0" "$@"` if behind. Skipped when not in a git checkout or when no remote is configured. |
| 1 | apt: `git curl jq ca-certificates bubblewrap` (index refreshed lazily via `apt_update_once` — only when something actually needs installing, so a steady-state re-run skips it); `configure_bwrap_apparmor` (writes `/etc/apparmor.d/bwrap` when unprivileged userns is AppArmor-restricted — for `blaude`); `install_or_upgrade_uv` (which also runs `configure_uv_system_python`). No Node.js — Claude Code is now a native binary, and `llm` is pure Python. |
| 2 | `llm` install/upgrade with the trimmed plugin set. A `sha256` fingerprint of the plugin list + source is stored at `~/.config/io.datasette.llm/llm-install-fingerprint`. If `llm` is missing or the fingerprint changed → full `uv tool install --force --with ...` (preserving user-installed plugins via `detect_user_plugins` + `uv-tool-packages.json`); otherwise → fast `uv tool upgrade llm`. Plugin list lives at the top of Phase 2 in `linux/setup.sh`. |
| 3 | Seed Azure model YAML templates: copy `linux/configs/extra-openai-models.yaml` and `azure-embeddings-models.yaml` to `~/.config/io.datasette.llm/` only if those files do not already exist. User edits `__AZURE_API_BASE__`; user runs `llm keys set` / `llm models default` themselves. |
| 4 | Claude Code: official `https://claude.ai/install.sh` curl pipe on first install; `claude update` on every subsequent run. |
| 5 | Sync top-level `skills/` → `~/.claude/skills/` (calls `skills/update-external-skills.sh` first if present) — skipped under `--skip-skills`; install `linux/scripts/statusline.sh` → `~/.claude/statusline.sh` (always, even with `--skip-skills`); write `~/.claude/settings.json` with a statusLine pointer **only on fresh install** (never overwrite an existing file). |
| 6 | Additional CLI tools: `gitingest` (via `install_or_upgrade_uv_tool`, auto-upgrades); `imagemage` (Go build of `c0ffee0wl/imagemage` → `~/.local/bin/imagemage`, via `install_go` from apt + `install_go_tool_from_source`; skipped with a warning if Go ≥ 1.22 isn't available — **install-if-missing only**); `blaude` (raw script from `c0ffee0wl/blaude` → `~/.local/bin/blaude`, via `install_blaude_repo_script`, re-fetched every run). The repo's `osc52-clipboard` script is deliberately not installed. |

After Phase 6 (before the summary), every normal run calls `clear_package_caches || true` to reclaim disk space — the same routine `--clear-cache` invokes standalone. Ported from `llm-linux-setup`, which ran it "regardless of install mode".

## Key Conventions

- **Idempotency**: every phase is safe to re-run. The seeded YAML templates, `~/.claude/settings.json`, and any user edits are never clobbered.
- **Auto-upgrade on every run**: there is no `--upgrade` flag. `llm` + plugins, Claude Code, and `gitingest` are upgraded automatically when already installed. Two exceptions remain install-if-missing-only: `imagemage` (avoids a Go rebuild every run) and the seeded YAML templates. `blaude` is re-fetched every run (cheap raw-script download).
- **Active-session guard**: pgrep for `claude` at the top of the script — exits cleanly if a session is running.
- **No interactive provider config**: the script deliberately does not prompt for Azure URLs, API keys, or default models. That state belongs to the user and lives in the `llm` config dir (`~/.config/io.datasette.llm/`) + the llm key store. README documents the manual steps.
- **Plugin list**: a single `REMOTE_PLUGINS=( ... )` array in Phase 2 of `linux/setup.sh` is the only source of truth. `llm-uv-tool` (c0ffee0wl fork) must be first so plugins persist across `uv tool upgrade llm`.
- **`llm` is a fork**: installed from `git+https://github.com/c0ffee0wl/llm` (markdown rendering enhancements). To revert to upstream, change `LLM_SOURCE` at the top of Phase 2.
- **Skills location**: `skills/` lives at the top level, not under `linux/`, because skills are platform-agnostic and a future `windows/` variant would consume the same directory.
- **Local vs. external skills**: `skills/` mixes two kinds. *Local* skills are committed to this repo (`image-generation`, `youtube-transcript`). *External* skills are vendored from upstream GitHub repos, listed in `skills/external-skills.yaml`, cloned into `skills/<name>/` by `skills/update-external-skills.sh`, and gitignored via `skills/.gitignore` (`humanizer`, `last30days`, `pretty-mermaid`, `smart-illustrator`). Never edit an external skill in place — the next run clobbers it — and never commit it. To add one, append an entry to `external-skills.yaml` (fields: `repo`, optional `ref`/`path`/`old_name` for renames) and run the update script. Phase 5 runs that script, then copies **all** `skills/*/` to `~/.claude/skills/`.
- **Phase 6 tools are standalone**: `gitingest`, `imagemage`, and `blaude` are independent CLIs — not plugins of `llm`. They use the `install_or_upgrade_uv_tool` / `install_go` + `install_go_tool_from_source` / `install_blaude_repo_script` helpers in `common.sh`. `imagemage` is required by the `image-generation` skill; without it the skill is non-functional. `blaude` needs `bwrap` (apt `bubblewrap`, Phase 1) at runtime or it exits with an error.
- **`configure_bwrap_apparmor` is the only non-apt sudo on the install path**: it writes `/etc/apparmor.d/bwrap` + reloads it, but only when `apparmor_restrict_unprivileged_userns=1` and the profile is absent (idempotent). Ported verbatim from `llm-linux-setup`. (`--uninstall` also sudo-removes that profile.)
- **Cache cleanup runs every run**: `clear_package_caches` (in `common.sh`) purges npm/go/pip/pipx/cargo/uv caches, each guarded by `command -v` so it's safe regardless of which package managers exist — that's why it covers cargo/npm even though this repo installs neither. Invoked at the end of every normal run (`|| true`) and standalone via `--clear-cache`.
- **`--uninstall` is footprint-scoped**: `run_uninstall` (in `setup.sh`, since it's footprint-specific) removes only what this script installs — `llm`+plugins and `gitingest` (`uninstall_uv_tool`), `~/.local/bin/{claude,imagemage,blaude}`, this repo's managed skills under `~/.claude/skills/` + `statusline.sh`, the Phase 2 state files, and the AppArmor `bwrap` profile. It **preserves** user data: keys/default-model/seeded YAML in `~/.config/io.datasette.llm/`, `~/.config/uv/uv.toml`, and a user-modified `~/.claude/settings.json` (removed only if byte-identical to `settings_template`, the shared definition Phase 5 also writes). Generic helpers (`ask_yes_no`, `do_or_dry`, `remove_path`, `confirm_uninstall`, `uninstall_uv_tool`) live in `common.sh`.

## Important Paths

- `~/.local/bin/{llm,claude,gitingest,imagemage,blaude}` — CLI entry points
- `~/.local/share/uv/tools/llm/` — uv-managed virtualenv for `llm` and its plugins
- `~/.config/io.datasette.llm/` — llm config: seeded `extra-openai-models.yaml` and `azure-embeddings-models.yaml`; user-managed `default_model.txt` and `keys.json`; Phase 2 state `llm-install-fingerprint` + `uv-tool-packages.json`
- `/etc/apparmor.d/bwrap` — permissive AppArmor profile for `bwrap` (written by `configure_bwrap_apparmor`, root-owned)
- `~/.config/uv/uv.toml` — `python-preference = "system"` (set by `configure_uv_system_python`)
- `~/.claude/{skills/, statusline.sh, settings.json}` — Claude Code user state (settings.json created only on fresh install)

## What's intentionally absent

- No `--azure` / `--gemini` flags, no `configure_*` provider functions, no `--yes` / `--no` / `--upgrade` flags. Users own provider state and the install path never prompts; upgrades are automatic. (`--uninstall` / `--clear-cache` / `--dry-run` / `--force` *do* exist — for removal and cache cleanup, not provider config.)
- No `osc52-clipboard`: the `c0ffee0wl/blaude` repo also ships an OSC 52 clipboard PTY proxy for VTE terminals — we install `blaude` only, not that script.
- No CCR (Claude Code Router) — for Azure-routed Claude Code use [`claude-litellm`](https://github.com/c0ffee0wl/claude-litellm).
- No `~/.bashrc` / `~/.zshrc` modifications — no `@()` wrapper, no `wut`, no Ctrl+N keybinding, no zsh tab-completion plugin. Skills + statusline at `~/.claude/` don't need shell rc edits.
- No Node.js install. The `pretty-mermaid` and `last30days` skills need Node at runtime; users install Node + run `npm install` in those skill dirs themselves. (Go _is_ installed from apt for `imagemage` — see Phase 6.)
- No `llm-tools-*` plugins. Add individually post-install if needed (`uv tool install --force --with llm-tools-mcp ... llm`).
- No `llm` templates. The previous repo's `llm-wut.yaml` required the removed `context` tool. Users who want templates: `llm templates edit <name>`.

## Editing the scripts

- **`setup.sh` runs under `set -eo pipefail`** (it sources `common.sh`, which has a `_LLM_COMMON_SOURCED` guard). This is the main hazard when porting code from `llm-linux-setup`: a brace group or `cmd1 && cmd2` whose **last** command exits non-zero — e.g. `[ ${#arr[@]} -gt 0 ] && printf ...` when the array is empty — becomes the pipeline's exit status under `pipefail` and aborts the whole script. Use an `if` block as the last statement (or append `|| true`). See the comment in `update_uv_tool_packages_json` (Phase 2). `set -u` is intentionally **not** set, so empty-array expansions like `"${USER_PLUGINS[@]}"` are safe. Network-dependent upgrades that should not be fatal are wrapped in `|| warn ...`.
- **`common.sh` = reusable helpers; `setup.sh` = the phase sequence.** Add install logic as an `install_or_upgrade_*` / `configure_*` helper in `common.sh` (use `curl_secure` for downloads, the `compare_versions` / `version_at_least` pair for version gating, `uv_tool_installed` for uv-tool presence checks, and `apt_update_once` before any apt install), then call it from the relevant phase.
- **No test harness.** Validate with `bash -n` (syntax) plus a real re-run on a Debian/Kali box; every phase must stay idempotent and safe to run twice.

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
./linux/setup.sh --clear-cache                           # standalone cache purge, exits 0
./linux/setup.sh --uninstall --dry-run                   # preview removals, change nothing
./linux/setup.sh --force                                 # must error: --force only valid with --uninstall
./linux/setup.sh --uninstall --force                     # remove footprint; user data in ~/.config/io.datasette.llm preserved
```
