# ccbar

Live Claude Code metrics in your terminal. Track token usage, costs, plan limits, tool calls, and cache efficiency — works with any terminal emulator, tmux, and [cmux](https://cmux.dev).

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Preview

**Top bar** (persistent header at the top of your terminal):
```
 󰚩 9.4M/44k ↑7.6k ↓35.5k $5.77 1h39m ~38m │ 183t 109tc ⚡94.1%
 today ↑16.0k ↓169.2k $26.83 12sess │ █████████░░░░░░ 21%/56%
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
  PLAN  Pro — 44k tokens / 5h window

  session  █████████░░░░░░░░░░░░░░░░░░░░░░░░░░  21%  9.4M
  today    ████████████████░░░░░░░░░░░░░░░░░░░░  56%  24.8M

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

```bash
git clone https://github.com/<your-user>/ccbar.git ~/.config/ccbar && ln -sf ~/.config/ccbar/ccbar ~/.local/bin/ccbar
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
| `ccbar dashboard` | Yes (current terminal) | Yes (new window) | Yes (new tab) |
| `ccbar stop` / `stop-all` | Yes | Yes | Yes |
| `claude_status.sh` | — | Yes (status bar) | — |

## Usage

### Top bar (per-terminal header)

Creates a persistent 2-line header at the top of your terminal using ANSI scroll regions. Your terminal content scrolls normally below it. Works in **any terminal emulator** — no tmux or cmux required. Refreshes every 10 seconds.

```bash
ccbar bar
```

Each terminal tracks its **own project** — if you have 3 terminals on different projects, each bar shows that project's data.

### Dashboard

Opens a comprehensive dashboard with token breakdown, tool usage, cache stats, plan limits, and per-project daily summary.

```bash
ccbar dashboard
```

- In **cmux**: opens in a new tab
- In **tmux**: opens in a new window
- **Standalone**: runs in the current terminal

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

Set `CLAUDE_PLAN` to track token usage against your plan's estimated limit per 5-hour window:

```bash
export CLAUDE_PLAN="pro"
```

| Plan | Token limit (5h window) |
|---|---|
| `pro` (default) | 44,000 |
| `max5` | 88,000 |
| `max20` | 220,000 |
| `team` | 55,000 |
| `team-prem` | 275,000 |
| `api` | no limit (context window only) |

> **Note:** These token limits are **community estimates** — Anthropic does not publish official per-window numbers. Actual limits may vary and change without notice.

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
| **Plan** | Progress bars comparing session vs daily usage against plan limit |
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

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_PLAN` | `pro` | Plan tier: `pro`, `max5`, `max20`, `team`, `team-prem`, `api` |
| `CLAUDE_PROJECT` | `$PWD` | Project path (for per-project filtering) |
| `CLAUDE_DIR` | `~/.claude/projects` | Path to Claude Code's project data |
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

### python3 / bc not found

- macOS: `brew install python3` or use `/usr/bin/python3`
- bc: pre-installed on macOS. Debian/Ubuntu: `sudo apt install bc`

## License

[MIT](LICENSE)
