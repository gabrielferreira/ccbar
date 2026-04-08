#!/usr/bin/env bash
# ccbar-cmux.sh — background updater for cmux tab names
# Runs in background, updates the current tab name with session metrics.
# Each terminal gets its own status, filtered by project (PWD).
#
# Usage: ~/.config/ccbar/ccbar-cmux.sh [interval_seconds]
# Stop:  pkill -f "ccbar-cmux.sh.*$CMUX_SURFACE_ID"

set -euo pipefail

INTERVAL="${1:-10}"
# Resolve symlinks for SCRIPT_DIR
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

SURFACE="${CMUX_SURFACE_ID:-}"
PROJECT="${CLAUDE_PROJECT:-$PWD}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/projects}"

if [[ -z "$SURFACE" ]]; then
  echo "ccbar: not inside cmux (CMUX_SURFACE_ID not set)" >&2
  exit 1
fi

project_encoded=$(echo "$PROJECT" | sed 's|[/.]|-|g')
project_dir="$CLAUDE_DIR/$project_encoded"

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

while true; do
  file=""
  if [[ -d "$project_dir" ]]; then
    file=$(find "$project_dir" -maxdepth 2 -name "*.jsonl" -not -path "*/subagents/*" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
  fi

  if [[ -n "$file" ]]; then
    eval "$(python3 - "$file" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
f = sys.argv[1]
tin=tout=tcw=tcr=turns=tools=0
timestamps=[]; model="?"
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
            if msg.get("role") == "assistant":
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
except: pass
dur_s = 0
if len(timestamps)>=2:
    dur_s = int((max(timestamps)-min(timestamps)).total_seconds())
h,m = dur_s//3600,(dur_s%3600)//60
dur = f"{h}h{m:02d}m" if h>0 else f"{m}m"
mins = max(1,dur_s//60) if dur_s>0 else 0
ctx = tin+tcw+tcr
cache_pct = round(tcr*100/ctx,1) if ctx>0 else 0
# cost
prices={"opus":(15,75,18.75,1.5),"haiku":(0.8,4,1,0.08)}
k="opus" if "opus" in model else "haiku" if "haiku" in model else "sonnet"
pi,po,pw,pr=prices.get(k,(3,15,3.75,0.3))
cost=(tin*pi+tout*po+tcw*pw+tcr*pr)/1e6
print(f'ctx={ctx}; tin={tin}; tout={tout}; dur="{dur}"; mins={mins}')
print(f'turns={turns}; tools={tools}; cost="{cost:.2f}"; cache_pct="{cache_pct}"')
PYEOF
    )" 2>/dev/null

    plimit=$(plan_limit)
    pct=0; eta=""
    if (( plimit > 0 && ctx > 0 )); then
      pct=$(( ctx * 100 / plimit ))
      if (( mins > 0 && ctx < plimit )); then
        rem=$(( (plimit - ctx) * mins / ctx ))
        if (( rem >= 60 )); then eta=" ~$(( rem / 60 ))h$(printf '%02d' $(( rem % 60 )))m"
        else eta=" ~${rem}m"; fi
      elif (( ctx >= plimit )); then
        eta=" ⚠"
      fi
    fi

    label="󰚩 $(fmt_t $ctx)/$(fmt_t $plimit) ↑$(fmt_t $tin) ↓$(fmt_t $tout) \$${cost} ${dur}${eta} │ ${turns}t ${tools}tc ⚡${cache_pct}%"
  else
    label="󰚩 sem sessão"
  fi

  cmux rename-tab --surface "$SURFACE" "$label" 2>/dev/null || true
  sleep "$INTERVAL"
done
