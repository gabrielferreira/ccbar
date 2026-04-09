#!/usr/bin/env bash
# ccbar-dashboard.sh — Full dashboard for Claude Code usage
# Usage: ~/.config/ccbar/ccbar-dashboard.sh [interval_seconds]
# Designed to run in a dedicated cmux tab.

set -euo pipefail

INTERVAL="${1:-10}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/projects}"
PROJECT="${CLAUDE_PROJECT:-$PWD}"

# ── ANSI ──
R='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'; ITALIC='\033[3m'
RED='\033[38;5;196m'; GREEN='\033[38;5;82m'; YELLOW='\033[38;5;226m'
BLUE='\033[38;5;39m'; CYAN='\033[38;5;51m'; GREY='\033[38;5;245m'
ORANGE='\033[38;5;208m'; WHITE='\033[38;5;255m'; MAGENTA='\033[38;5;213m'
BG_GREY='\033[48;5;236m'

# ── Helpers ──
color_pct() {
  local pct=$1
  if   (( pct >= 80 )); then printf '%b' "$RED"
  elif (( pct >= 50 )); then printf '%b' "$YELLOW"
  else                       printf '%b' "$GREEN"
  fi
}

fmt_tokens() {
  local n=${1%%.*}  # strip decimal part (tokens can come as floats from JSON)
  if   (( n >= 1000000 )); then printf "%.1fM" "$(echo "scale=1; $n/1000000" | bc)"
  elif (( n >= 1000 ));    then printf "%.1fk" "$(echo "scale=1; $n/1000" | bc)"
  else                          printf "%d" "$n"
  fi
}

bar() {
  local pct=$1 len=${2:-30} char_fill=${3:-█} char_empty=${4:-░}
  local filled=$(( pct * len / 100 ))
  (( filled > len )) && filled=$len
  local b=""
  for (( i=0; i<len; i++ )); do
    if (( i < filled )); then b+="$char_fill"; else b+="$char_empty"; fi
  done
  printf '%s' "$b"
}

hline() {
  local len=${1:-60}
  printf '%b' "$GREY"
  printf '%.0s─' $(seq 1 "$len")
  printf '%b\n' "$R"
}

plan_limit() {
  case "${CLAUDE_PLAN:-pro}" in
    pro)       echo 200000 ;;
    max5)      echo 400000 ;;
    max20)     echo 900000 ;;
    team)      echo 250000 ;;
    team-prem) echo 1300000 ;;
    api)       echo 0 ;;
    *)         echo 44000 ;;
  esac
}

plan_name() {
  case "${CLAUDE_PLAN:-pro}" in
    pro)       echo "Pro" ;;
    max5)      echo "Max (5x)" ;;
    max20)     echo "Max (20x)" ;;
    team)      echo "Team" ;;
    team-prem) echo "Team Premium" ;;
    api)       echo "API" ;;
    *)         echo "Pro" ;;
  esac
}

calc_cost() {
  local tin=$1 tout=$2 tcw=$3 tcr=$4 model=${5:-sonnet}
  python3 -c "
tin,tout,tcw,tcr = $tin,$tout,$tcw,$tcr
prices = {
  'opus':   (15.00, 75.00, 18.75, 1.50),
  'haiku':  (0.80,  4.00,  1.00,  0.08),
  'sonnet': (3.00,  15.00, 3.75,  0.30),
}
m = 'opus' if 'opus' in '$model' else 'haiku' if 'haiku' in '$model' else 'sonnet'
pi,po,pcw,pcr = prices[m]
cost = (tin*pi + tout*po + tcw*pcw + tcr*pcr) / 1_000_000
print(f'{cost:.2f}')
"
}

# ── Resolve project session dir ──
project_encoded=$(echo "$PROJECT" | sed 's|[/.]|-|g')
project_dir="$CLAUDE_DIR/$project_encoded"

tput civis 2>/dev/null
trap 'tput cnorm 2>/dev/null; exit' INT TERM
trap 'kill "$_sleep_pid" 2>/dev/null; _sleep_pid=0' WINCH

_sleep_pid=0

while true; do
  # ── Find session file ──
  file=""
  if [[ -d "$project_dir" ]]; then
    file=$(find "$project_dir" -maxdepth 2 -name "*.jsonl" -not -path "*/subagents/*" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
  fi

  # ── Parse data ──
  if [[ -n "$file" ]]; then
    data=$(python3 "$SCRIPT_DIR/ccbar_parse.py" --session "$file" --daily "$CLAUDE_DIR" --window "$CLAUDE_DIR" 2>/dev/null)
  else
    data=$(python3 "$SCRIPT_DIR/ccbar_parse.py" --daily "$CLAUDE_DIR" --window "$CLAUDE_DIR" 2>/dev/null)
  fi

  # ── Extract fields via Python ──
  eval "$(python3 -c "
import json, sys
d = json.loads('''$data''') if '''$data''' else {}
s = d.get('session', {})
dl = d.get('daily', {})
dt = dl.get('total', {})
projects = dl.get('projects', {})

# Session
print(f's_tin={s.get(\"input_tokens\", 0)}')
print(f's_tout={s.get(\"output_tokens\", 0)}')
print(f's_tcw={s.get(\"cache_write_tokens\", 0)}')
print(f's_tcr={s.get(\"cache_read_tokens\", 0)}')
print(f's_ctx={s.get(\"context_total\", 0)}')
print(f's_turns_u={s.get(\"turns_user\", 0)}')
print(f's_turns_a={s.get(\"turns_assistant\", 0)}')
print(f's_tools={s.get(\"tool_calls_total\", 0)}')
print(f's_errors={s.get(\"tool_errors\", 0)}')
print(f's_model=\"{s.get(\"primary_model\", \"unknown\")}\"')
print(f's_dur=\"{s.get(\"duration_fmt\", \"0m\")}\"')
print(f's_dur_sec={s.get(\"duration_sec\", 0)}')
print(f's_cache_pct={s.get(\"cache_hit_pct\", 0)}')
print(f's_cache_save={s.get(\"cache_savings_usd\", 0)}')

# Tool breakdown (top 6)
tc = s.get('tool_calls', {})
items = sorted(tc.items(), key=lambda x: -x[1])[:6]
for i, (name, count) in enumerate(items):
    print(f'tool_{i}_name=\"{name}\"')
    print(f'tool_{i}_count={count}')
print(f'tool_count={len(items)}')

# Daily total
print(f'd_tin={dt.get(\"input_tokens\", 0)}')
print(f'd_tout={dt.get(\"output_tokens\", 0)}')
print(f'd_tcw={dt.get(\"cache_write_tokens\", 0)}')
print(f'd_tcr={dt.get(\"cache_read_tokens\", 0)}')
print(f'd_sessions={dt.get(\"sessions\", 0)}')
print(f'd_tools={dt.get(\"tool_calls\", 0)}')

# 5h rolling window
w = d.get('window', {})
print(f'w_tin={w.get(\"input_tokens\", 0)}')
print(f'w_tout={w.get(\"output_tokens\", 0)}')
print(f'w_tcw={w.get(\"cache_write_tokens\", 0)}')
print(f'w_tcr={w.get(\"cache_read_tokens\", 0)}')
print(f'w_base_pct={w.get(\"base_pct\", 0)}')
ws = w.get('window_start', '')
we = w.get('window_end', '')
print(f'w_start=\"{ws}\"')
print(f'w_end=\"{we}\"')

# Current project today (from daily per-project breakdown)
import re
proj_encoded = re.sub(r'[/.]', '-', '$PROJECT')
cp = projects.get(proj_encoded, {})
print(f'cp_tin={cp.get(\"input_tokens\", 0)}')
print(f'cp_tout={cp.get(\"output_tokens\", 0)}')
print(f'cp_tcw={cp.get(\"cache_write_tokens\", 0)}')
print(f'cp_tcr={cp.get(\"cache_read_tokens\", 0)}')
print(f'cp_sessions={cp.get(\"sessions\", 0)}')

# Per-project breakdown (top 5)
pitems = sorted(projects.items(), key=lambda x: -(x[1]['output_tokens']+x[1]['input_tokens']))[:5]
for i, (name, info) in enumerate(pitems):
    short = name.split('-')[-1] if len(name) > 20 else name
    # Try to make a readable name from the encoded path
    parts = name.lstrip('-').split('-')
    short = parts[-1] if parts else name
    if len(short) < 3 and len(parts) > 1:
        short = '-'.join(parts[-2:])
    total_t = info['input_tokens'] + info['output_tokens'] + info['cache_write_tokens'] + info['cache_read_tokens']
    print(f'proj_{i}_name=\"{short}\"')
    print(f'proj_{i}_sessions={info[\"sessions\"]}')
    print(f'proj_{i}_tin={info[\"input_tokens\"]}')
    print(f'proj_{i}_tout={info[\"output_tokens\"]}')
    print(f'proj_{i}_tcw={info[\"cache_write_tokens\"]}')
    print(f'proj_{i}_tcr={info[\"cache_read_tokens\"]}')
    print(f'proj_{i}_tools={info[\"tool_calls\"]}')
print(f'proj_count={len(pitems)}')
" 2>/dev/null)"

  plimit=$(plan_limit)
  pname=$(plan_name)

  # ── Costs ──
  s_cost=$(calc_cost "$s_tin" "$s_tout" "$s_tcw" "$s_tcr" "$s_model")
  d_ctx=$(( d_tin + d_tcw + d_tcr ))
  d_cost=$(calc_cost "$d_tin" "$d_tout" "$d_tcw" "$d_tcr" "sonnet")
  w_ctx=$(( w_tin + w_tcw ))
  cp_ctx=$(( cp_tin + cp_tcw + cp_tcr ))

  # Plan usage: exclude cache reads (re-reads inflate count without new compute)
  s_plan=$(( s_tin + s_tcw ))
  d_plan=$(( d_tin + d_tcw ))
  cp_plan=$(( cp_tin + cp_tcw ))

  # ── Percentages ──
  s_pct=0; d_pct=0; w_pct=0; cp_pct=0
  if (( plimit > 0 )); then
    s_pct=$(( s_plan * 100 / plimit ))
    d_pct=$(( d_plan * 100 / plimit ))
    w_pct=$(( w_ctx * 100 / plimit + w_base_pct ))
    cp_pct=$(( cp_plan * 100 / plimit ))
  fi

  # ── ETA ──
  eta=""
  if (( plimit > 0 && s_plan > 0 && s_dur_sec > 60 )); then
    mins=$(( s_dur_sec / 60 ))
    if (( s_plan < plimit )); then
      rem=$(( (plimit - s_plan) * mins / s_plan ))
      if (( rem >= 60 )); then eta="~$(( rem / 60 ))h$(printf '%02d' $(( rem % 60 )))m"
      else eta="~${rem}m"; fi
    else
      eta="exceeded"
    fi
  fi

  # ── Render ──
  clear
  cols=$(tput cols 2>/dev/null || echo 80)
  rows=$(tput lines 2>/dev/null || echo 24)

  # ── Count content lines (dynamic sections) ──
  _lines=0
  _lines=$(( _lines + 2 ))  # header title + hline
  _lines=$(( _lines + 2 ))  # SESSION label + blank
  _lines=$(( _lines + 4 ))  # 3 token rows + blank echo
  _lines=$(( _lines + 2 ))  # turns/tools row + blank
  if (( tool_count > 0 )); then
    _lines=$(( _lines + 1 + tool_count + 1 ))
  fi
  if (( plimit > 0 )); then
    _lines=$(( _lines + 1 + 2 + 4 + 1 ))          # hline + PLAN header+blank + 4 bars + trailing blank
    (( w_pct >= 80 )) && _lines=$(( _lines + 2 )) # warning: \n + text line
  fi
  _lines=$(( _lines + 1 + 2 + 2 + 1 ))            # hline + TODAY header+blank + 2 data rows + blank
  if (( proj_count > 0 )); then
    _lines=$(( _lines + 1 + proj_count + 1 ))
  fi
  _lines=$(( _lines + 2 ))  # footer hline + status line

  # ── Vertical padding ──
  _top=0; _bot=0
  if (( _lines < rows )); then
    _spare=$(( rows - _lines ))
    _top=$(( _spare / 4 ))
    _bot=$(( _spare - _top ))
  fi

  # Top padding
  for (( _p=0; _p<_top; _p++ )); do echo ""; done

  # Header
  printf "${BOLD}${WHITE}  󰚩 ccbar dashboard${R}"
  printf "${GREY}%*s${R}\n" $(( cols - 20 )) "$(date '+%H:%M:%S')"
  hline "$cols"

  # ═══ SESSION ═══
  printf "${BOLD}${BLUE}  SESSION${R}  ${DIM}${s_model}${R}  ${GREY}${s_dur}${R}"
  if [[ -n "$eta" ]]; then printf "  ${ORANGE}${eta} left${R}"; fi
  printf "\n\n"

  # Tokens
  printf "  ${DIM}input${R}    %10s   ${DIM}output${R}  %10s\n" "$(fmt_tokens $s_tin)" "$(fmt_tokens $s_tout)"
  printf "  ${DIM}cache w${R}  %10s   ${DIM}cache r${R}  %10s\n" "$(fmt_tokens $s_tcw)" "$(fmt_tokens $s_tcr)"
  printf "  ${DIM}total${R}    %10s   ${DIM}cost${R}    ${YELLOW}\$${s_cost}${R}\n" "$(fmt_tokens $s_ctx)"
  echo ""

  # Turns & tools
  printf "  ${DIM}turns${R}  ${WHITE}${s_turns_u}${R}${GREY}→${R}${WHITE}${s_turns_a}${R}"
  printf "   ${DIM}tools${R}  ${WHITE}${s_tools}${R}"
  if (( s_errors > 0 )); then printf "  ${RED}${s_errors} errors${R}"; fi
  printf "   ${DIM}cache hit${R}  ${GREEN}${s_cache_pct}%%${R}"
  if (( $(echo "$s_cache_save > 0" | bc -l) )); then
    printf "  ${DIM}saved${R} ${GREEN}\$${s_cache_save}${R}"
  fi
  printf "\n\n"

  # Tool breakdown
  if (( tool_count > 0 )); then
    printf "  ${DIM}tools breakdown${R}\n"
    for (( i=0; i<tool_count; i++ )); do
      eval "tn=\$tool_${i}_name; tc=\$tool_${i}_count"
      # Mini bar proportional to max
      if (( i == 0 )); then max_tc=$tc; fi
      blen=$(( tc * 20 / (max_tc > 0 ? max_tc : 1) ))
      (( blen < 1 )) && blen=1
      printf "  ${CYAN}%-10s${R} %4d " "$tn" "$tc"
      printf "${BLUE}"
      printf '%.0s▪' $(seq 1 "$blen")
      printf "${R}\n"
    done
    echo ""
  fi

  # ═══ PLAN LIMIT ═══
  if (( plimit > 0 )); then
    hline "$cols"
    # Window time range display
    w_range=""
    if [[ -n "$w_start" && -n "$w_end" ]]; then
      ws_h=$(python3 -c "from datetime import datetime; t=datetime.fromisoformat('$w_start'); print(t.strftime('%H:%M'))" 2>/dev/null || echo "?")
      we_h=$(python3 -c "from datetime import datetime; t=datetime.fromisoformat('$w_end'); print(t.strftime('%H:%M'))" 2>/dev/null || echo "?")
      w_range=" (${ws_h}–${we_h} UTC)"
    fi
    base_info=""
    if (( w_base_pct > 0 )); then
      base_info=" +${w_base_pct}%% base"  # double %% for printf escaping
    fi

    printf "${BOLD}${ORANGE}  PLAN${R}  ${DIM}${pname} — $(fmt_tokens $plimit) tokens / 5h window${w_range}${R}\n\n"

    sc=$(color_pct "$s_pct")
    cpc=$(color_pct "$cp_pct")
    wc=$(color_pct "$w_pct")
    dc=$(color_pct "$d_pct")

    printf "  ${DIM}session${R}  ${sc}$(bar $s_pct 35)${R} ${sc}%3d%%${R}  $(fmt_tokens $s_ctx)\n" "$s_pct"
    printf "  ${DIM}project${R}  ${cpc}$(bar $cp_pct 35)${R} ${cpc}%3d%%${R}  $(fmt_tokens $cp_ctx)\n" "$cp_pct"
    printf "  ${DIM}5h wind${R}  ${wc}$(bar $w_pct 35)${R} ${wc}%3d%%${R}  $(fmt_tokens $w_ctx)${GREY}${base_info}${R}\n" "$w_pct"
    printf "  ${DIM}today  ${R}  ${dc}$(bar $d_pct 35)${R} ${dc}%3d%%${R}  $(fmt_tokens $d_ctx)\n" "$d_pct"

    if (( w_pct >= 100 )); then
      printf "\n  ${RED}${BOLD}⚠  LIMIT EXCEEDED${R}${RED} — consider waiting for the next 5h window${R}\n"
    elif (( w_pct >= 80 )); then
      printf "\n  ${YELLOW}⚠  Approaching limit${R}\n"
    fi
    echo ""
  fi

  # ═══ DAILY ═══
  hline "$cols"
  printf "${BOLD}${MAGENTA}  TODAY${R}  ${DIM}${d_sessions} sessions — $(fmt_tokens $d_ctx) total tokens${R}\n\n"

  printf "  ${DIM}input${R}    %10s   ${DIM}output${R}  %10s   ${DIM}cost${R}  ${YELLOW}\$${d_cost}${R}\n" "$(fmt_tokens $d_tin)" "$(fmt_tokens $d_tout)"
  printf "  ${DIM}tools${R}    %10d\n" "$d_tools"
  echo ""

  # Per-project breakdown
  if (( proj_count > 0 )); then
    printf "  ${DIM}%-20s %6s %8s %8s %6s${R}\n" "project" "sess" "input" "output" "tools"
    for (( i=0; i<proj_count; i++ )); do
      eval "pn=\$proj_${i}_name; ps=\$proj_${i}_sessions; ptin=\$proj_${i}_tin; ptout=\$proj_${i}_tout; pt=\$proj_${i}_tools"
      printf "  ${WHITE}%-20s${R} %4d  %8s %8s %6d\n" "$pn" "$ps" "$(fmt_tokens $ptin)" "$(fmt_tokens $ptout)" "$pt"
    done
    echo ""
  fi

  hline "$cols"
  printf "${DIM}  refresh: ${INTERVAL}s │ plan: ${CLAUDE_PLAN:-pro} │ project: $(basename "$PROJECT")${R}\n"

  # Bottom padding — fill remaining terminal height
  for (( _p=0; _p<_bot; _p++ )); do echo ""; done

  # Interruptible sleep: SIGWINCH will kill $_sleep_pid and trigger immediate redraw
  sleep "$INTERVAL" & _sleep_pid=$!
  wait "$_sleep_pid" 2>/dev/null || true
  _sleep_pid=0
done
