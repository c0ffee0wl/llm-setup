# llm-setup

Lean Linux installer for [Simon Willison's `llm` CLI](https://github.com/simonw/llm), [Anthropic's Claude Code](https://claude.com/claude-code), and a curated set of Claude Code skills.

Runs as a regular user on Debian / Kali (no WSL ties, no system-level hardening, no GUI integrations). Self-updates from git on every run.

## Quick Start

```bash
git clone https://github.com/c0ffee0wl/llm-setup ~/llm-setup
cd ~/llm-setup
./linux/setup.sh
```

That installs `llm` with a trimmed plugin set, Claude Code, and copies the skills into `~/.claude/skills/`. First run asks if you want to configure Azure OpenAI and/or Google Gemini.

Open a new shell and try:

```bash
llm "hi"
claude
```

## Setup Modes

| Command | What it does |
|---|---|
| `./linux/setup.sh` | Install missing tools; first-run provider prompts |
| `./linux/setup.sh --upgrade` | Re-install `llm` (refreshes plugins) and run `claude update` |
| `./linux/setup.sh --azure` | (Re)configure Azure OpenAI provider |
| `./linux/setup.sh --gemini` | (Re)configure Google Gemini provider |
| `./linux/setup.sh --yes` / `-y` | Auto-answer yes to prompts |
| `./linux/setup.sh --no` / `-n` | Auto-answer no to prompts |

Idempotent: re-running is safe. By default tools are install-if-missing only — pass `--upgrade` to refresh.

## What's installed

- **`llm` CLI** (from the [c0ffee0wl/llm](https://github.com/c0ffee0wl/llm) fork) with: provider plugins (`llm-gemini`, `llm-vertex`, `llm-anthropic`, `llm-openrouter`), `llm-cmd`, `llm-git-commit`, `llm-jq`, `llm-templates-fabric`, fragment loaders (`llm-fragments-github`, `llm-fragments-pdf`, `llm-fragments-site-text`, `llm-fragments-dir`, `llm-fragments-youtube-transcript`), `llm-sort`, `llm-classify`, and `llm-uv-tool` (plugin persistence across `uv tool upgrade`).
- **Claude Code** via the official `claude.ai/install.sh` installer.
- **Claude Code skills** copied from this repo's `skills/` to `~/.claude/skills/`. External skills listed in `skills/external-skills.yaml` are refreshed on every run.
- **Claude Code statusline** at `~/.claude/statusline.sh` (sourced from `/opt/claude-litellm`'s richer LiteLLM-aware variant; degrades gracefully without LiteLLM).

## What's _not_ installed

By design this repo does not ship: the Terminator/inline-`@`/GTK/espanso/Ulauncher AI assistants, Claude Code Router, Codex CLI, asciinema session recording, speech-to-text, custom shell keybindings, or any `~/.bashrc`/`~/.zshrc` modifications. Those lived in the previous `llm-linux-setup` and were pulled out for this lean variant.

For Azure-routed Claude Code (LiteLLM gateway), see [claude-litellm](https://github.com/c0ffee0wl/claude-litellm).

## Layout

```
llm-setup/
├── README.md                # this file
├── CLAUDE.md                # agent guidance
├── PLAN.md                  # design rationale
├── skills/                  # Claude Code skills (platform-agnostic)
└── linux/
    ├── setup.sh             # entry point (5 phases)
    ├── common.sh            # helper library
    ├── configs/             # Azure model YAML templates
    └── scripts/statusline.sh
```
