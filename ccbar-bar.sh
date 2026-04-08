#!/usr/bin/env bash
# ccbar-bar.sh — Compact top bar for cmux split (2 lines)
# Usage: ~/.config/ccbar/ccbar-bar.sh [interval_seconds]
# Designed for a small split at the top of the working terminal.

set -euo pipefail

INTERVAL="${1:-10}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/projects}"
PROJECT="${CLAUDE_PROJECT:-$PWD}"

R='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[38;5;196m'; GREEN='\033[38;5;82m'; YELLOW='\033[38;5;226m'
BLUE='\033[38;5;39m'; CYAN='\033[38;5;51m'; GREY='\033[38;5;245m'
ORANGE='\033[38;5;208m'; WHITE='\033[38;5;255m'

color_pct() {
  local pct=$1
  if (( pct >= 80 )); then printf '%b' "$RED"
  elif (( pct >= 50 )); then printf '%b' "$YELLOW"
  else printf '%b' "$GREEN"; fi
}

fmt_t() {
  local n=$1
  if   (( n >= 1000000 )); then printf "%.1fM" "$(echo "scale=1; $n/1000000" | bc)"
  elif (( n >= 1000 ));    then printf "%.1fk" "$(echo "scale=1; $n/1000" | bc)"
  else printf "%d" "$n"; fi
}

plan_limit() {
  case "${CLAUDE_PLAN:-pro}" in
    pro) echo 44000;; max5) echo 88000;; max20) echo 220000;;
    team) echo 55000;; team-prem) echo 275000;; api) echo 0;; *) echo 44000;;
  esac
}

project_encoded=$(echo "$PROJECT" | sed 's|[/.]|-|g')
project_dir="$CLAUDE_DIR/$project_encoded"

tput civis 2>/dev/null
trap 'tput cnorm 2>/dev/null; exit' INT TERM

while true; do
  file=""
  if [[ -d "$project_dir" ]]; then
    file=$(find "$project_dir" -maxdepth 2 -name "*.jsonl" -not -path "*/subagents/*" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
  fi

  if [[ -n "$file" ]]; then
    eval "$(python3 - "$file" "$CLAUDE_DIR" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

f, base = sys.argv[1], sys.argv[2]

# Session
tin=tout=tcw=tcr=turns=tools=errors=0
timestamps=[]
model="unknown"
try:
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try: obj = json.loads(line)
            except: continue
            ts = obj.get("timestamp")
            if ts:
                try: timestamps.append(datetime.fromisoformat(ts.replace("Z","+00:00")))
                except: pass
            msg = obj.get("message",{})
            if not isinstance(msg,dict): continue
            role = msg.get("role","")
            if role == "assistant":
                turns += 1
                m = msg.get("model","")
                if m: model = m
                usage = msg.get("usage") or obj.get("usage")
                if isinstance(usage,dict):
                    tin+=usage.get("input_tokens",0)
                    tout+=usage.get("output_tokens",0)
                    tcw+=usage.get("cache_creation_input_tokens",0)
                    tcr+=usage.get("cache_read_input_tokens",0)
                content = msg.get("content",[])
                if isinstance(content,list):
                    for b in content:
                        if isinstance(b,dict) and b.get("type")=="tool_use": tools+=1
            elif role == "user":
                content = msg.get("content",[])
                if isinstance(content,list):
                    for b in content:
                        if isinstance(b,dict) and b.get("is_error"): errors+=1
except: pass

dur_s = 0
if len(timestamps)>=2:
    dur_s = int((max(timestamps)-min(timestamps)).total_seconds())
h,m = dur_s//3600,(dur_s%3600)//60
dur = f"{h}h{m:02d}m" if h>0 else f"{m}m"
mins = max(1,dur_s//60) if dur_s>0 else 0
ctx = tin+tcw+tcr

# Daily
dtin=dtout=dtcw=dtcr=dsess=0
today = datetime.now(timezone.utc).date()
for root,dirs,files in os.walk(base):
    dirs[:]=[d for d in dirs if d!="subagents"]
    for fn in files:
        if not fn.endswith(".jsonl"): continue
        fp=os.path.join(root,fn)
        mt=datetime.fromtimestamp(os.path.getmtime(fp),tz=timezone.utc).date()
        if mt!=today: continue
        dsess+=1
        try:
            with open(fp) as fh2:
                for line2 in fh2:
                    line2=line2.strip()
                    if not line2: continue
                    try: o2=json.loads(line2)
                    except: continue
                    msg2=o2.get("message",{})
                    if isinstance(msg2,dict): u2=msg2.get("usage")
                    else: u2=None
                    if u2 is None: u2=o2.get("usage")
                    if not isinstance(u2,dict): continue
                    dtin+=u2.get("input_tokens",0)
                    dtout+=u2.get("output_tokens",0)
                    dtcw+=u2.get("cache_creation_input_tokens",0)
                    dtcr+=u2.get("cache_read_input_tokens",0)
        except: pass

dctx=dtin+dtcw+dtcr
cache_pct=round(tcr*100/(tin+tcw+tcr),1) if (tin+tcw+tcr)>0 else 0

# Cost
def cost(i,o,cw,cr,m="sonnet"):
    p={"opus":(15,75,18.75,1.5),"haiku":(0.8,4,1,0.08),"sonnet":(3,15,3.75,0.3)}
    k="opus" if "opus" in m else "haiku" if "haiku" in m else "sonnet"
    pi,po,pw,pr=p[k]
    return (i*pi+o*po+cw*pw+cr*pr)/1e6

sc=cost(tin,tout,tcw,tcr,model)
dc=cost(dtin,dtout,dtcw,dtcr)

print(f's_tin={tin}; s_tout={tout}; s_tcw={tcw}; s_tcr={tcr}')
print(f's_ctx={ctx}; s_dur="{dur}"; s_mins={mins}; s_turns={turns}')
print(f's_tools={tools}; s_errors={errors}; s_model="{model}"')
print(f's_cost="{sc:.2f}"; s_cache_pct="{cache_pct}"')
print(f'd_tin={dtin}; d_tout={dtout}; d_ctx={dctx}; d_sess={dsess}')
print(f'd_cost="{dc:.2f}"')
PYEOF
    )"
  else
    s_tin=0; s_tout=0; s_ctx=0; s_dur="0m"; s_mins=0; s_turns=0
    s_tools=0; s_errors=0; s_model="—"; s_cost="0.00"; s_cache_pct="0"
    d_tin=0; d_tout=0; d_ctx=0; d_sess=0; d_cost="0.00"
  fi

  plimit=$(plan_limit)

  # Percentages
  s_pct=0; d_pct=0
  if (( plimit > 0 )); then
    s_pct=$(( s_ctx * 100 / plimit ))
    d_pct=$(( d_ctx * 100 / plimit ))
  fi

  # ETA
  eta=""
  if (( plimit > 0 && s_ctx > 0 && s_mins > 0 && s_ctx < plimit )); then
    rem=$(( (plimit - s_ctx) * s_mins / s_ctx ))
    if (( rem >= 60 )); then eta="~$(( rem / 60 ))h$(printf '%02d' $(( rem % 60 )))m"
    else eta="~${rem}m"; fi
  elif (( plimit > 0 && s_ctx >= plimit )); then
    eta="exceeded"
  fi

  # ── Render 2 lines ──
  printf '\033[H'  # cursor home

  # Line 1: session
  sc=$(color_pct "$s_pct")
  printf " ${GREY}󰚩${R} ${sc}$(fmt_t $s_ctx)${R}${GREY}/$(fmt_t $plimit)${R}"
  printf " ${BLUE}↑$(fmt_t $s_tin)${R} ${CYAN}↓$(fmt_t $s_tout)${R}"
  printf " ${YELLOW}\$${s_cost}${R}"
  printf " ${GREY}${s_dur}${R}"
  if [[ -n "$eta" ]]; then
    if [[ "$eta" == "exceeded" ]]; then printf " ${RED}⚠ exceeded${R}"
    else printf " ${ORANGE}${eta}${R}"; fi
  fi
  printf " ${GREY}│${R} ${DIM}${s_turns}t ${s_tools}tc${R}"
  if (( s_errors > 0 )); then printf " ${RED}${s_errors}err${R}"; fi
  printf " ${GREEN}⚡${s_cache_pct}%%${R}"
  printf '\033[K\n'

  # Line 2: daily + limit bar
  dc=$(color_pct "$d_pct")
  printf " ${DIM}today${R} ${BLUE}↑$(fmt_t $d_tin)${R} ${CYAN}↓$(fmt_t $d_tout)${R} ${YELLOW}\$${d_cost}${R} ${GREY}${d_sess}sess${R}"

  if (( plimit > 0 )); then
    printf " ${GREY}│${R} "
    bar_len=15
    s_fill=$(( s_pct * bar_len / 100 ))
    d_fill=$(( d_pct * bar_len / 100 ))
    (( s_fill > bar_len )) && s_fill=$bar_len
    (( d_fill > bar_len )) && d_fill=$bar_len
    for (( i=0; i<bar_len; i++ )); do
      if (( i < s_fill )); then printf "${sc}█${R}"
      elif (( i < d_fill )); then printf "${dc}▒${R}"
      else printf "${GREY}░${R}"; fi
    done
    printf " ${sc}${s_pct}%%${R}${GREY}/${R}${dc}${d_pct}%%${R}"
  fi
  printf '\033[K\n'

  sleep "$INTERVAL"
done
