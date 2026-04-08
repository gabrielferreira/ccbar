#!/usr/bin/env bash
# ccbar-panel.sh — live dashboard panel for cmux
# Usage: ~/.config/ccbar/ccbar-panel.sh [interval_seconds]
#
# Shows this terminal's session vs total daily usage, refreshing in-place.
# Designed to run in a small cmux split pane (3 lines).

set -euo pipefail

INTERVAL="${1:-10}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="${CLAUDE_PROJECT:-$PWD}"

# Cores ANSI (não tmux)
R='\033[0m'
GREEN='\033[38;5;82m'
YELLOW='\033[38;5;226m'
RED='\033[38;5;196m'
BLUE='\033[38;5;39m'
CYAN='\033[38;5;51m'
GREY='\033[38;5;245m'
ORANGE='\033[38;5;208m'
WHITE='\033[38;5;255m'
DIM='\033[2m'
BOLD='\033[1m'

color_pct() {
  local pct=$1
  if   (( pct >= 80 )); then printf '%b' "$RED"
  elif (( pct >= 50 )); then printf '%b' "$YELLOW"
  else                       printf '%b' "$GREEN"
  fi
}

fmt_tokens() {
  local n=$1
  if   (( n >= 1000000 )); then printf "%.1fM" "$(echo "scale=1; $n/1000000" | bc)"
  elif (( n >= 1000 ));    then printf "%.1fk" "$(echo "scale=1; $n/1000" | bc)"
  else                          printf "%d" "$n"
  fi
}

# Resolve project dir
project_dir() {
  local encoded
  encoded=$(echo "$PROJECT" | sed 's|[/.]|-|g')
  local dir="${CLAUDE_DIR:-$HOME/.claude/projects}/$encoded"
  if [[ -d "$dir" ]]; then echo "$dir"; else echo ""; fi
}

# Get tokens from a .jsonl file: "in out cache_write cache_read"
get_tokens() {
  local file=$1
  python3 - "$file" <<'PYEOF'
import json, sys
f = sys.argv[1]
tin = tout = tcw = tcr = 0
try:
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try: obj = json.loads(line)
            except: continue
            usage = None
            msg = obj.get("message", {})
            if isinstance(msg, dict): usage = msg.get("usage")
            if usage is None: usage = obj.get("usage")
            if not isinstance(usage, dict): continue
            tin  += usage.get("input_tokens", 0)
            tout += usage.get("output_tokens", 0)
            tcw  += usage.get("cache_creation_input_tokens", 0)
            tcr  += usage.get("cache_read_input_tokens", 0)
except: pass
print(tin, tout, tcw, tcr)
PYEOF
}

# Get tokens for all sessions today
get_tokens_today() {
  local base="${1:-$HOME/.claude/projects}"
  python3 - "$base" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone
base = sys.argv[1]
today = datetime.now(timezone.utc).date()
tin = tout = tcw = tcr = 0
for root, dirs, files in os.walk(base):
    dirs[:] = [d for d in dirs if d != "subagents"]
    for fname in files:
        if not fname.endswith(".jsonl"): continue
        fpath = os.path.join(root, fname)
        mtime = datetime.fromtimestamp(os.path.getmtime(fpath), tz=timezone.utc).date()
        if mtime != today: continue
        try:
            with open(fpath) as fh:
                for line in fh:
                    line = line.strip()
                    if not line: continue
                    try: obj = json.loads(line)
                    except: continue
                    usage = None
                    msg = obj.get("message", {})
                    if isinstance(msg, dict): usage = msg.get("usage")
                    if usage is None: usage = obj.get("usage")
                    if not isinstance(usage, dict): continue
                    tin  += usage.get("input_tokens", 0)
                    tout += usage.get("output_tokens", 0)
                    tcw  += usage.get("cache_creation_input_tokens", 0)
                    tcr  += usage.get("cache_read_input_tokens", 0)
        except: pass
print(tin, tout, tcw, tcr)
PYEOF
}

# Session duration in formatted + raw minutes
get_duration() {
  local file=$1
  python3 - "$file" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
f = sys.argv[1]
timestamps = []
try:
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try: obj = json.loads(line)
            except: continue
            ts = obj.get("timestamp")
            if ts:
                try: timestamps.append(datetime.fromisoformat(ts.replace("Z", "+00:00")))
                except: pass
except: pass
if len(timestamps) < 1:
    print("0m 0")
    sys.exit()
start, end = min(timestamps), max(timestamps)
diff = int((end - start).total_seconds())
h, m = diff // 3600, (diff % 3600) // 60
mins = max(1, diff // 60) if diff > 0 else 0
fmt = f"{h}h{m:02d}m" if h > 0 else f"{m}m"
print(fmt, mins)
PYEOF
}

plan_limit() {
  case "${CLAUDE_PLAN:-pro}" in
    pro)       echo 44000 ;;
    max5)      echo 88000 ;;
    max20)     echo 220000 ;;
    team)      echo 55000 ;;
    team-prem) echo 275000 ;;
    api)       echo 0 ;;
    *)         echo 44000 ;;
  esac
}

calc_cost() {
  python3 -c "
tin,tout,tcw,tcr = $1,$2,$3,$4
pi,po,pcw,pcr = $5,$6,$7,$8
cost = (tin*pi + tout*po + tcw*pcw + tcr*pcr) / 1_000_000
print(f'{cost:.2f}')
"
}

tput civis 2>/dev/null  # hide cursor
trap 'tput cnorm 2>/dev/null; exit' INT TERM

while true; do
  # ── Find session file for this project ──
  pdir=$(project_dir)
  if [[ -n "$pdir" ]]; then
    file=$(find "$pdir" -maxdepth 2 -name "*.jsonl" -not -path "*/subagents/*" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
  else
    file=""
  fi

  # ── Plan limit ──
  plimit=$(plan_limit)

  # ── Session data (this terminal) ──
  if [[ -n "$file" ]]; then
    read -r tin tout tcw tcr <<< "$(get_tokens "$file")"
    read -r dur mins <<< "$(get_duration "$file")"
    ctx=$(( tin + tcw + tcr ))
    cost=$(calc_cost "$tin" "$tout" "$tcw" "$tcr" 3.00 15.00 3.75 0.30)

    # ETA
    eta=""
    if (( plimit > 0 && ctx > 0 && mins > 0 && ctx < plimit )); then
      rem=$(( (plimit - ctx) * mins / ctx ))
      if (( rem >= 60 )); then
        eta="~$(( rem / 60 ))h$(printf '%02d' $(( rem % 60 )))m"
      else
        eta="~${rem}m"
      fi
    fi
  else
    tin=0; tout=0; ctx=0; cost="0.00"; dur="0m"; mins=0; eta=""
  fi

  # ── Daily totals (all projects) ──
  read -r dtin dtout dtcw dtcr <<< "$(get_tokens_today)"
  dctx=$(( dtin + dtcw + dtcr ))
  dcost=$(calc_cost "$dtin" "$dtout" "$dtcw" "$dtcr" 3.00 15.00 3.75 0.30)

  # ── Percentages ──
  if (( plimit > 0 )); then
    sess_pct=$(( ctx * 100 / plimit ))
    day_pct=$(( dctx * 100 / plimit ))
  else
    sess_pct=0; day_pct=0
  fi

  # ── Render ──
  tput home 2>/dev/null || printf '\033[H'
  tput el 2>/dev/null || printf '\033[K'

  # Line 1: session
  sc=$(color_pct "$sess_pct")
  printf "${DIM}session${R}  ${BLUE}↑$(fmt_tokens $tin)${R} ${CYAN}↓$(fmt_tokens $tout)${R}  ${GREY}\$${cost}${R}  ${GREY}${dur}${R}"
  if [[ -n "$eta" ]]; then printf "  ${ORANGE}${eta}${R}"; fi
  printf '\033[K\n'

  # Line 2: daily total
  dc=$(color_pct "$day_pct")
  printf "${DIM}today  ${R}  ${BLUE}↑$(fmt_tokens $dtin)${R} ${CYAN}↓$(fmt_tokens $dtout)${R}  ${GREY}\$${dcost}${R}"
  printf '\033[K\n'

  # Line 3: progress bar
  if (( plimit > 0 )); then
    bar_len=30
    s_filled=$(( sess_pct * bar_len / 100 ))
    d_filled=$(( day_pct * bar_len / 100 ))
    if (( s_filled > bar_len )); then s_filled=$bar_len; fi
    if (( d_filled > bar_len )); then d_filled=$bar_len; fi

    printf "${DIM}limit${R}   ${sc}"
    for (( i=0; i<bar_len; i++ )); do
      if (( i < s_filled )); then printf '█'
      elif (( i < d_filled )); then printf '▒'
      else printf '░'; fi
    done
    printf "${R} ${sc}${sess_pct}%%${R}${GREY}/${R}${dc}${day_pct}%%${R} ${DIM}of $(fmt_tokens $plimit)${R}"
  else
    printf "${DIM}plan${R}   ${GREY}api (no limit)${R}"
  fi
  printf '\033[K\n'
  printf '\033[K'

  sleep "$INTERVAL"
done
