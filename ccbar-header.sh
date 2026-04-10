#!/usr/bin/env bash
# ccbar-header.sh — persistent header at the top of the current terminal
# Uses ANSI scroll region to reserve lines 1-2 for status display.
# The rest of the terminal scrolls normally below.
#
# Usage: source this or run in background:
#   eval "$(~/.config/ccbar/ccbar-header.sh setup)"   — init scroll region
#   ~/.config/ccbar/ccbar-header.sh update             — refresh status (called by bg loop)
#   ~/.config/ccbar/ccbar-header.sh start [interval]   — start background updater
#   ~/.config/ccbar/ccbar-header.sh stop               — stop and restore terminal

set -euo pipefail

# Resolve real script dir (follows symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/projects}"
PROJECT="${CLAUDE_PROJECT:-$PWD}"
HEADER_LINES=2

fmt_t() {
  local n=${1%%.*}  # strip decimal part (tokens can come as floats from JSON)
  if   (( n >= 1000000 )); then printf "%.1fM" "$(echo "scale=1; $n/1000000" | bc)"
  elif (( n >= 1000 ));    then printf "%.1fk" "$(echo "scale=1; $n/1000" | bc)"
  else printf "%d" "$n"; fi
}

plan_limit() {
  [[ -n "${CLAUDE_PLAN_LIMIT:-}" ]] && echo "$CLAUDE_PLAN_LIMIT" && return
  case "${CLAUDE_PLAN:-pro}" in
    pro) echo 200000;; max5) echo 400000;; max20) echo 900000;;
    team) echo 250000;; team-prem) echo 1300000;; api) echo 0;; *) echo 200000;;
  esac
}

get_status_lines() {
  local project_encoded project_dir file
  project_encoded=$(echo "$PROJECT" | sed 's|[/.]|-|g')
  project_dir="$CLAUDE_DIR/$project_encoded"

  file=""
  if [[ -d "$project_dir" ]]; then
    file=$(find "$project_dir" -maxdepth 2 -name "*.jsonl" -not -path "*/subagents/*" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
  fi

  if [[ -z "$file" ]]; then
    echo "󰚩 sem sessão"
    echo ""
    return
  fi

  eval "$(python3 - "$file" "$project_dir" "$CLAUDE_DIR" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

session_file, proj_dir, base = sys.argv[1], sys.argv[2], sys.argv[3]

def sum_tokens(filepath):
    ti=to=cw=cr=tu=tl=er=0
    ts_list=[]; mdl="?"
    try:
        with open(filepath) as fh:
            for line in fh:
                line=line.strip()
                if not line: continue
                try: obj=json.loads(line)
                except: continue
                ts=obj.get("timestamp")
                if ts:
                    try: ts_list.append(datetime.fromisoformat(ts.replace("Z","+00:00")))
                    except: pass
                msg=obj.get("message",{})
                if not isinstance(msg,dict): continue
                if msg.get("role")=="assistant":
                    tu+=1
                    m=msg.get("model","")
                    if m: mdl=m
                    usage=msg.get("usage") or obj.get("usage")
                    if isinstance(usage,dict):
                        ti+=usage.get("input_tokens",0);to+=usage.get("output_tokens",0)
                        cw+=usage.get("cache_creation_input_tokens",0);cr+=usage.get("cache_read_input_tokens",0)
                    content=msg.get("content",[])
                    if isinstance(content,list):
                        for b in content:
                            if isinstance(b,dict) and b.get("type")=="tool_use": tl+=1
                elif msg.get("role")=="user":
                    content=msg.get("content",[])
                    if isinstance(content,list):
                        for b in content:
                            if isinstance(b,dict) and b.get("is_error"): er+=1
    except: pass
    return ti,to,cw,cr,tu,tl,er,ts_list,mdl

def daily_sum(directory):
    today=datetime.now(timezone.utc).date()
    ti=to=cw=cr=sess=0
    for root,dirs,files in os.walk(directory):
        dirs[:]=[d for d in dirs if d!="subagents"]
        for fn in files:
            if not fn.endswith(".jsonl"): continue
            fp=os.path.join(root,fn)
            mt=datetime.fromtimestamp(os.path.getmtime(fp),tz=timezone.utc).date()
            if mt!=today: continue
            sess+=1
            try:
                with open(fp) as fh:
                    for l in fh:
                        l=l.strip()
                        if not l: continue
                        try: o=json.loads(l)
                        except: continue
                        msg=o.get("message",{})
                        u=msg.get("usage") if isinstance(msg,dict) else None
                        if u is None: u=o.get("usage")
                        if not isinstance(u,dict): continue
                        ti+=u.get("input_tokens",0);to+=u.get("output_tokens",0)
                        cw+=u.get("cache_creation_input_tokens",0);cr+=u.get("cache_read_input_tokens",0)
            except: pass
    return ti,to,cw,cr,sess

# 1. This session
tin,tout,tcw,tcr,turns,tools,errors,timestamps,model=sum_tokens(session_file)
dur_s=0
if len(timestamps)>=2: dur_s=int((max(timestamps)-min(timestamps)).total_seconds())
h,m=dur_s//3600,(dur_s%3600)//60
dur=f"{h}h{m:02d}m" if h>0 else f"{m}m"
mins=max(1,dur_s//60) if dur_s>0 else 0
ctx=tin+tcw+tcr
splan=tin+tcw  # plan usage: no cache reads
cache_pct=round(tcr*100/ctx,1) if ctx>0 else 0
prices={"opus":(15,75,18.75,1.5),"haiku":(0.8,4,1,0.08)}
k="opus" if "opus" in model else "haiku" if "haiku" in model else "sonnet"
pi,po,pw,pr=prices.get(k,(3,15,3.75,0.3))
scost=(tin*pi+tout*po+tcw*pw+tcr*pr)/1e6

# 2. This project today
ptin,ptout,ptcw,ptcr,psess=daily_sum(proj_dir)
pctx=ptin+ptcw+ptcr
pplan=ptin+ptcw  # plan usage: no cache reads
pcost=(ptin*3+ptout*15+ptcw*3.75+ptcr*0.3)/1e6

print(f'ctx={ctx};splan={splan};tin={tin};tout={tout};dur="{dur}";mins={mins}')
print(f'turns={turns};tools={tools};errors={errors};cost="{scost:.2f}";cache_pct="{cache_pct}"')
print(f'ptin={ptin};ptout={ptout};pctx={pctx};pplan={pplan};psess={psess};pcost="{pcost:.2f}"')
PYEOF
  )" 2>/dev/null

  local plimit pct
  plimit=$(plan_limit)
  pct=0
  (( plimit > 0 && splan > 0 )) && pct=$(( splan * 100 / plimit ))

  # Percentages
  local p_pct=0
  (( plimit > 0 && pplan > 0 )) && p_pct=$(( pplan * 100 / plimit ))

  # Color codes
  local R='\033[0m' DIM='\033[2m'
  local RED='\033[38;5;196m' GREEN='\033[38;5;82m' YELLOW='\033[38;5;226m'
  local BLUE='\033[38;5;39m' CYAN='\033[38;5;51m' GREY='\033[38;5;245m'
  local ORANGE='\033[38;5;208m' WHITE='\033[38;5;255m' BG='\033[48;5;236m'

  local sc
  if   (( pct >= 80 )); then sc=$RED
  elif (( pct >= 50 )); then sc=$YELLOW
  else sc=$GREEN; fi

  # Line 1: this session
  printf "${BG} ${GREY}󰚩${R}${BG} ${sc}$(fmt_t $ctx)${R}${BG}${GREY}/$(fmt_t $plimit)${R}${BG} ${BLUE}↑$(fmt_t $tin)${R}${BG} ${CYAN}↓$(fmt_t $tout)${R}${BG} ${YELLOW}\$${cost}${R}${BG} ${GREY}${dur}${R}${BG} ${GREY}│${R}${BG} ${DIM}${turns}t ${tools}tc${R}${BG} ${GREEN}⚡${cache_pct}%%${R}${BG}"
  if (( errors > 0 )); then printf " ${RED}${errors}err${R}${BG}"; fi

  echo ""

  # Line 2: project today | limit bar
  local pc
  if   (( p_pct >= 80 )); then pc=$RED; elif (( p_pct >= 50 )); then pc=$YELLOW; else pc=$GREEN; fi

  printf "${BG} ${DIM}proj${R}${BG} ${YELLOW}\$${pcost}${R}${BG} ${GREY}${psess}sess${R}${BG}"

  if (( plimit > 0 )); then
    printf " ${GREY}│${R}${BG} "
    local bar_len=12 s_fill p_fill
    s_fill=$(( pct * bar_len / 100 ))
    p_fill=$(( p_pct * bar_len / 100 ))
    (( s_fill > bar_len )) && s_fill=$bar_len
    (( p_fill > bar_len )) && p_fill=$bar_len
    for (( i=0; i<bar_len; i++ )); do
      if (( i < s_fill )); then printf "${sc}█${R}${BG}"
      elif (( i < p_fill )); then printf "${pc}▓${R}${BG}"
      else printf "${GREY}░${R}${BG}"; fi
    done
    printf " ${sc}s${pct}%%${R}${BG} ${pc}p${p_pct}%%${R}${BG}"
  fi
}

case "${1:-help}" in
  setup)
    # Output commands to eval in the calling shell
    cat <<'SETUPEOF'
# ccbar: reserve top 2 lines via scroll region
_ccbar_setup_scroll() {
  local lines=${LINES:-$(tput lines)}
  printf '\e[3;%dr' "$lines"
  printf '\e[3;1H'
}
_ccbar_setup_scroll

# Re-setup on terminal resize
trap '_ccbar_setup_scroll' WINCH
SETUPEOF
    ;;

  update)
    # Skip update if a TUI app (like Claude CLI) is the foreground process.
    # Writing scroll regions while a TUI is active causes flickering,
    # lost input, and broken rendering.
    lines=${LINES:-$(tput lines 2>/dev/null || echo 24)}

    if [[ -n "${CCBAR_TTY:-}" ]]; then
      tty_short="${CCBAR_TTY#/dev/}"
      fg_cmd=$(ps -o stat=,comm= -t "$tty_short" 2>/dev/null \
        | awk 'index($1,"+")>0 {print $2}' | head -1)
      case "${fg_cmd:-}" in
        bash|zsh|fish|sh|dash|ksh|tcsh|"")
          # Shell is foreground — safe to render bar
          ;;
        *)
          # Non-shell foreground (TUI app) — skip ALL cursor/scroll writes
          buf=$(get_status_lines 2>/dev/null)
          clean=$(printf '%s' "$buf" | sed 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ' | sed 's/  */ /g')
          printf '\e]0;ccbar │ %s\a' "$clean" > "${CCBAR_TTY}"
          exit 0
          ;;
      esac
    fi

    # Buffer output FIRST (Python is slow), then write atomically
    # to minimize cursor displacement time and avoid eating user input
    buf=$(get_status_lines 2>/dev/null)
    if [[ -n "$buf" ]]; then
      # Single atomic write: save cursor, re-apply scroll region, draw, restore
      printf '\e7\e[3;%dr\e[1;1H\e[K%s\e[K\e8' "$lines" "$buf"
    else
      # Python failed silently — preserve existing header, just re-apply scroll region
      printf '\e[3;%dr' "$lines"
    fi
    ;;

  title)
    # Output compact plain-text metrics for terminal title (no ANSI colors)
    get_status_lines 2>/dev/null | \
      sed 's/\x1b\[[0-9;]*m//g' | \
      tr '\n' ' ' | \
      sed 's/  */ /g; s/^ //; s/ $//'
    ;;

  start)
    interval=${2:-60}
    # Setup scroll region
    eval "$("$0" setup)"
    # Initial draw
    "$0" update
    # Background loop
    while true; do
      sleep "$interval"
      "$0" update
    done &
    CCBAR_HEADER_PID=$!
    echo "$CCBAR_HEADER_PID"
    ;;

  stop)
    # Kill background updater
    if [[ -n "${CCBAR_HEADER_PID:-}" ]]; then
      kill "$CCBAR_HEADER_PID" 2>/dev/null
    fi
    pkill -f "ccbar-header.sh" 2>/dev/null || true
    # Restore full scroll region
    printf '\e[;r'
    printf '\e[1;1H\e[2K\e[2;1H\e[2K'
    ;;

  help|*)
    echo "Usage: ccbar-header.sh <setup|update|start [interval]|stop>"
    ;;
esac
