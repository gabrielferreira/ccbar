# ccbar

Live Claude Code metrics in your terminal. Track token usage, costs, plan limits, tool calls, and cache efficiency — works with any terminal emulator, tmux, and [cmux](https://cmux.dev).

[![CI](https://github.com/gabrielferreira/ccbar/actions/workflows/ci.yml/badge.svg)](https://github.com/gabrielferreira/ccbar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Preview

**Top bar** (persistent header at the top of your terminal):
```
 󰚩 9.4M/1.3M ↑7.6k ↓35.5k $5.77 1h39m │ 183t 109tc ⚡94.1%
 proj $5.77 3sess │ ████░░░░░░░░ s21% p35%
```

**Dashboard** (full tab with detailed breakdown):
```
  󰚩 ccbar dashboard                                    14:32:07
────────────────────────────────────────────────────────────────
  SESSION  claude-opus-4-6  1h39m  ~38m left

  input       7.6k   output    35.5k
  cache w   712.1k   cache r   11.4M
  total       9.4M   cost     $5.77

  turns  19→183   tools  109  4 errors   cache hit  94.1%  saved $30.86

  tools breakdown
  Bash         69 ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪
  Edit         16 ▪▪▪▪▪
  Write        12 ▪▪▪▪
  Read          8 ▪▪
  Agent         1 ▪

────────────────────────────────────────────────────────────────
  PLAN  Pro — 200k tokens

  session  █████████░░░░░░░░░░░░░░░░░░░░░░░░░░  21%  9.4M
  project  ████████████░░░░░░░░░░░░░░░░░░░░░░░  35%  15.2M

────────────────────────────────────────────────────────────────
  TODAY  12 sessions — 24.8M total tokens

  input      16.0k   output   169.2k   cost  $26.83
  tools         523

  project              sess    input   output  tools
  my-web-app              5     8.6k   155.9k    442
  ccbar                   1     7.6k    35.5k    109
  side-project            2      188    25.3k     81
```

## Dependencies

| Dependency | Required | Notes |
|---|---|---|
| **bash** 4+ | Yes | macOS ships bash 3 — use `brew install bash` |
| **python3** | Yes | stdlib only, no pip packages needed |
| **bc** | Yes | pre-installed on most systems |
| [Nerd Fonts](https://www.nerdfonts.com/) | Optional | for the 󰚩 icon; falls back gracefully |

## Installation

### Homebrew (recommended)

```bash
brew tap gabrielferreira/ccbar
brew install ccbar
```

### Manual

```bash
git clone https://github.com/gabrielferreira/ccbar.git ~/.config/ccbar && ln -sf ~/.config/ccbar/ccbar ~/.local/bin/ccbar
```

Add to your `~/.bashrc` or `~/.zshrc`:

```bash
export CLAUDE_PLAN="pro"  # see Plan Limits below for options
```

## How it works

ccbar reads Claude Code's session logs (`~/.claude/projects/**/*.jsonl`) and calculates metrics in real time. The top bar uses ANSI scroll regions to pin a 2-line status header to the top of your terminal — no multiplexer needed.

## Compatibility

| Command | Any terminal (iTerm, etc.) | tmux | cmux |
|---|---|---|---|
| `ccbar bar` | Yes | Yes | Yes |
| `ccbar title` | Yes | Yes | Yes |
| `ccbar dashboard` | Yes (current terminal) | Yes (new window) | Yes (new tab) |
| `ccbar float` | Yes (new window) | Yes (popup) | Yes (new tab) |
| `ccbar reset [%]` | Yes | Yes | Yes |
| `ccbar stop` / `stop-all` | Yes | Yes | Yes |
| `claude_status.sh` | — | Yes (status bar) | — |

## Usage

### Top bar (per-terminal header)

Creates a persistent 2-line header at the top of your terminal using ANSI scroll regions. Your terminal content scrolls normally below it. Works in **any terminal emulator** — no tmux or cmux required. Refreshes every 10 seconds.

```bash
ccbar bar
```

Each terminal tracks its **own project** — if you have 3 terminals on different projects, each bar shows that project's data.

When a TUI app like Claude Code CLI is detected in the foreground, the bar automatically pauses scroll region updates and falls back to updating the terminal title instead — no flickering or lost input. If metric parsing fails temporarily (e.g., during a long session with heavy JSONL files), the bar preserves the last rendered content instead of going blank.

### Title mode

Shows compact metrics in the terminal window/tab title. No cursor manipulation, no scroll regions — fully compatible with Claude Code CLI and any other TUI. Best for use in the same terminal as Claude.

```bash
ccbar title
```

### Float

Opens the dashboard in a floating overlay without leaving your current terminal.

```bash
ccbar float
```

- In **tmux**: opens a `display-popup` (press `q` or `Ctrl-C` to close)
- In **cmux**: opens in a new tab
- **macOS standalone**: opens a new iTerm2 or Terminal.app window

### Dashboard

Opens a comprehensive dashboard with token breakdown, tool usage, cache stats, plan limits, and per-project daily summary.

```bash
ccbar dashboard
```

- In **cmux**: opens in a new tab
- In **tmux**: opens in a new window
- **Standalone**: runs in the current terminal

The dashboard adapts to your terminal size — content is distributed vertically to fill available space. Resizing the window triggers an immediate redraw.

### Stop

```bash
ccbar stop       # stop ccbar for this terminal
ccbar stop-all   # stop all ccbar processes
```

### Per-project filtering

ccbar automatically detects the project from the terminal's working directory (`$PWD`). You can also set it explicitly:

```bash
CLAUDE_PROJECT=/path/to/project ccbar bar
```

## tmux status bar

For tmux users who want metrics in the **status bar** (bottom of screen), use `claude_status.sh` directly. For a top-of-screen header or full dashboard, use `ccbar bar` or `ccbar dashboard` instead — they work inside tmux too.

Add one of the following to your `~/.tmux.conf`:

```tmux
# session (default) — tokens, cost, duration of active session
set -g status-right '#(~/.config/ccbar/claude_status.sh session)'

# daily — accumulated tokens and cost for today
set -g status-right '#(~/.config/ccbar/claude_status.sh daily)'

# context — context window usage with progress bar
set -g status-right '#(~/.config/ccbar/claude_status.sh context)'

# all — everything in one line
set -g status-right '#(~/.config/ccbar/claude_status.sh all)'
```

After editing, reload: `tmux source-file ~/.tmux.conf`

## tmux Status Modes

| Mode | Description | Example output |
|---|---|---|
| `session` | Token I/O, cost, duration, and ETA of the active session | `󰚩 31.0k/44k │ ↑22.1k ↓8.9k │ $0.2940 │ 47m ~38m` |
| `daily` | Total tokens and cost accumulated today (all sessions) | `hoje: ↑128.4k ↓52.3k $1.4210` |
| `context` | Usage progress bar against plan limit | `ctx: ███████░░░ 70%` |
| `all` | Session + daily metrics combined | `󰚩 sess:↑22.1k↓8.9k ctx:70% $0.2940 47m ~38m │ dia:↑128.4k $1.4210` |

The `~38m` ETA estimates remaining time based on the current burn rate (tokens/min). When `CLAUDE_PLAN=api` or burn rate is zero, the ETA is omitted.

## Integration with tmux themes

### Catppuccin

```tmux
# After catppuccin loads:
set -ga status-right '#(~/.config/ccbar/claude_status.sh session)'
```

Or use Catppuccin's custom module:

```tmux
set -g @catppuccin_status_modules_right "... custom"
set -g @catppuccin_custom_plugin_text '#(~/.config/ccbar/claude_status.sh session)'
```

### Powerline

```tmux
set -ga status-right '#[fg=colour235,bg=colour233]#[fg=colour245,bg=colour235] #(~/.config/ccbar/claude_status.sh session) '
```

### TPM (generic)

Use `set -ga` (append) **after** the `run` line:

```tmux
run '~/.tmux/plugins/tpm/tpm'
set -ga status-right ' #(~/.config/ccbar/claude_status.sh session)'
```

## Plan Limits

Set `CLAUDE_PLAN` to show session and project usage as a percentage of your plan's estimated token limit:

```bash
export CLAUDE_PLAN="pro"
```

| Plan | Token limit (estimated) |
|---|---|
| `pro` (default) | 200,000 |
| `max5` | 400,000 |
| `max20` | 900,000 |
| `team` | 250,000 |
| `team-prem` | 1,300,000 |
| `api` | no limit (context window only) |

> **Note:** These limits are **community estimates** based on observed usage — Anthropic does not publish official numbers. If the percentages don't match Claude.ai's usage meter, set your own limit:
> ```bash
> export CLAUDE_PLAN_LIMIT=3870000  # override with your calibrated value
> ```

### Color scheme

Colors reflect usage percentage against the plan limit:

| Usage | Color |
|---|---|
| < 50% | Green |
| 50-79% | Yellow |
| >= 80% | Red |

## Dashboard Metrics

The full dashboard (`ccbar dashboard`) shows:

| Section | Metrics |
|---|---|
| **Session** | Model, duration, ETA, input/output/cache tokens, cost, turns, tool calls, errors |
| **Tools** | Breakdown by tool name (Bash, Edit, Read, Write, etc.) with visual bars |
| **Cache** | Hit rate %, estimated savings in USD |
| **Plan** | Progress bars: session and project usage against plan limit |
| **Today** | Total tokens, cost, tool calls across all sessions and projects |
| **Projects** | Per-project breakdown with sessions, tokens, and tool counts |

## Pricing Table

Costs are calculated using Anthropic API pricing (per 1M tokens):

| Model | Input | Output | Cache Write | Cache Read |
|---|---|---|---|---|
| **Sonnet** | $3.00 | $15.00 | $3.75 | $0.30 |
| **Opus** | $15.00 | $75.00 | $18.75 | $1.50 |
| **Haiku** | $0.80 | $4.00 | $1.00 | $0.08 |

The model is auto-detected from the session's JSONL data. If detection fails, Sonnet pricing is used as default.

## Custom Claude directory

If you use multiple Claude accounts or a non-default config path, use `--path` to point ccbar to the right directory:

```bash
ccbar --path ~/.claude-pessoal bar
ccbar --path ~/.claude-work dashboard
ccbar --path ~/custom/claude reset 20
```

The `--path` option sets the root Claude directory (equivalent to `~/.claude`). ccbar will look for session logs in `<path>/projects/` and store the reset file in `<path>/ccbar_reset`.

You can also set this permanently via environment variable:

```bash
export CLAUDE_HOME=~/.claude-pessoal
ccbar bar  # uses ~/.claude-pessoal/projects/
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_PLAN` | `pro` | Plan tier: `pro`, `max5`, `max20`, `team`, `team-prem`, `api` |
| `CLAUDE_PLAN_LIMIT` | _(from plan)_ | Override token limit (e.g. `export CLAUDE_PLAN_LIMIT=3870000`) |
| `CLAUDE_PROJECT` | `$PWD` | Project path (for per-project filtering) |
| `CLAUDE_HOME` | `~/.claude` | Root Claude directory (use `--path` flag or this env var) |
| `CLAUDE_DIR` | `$CLAUDE_HOME/projects` | Path to Claude Code's project data |
| `FORCE_COLOR` | `0` | Set to `1` to enable tmux colors outside tmux (testing) |

## Files

| File | Purpose |
|---|---|
| `ccbar` | CLI launcher (`ccbar bar`, `ccbar dashboard`, `ccbar stop`) |
| `ccbar-header.sh` | Persistent terminal header using ANSI scroll regions (used by `ccbar bar`) |
| `ccbar-dashboard.sh` | Full dashboard (works in any terminal, tmux, or cmux) |
| `ccbar_parse.py` | Centralized JSONL parser (used by dashboard and header) |
| `claude_status.sh` | tmux status bar script (4 modes: session/daily/context/all) |
| `ccbar-bar.sh` | Compact 2-line bar (legacy) |
| `ccbar-cmux.sh` | Tab name updater for cmux (legacy) |
| `ccbar-panel.sh` | 3-line panel (legacy) |

## Troubleshooting

### No output / "sem sessao"

- Verify Claude Code has been used recently: `ls -lt ~/.claude/projects/**/*.jsonl`
- Check `CLAUDE_DIR` points to the correct directory
- Ensure scripts are executable: `chmod +x ~/.config/ccbar/*`

### Colors not showing

- In tmux: colors auto-disable outside tmux. Test with `FORCE_COLOR=1`
- In cmux: colors use ANSI escapes and should work automatically
- Ensure your terminal supports 256 colors: `tput colors` should return `256`

### Icons showing as boxes/squares

- Install a [Nerd Font](https://www.nerdfonts.com/) and set it as your terminal font

### Stale data / not updating

- tmux: `set -g status-interval 5` for faster refresh
- cmux bar/dashboard: refreshes every 10 seconds by default (pass interval as first arg)

### Wrong project data

- ccbar uses `$PWD` to find the project. Ensure your terminal is in the project directory
- Override with: `CLAUDE_PROJECT=/path/to/project ccbar bar`
- Check project exists: `ls ~/.claude/projects/` (paths are encoded with `-` replacing `/`)

### `printf: X.X: invalid number` errors

Token counts in some JSONL files are stored as floats (`44000.0` instead of `44000`). This was fixed in [v1.1.0](https://github.com/gabrielferreira/ccbar/releases/tag/v1.1.0). Update your installation:

```bash
# Homebrew
brew upgrade ccbar

# Manual
cd ~/.config/ccbar && git pull
```

### python3 / bc not found

- macOS: `brew install python3` or use `/usr/bin/python3`
- bc: pre-installed on macOS. Debian/Ubuntu: `sudo apt install bc`

## License

[MIT](LICENSE)
