#!/usr/bin/env bash
# claude_status.sh — tmux status bar plugin for Claude Code
# Reads ~/.claude/projects/**/*.jsonl and shows live session metrics
#
# Usage: $(~/.config/claude-tmux/claude_status.sh [session|daily|context])
#   session  — tokens + cost da sessão ativa (default)
#   daily    — tokens acumulados hoje
#   context  — tamanho do contexto atual vs limite
#   all      — todas as métricas em uma linha

set -euo pipefail

# ── Preços Anthropic API (por 1M tokens) ──────────────────────────────────────
readonly PRICE_INPUT_SONNET="3.00"
readonly PRICE_OUTPUT_SONNET="15.00"
readonly PRICE_CACHE_WRITE_SONNET="3.75"
readonly PRICE_CACHE_READ_SONNET="0.30"

readonly PRICE_INPUT_OPUS="15.00"
readonly PRICE_OUTPUT_OPUS="75.00"
readonly PRICE_CACHE_WRITE_OPUS="18.75"
readonly PRICE_CACHE_READ_OPUS="1.50"

readonly PRICE_INPUT_HAIKU="0.80"
readonly PRICE_OUTPUT_HAIKU="4.00"
readonly PRICE_CACHE_WRITE_HAIKU="1.00"
readonly PRICE_CACHE_READ_HAIKU="0.08"

# ── Contexto máximo por modelo ────────────────────────────────────────────────
readonly CTX_MAX_SONNET=200000
readonly CTX_MAX_OPUS=200000
readonly CTX_MAX_HAIKU=200000

# ── Limites por plano (tokens estimados por janela de 5h) ────────────────────
# Nota: valores estimados por terceiros — Anthropic não publica limites oficiais
CLAUDE_PLAN="${CLAUDE_PLAN:-pro}"

# ── Cores tmux ────────────────────────────────────────────────────────────────
C_RESET="#[default]"
C_GREEN="#[fg=colour82]"
C_YELLOW="#[fg=colour226]"
C_RED="#[fg=colour196]"
C_BLUE="#[fg=colour39]"
C_GREY="#[fg=colour245]"
C_WHITE="#[fg=colour255]"
C_ORANGE="#[fg=colour208]"
C_CYAN="#[fg=colour51]"

# Desabilita cores se não estiver no tmux
if [[ -z "${TMUX:-}" && "${FORCE_COLOR:-0}" != "1" ]]; then
  C_RESET="" C_GREEN="" C_YELLOW="" C_RED=""
  C_BLUE="" C_GREY="" C_WHITE="" C_ORANGE="" C_CYAN=""
fi

# ── Diretório de projetos ─────────────────────────────────────────────────────
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/projects}"

# ── Filtro por projeto ────────────────────────────────────────────────────────
# CLAUDE_PROJECT: caminho absoluto do projeto (ex: /Users/x/workspace/myapp)
# Quando definido, restringe a busca ao diretório do projeto no CLAUDE_DIR
CLAUDE_PROJECT="${CLAUDE_PROJECT:-}"

project_session_dir() {
  if [[ -n "$CLAUDE_PROJECT" ]]; then
    # Claude Code codifica o path trocando / por -
    local encoded
    encoded=$(echo "$CLAUDE_PROJECT" | sed 's|[/.]|-|g')
    local dir="$CLAUDE_DIR/$encoded"
    if [[ -d "$dir" ]]; then
      echo "$dir"
      return
    fi
  fi
  echo ""
}

# ── Helpers ───────────────────────────────────────────────────────────────────
fmt_tokens() {
  local n=$1
  if   (( n >= 1000000 )); then printf "%.1fM" "$(echo "scale=1; $n/1000000" | bc)"
  elif (( n >= 1000 ));    then printf "%.1fk" "$(echo "scale=1; $n/1000" | bc)"
  else                          printf "%d" "$n"
  fi
}

fmt_cost() {
  # Recebe valor em dólares (float), imprime com símbolo
  local v=$1
  printf '$%.4f' "$v"
}

color_pct() {
  local pct=$1  # inteiro 0-100
  if   (( pct >= 80 )); then echo "$C_RED"
  elif (( pct >= 50 )); then echo "$C_YELLOW"
  else                       echo "$C_GREEN"
  fi
}

# Detecta modelo a partir do nome do arquivo/conteúdo
detect_model() {
  local file=$1
  local model
  model=$(grep -m1 '"model"' "$file" 2>/dev/null | grep -oP '"model"\s*:\s*"\K[^"]+' | head -1)
  echo "${model:-claude-sonnet}"
}

# Preços para um dado modelo
get_prices() {
  local model=$1
  if   [[ "$model" == *"opus"*   ]]; then
    echo "$PRICE_INPUT_OPUS $PRICE_OUTPUT_OPUS $PRICE_CACHE_WRITE_OPUS $PRICE_CACHE_READ_OPUS"
  elif [[ "$model" == *"haiku"*  ]]; then
    echo "$PRICE_INPUT_HAIKU $PRICE_OUTPUT_HAIKU $PRICE_CACHE_WRITE_HAIKU $PRICE_CACHE_READ_HAIKU"
  else
    echo "$PRICE_INPUT_SONNET $PRICE_OUTPUT_SONNET $PRICE_CACHE_WRITE_SONNET $PRICE_CACHE_READ_SONNET"
  fi
}

ctx_max_for_model() {
  local model=$1
  if   [[ "$model" == *"opus"*  ]]; then echo $CTX_MAX_OPUS
  elif [[ "$model" == *"haiku"* ]]; then echo $CTX_MAX_HAIKU
  else                                   echo $CTX_MAX_SONNET
  fi
}

plan_token_limit() {
  case "${CLAUDE_PLAN}" in
    pro)       echo 44000 ;;
    max5)      echo 88000 ;;
    max20)     echo 220000 ;;
    team)      echo 55000 ;;
    team-prem) echo 275000 ;;
    api)       echo 0 ;;
    *)         echo 44000 ;;
  esac
}

# ── Encontra sessão ativa ─────────────────────────────────────────────────────
# "ativa" = arquivo .jsonl modificado nos últimos 30 minutos
find_active_session() {
  find "$CLAUDE_DIR" -maxdepth 2 -name "*.jsonl" \
    -not -path "*/subagents/*" \
    -newer <(date -d "30 minutes ago" +%s 2>/dev/null || date -v-30M +%s 2>/dev/null \
             && touch -t "$(date -d '30 minutes ago' '+%Y%m%d%H%M' 2>/dev/null \
                           || date -v-30M '+%Y%m%d%H%M')" /tmp/_cc_anchor 2>/dev/null \
             && cat /tmp/_cc_anchor) \
    2>/dev/null | sort -t/ -k1 | tail -1
}

find_active_session_simple() {
  # Versão mais simples: arquivo .jsonl mais recente
  # Respeita CLAUDE_PROJECT quando definido
  local search_dir
  search_dir=$(project_session_dir)
  search_dir="${search_dir:-$CLAUDE_DIR}"

  find "$search_dir" -maxdepth 2 -name "*.jsonl" \
    -not -path "*/subagents/*" \
    2>/dev/null \
    | xargs ls -t 2>/dev/null \
    | head -1
}

# ── Parser JSONL ──────────────────────────────────────────────────────────────
# Extrai tokens de um arquivo .jsonl
# Saída: "input output cache_write cache_read"
parse_tokens_from_file() {
  local file=$1
  python3 - "$file" <<'PYEOF'
import json, sys

f = sys.argv[1]
tin = tout = tcw = tcr = 0

try:
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Suporte a dois formatos:
            # 1. message.usage  (formato novo)
            # 2. usage na raiz   (formato alternativo)
            usage = None
            msg = obj.get("message", {})
            if isinstance(msg, dict):
                usage = msg.get("usage")
            if usage is None:
                usage = obj.get("usage")
            if not isinstance(usage, dict):
                continue

            tin  += usage.get("input_tokens", 0)
            tout += usage.get("output_tokens", 0)
            tcw  += usage.get("cache_creation_input_tokens", 0)
            tcr  += usage.get("cache_read_input_tokens", 0)
except Exception:
    pass

print(tin, tout, tcw, tcr)
PYEOF
}

# Tokens de todas as sessões de hoje
parse_tokens_today() {
  local search_dir
  search_dir=$(project_session_dir)
  search_dir="${search_dir:-$CLAUDE_DIR}"

  python3 - "$search_dir" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

base   = sys.argv[1]
today  = datetime.now(timezone.utc).date()
tin = tout = tcw = tcr = 0

for root, dirs, files in os.walk(base):
    # pula subagents
    dirs[:] = [d for d in dirs if d != "subagents"]
    for fname in files:
        if not fname.endswith(".jsonl"):
            continue
        fpath = os.path.join(root, fname)
        mtime = datetime.fromtimestamp(os.path.getmtime(fpath), tz=timezone.utc).date()
        if mtime != today:
            continue
        try:
            with open(fpath) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    usage = None
                    msg = obj.get("message", {})
                    if isinstance(msg, dict):
                        usage = msg.get("usage")
                    if usage is None:
                        usage = obj.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    tin  += usage.get("input_tokens", 0)
                    tout += usage.get("output_tokens", 0)
                    tcw  += usage.get("cache_creation_input_tokens", 0)
                    tcr  += usage.get("cache_read_input_tokens", 0)
        except Exception:
            pass

print(tin, tout, tcw, tcr)
PYEOF
}

# ── Calcula custo ─────────────────────────────────────────────────────────────
calc_cost() {
  local tin=$1 tout=$2 tcw=$3 tcr=$4
  local pi=$5 po=$6 pcw=$7 pcr=$8
  python3 -c "
tin,tout,tcw,tcr = $tin,$tout,$tcw,$tcr
pi,po,pcw,pcr    = $pi,$po,$pcw,$pcr
cost = (tin*pi + tout*po + tcw*pcw + tcr*pcr) / 1_000_000
print(f'{cost:.4f}')
"
}

# ── Tempo de sessão ───────────────────────────────────────────────────────────
session_duration() {
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
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = obj.get("timestamp")
            if ts:
                try:
                    timestamps.append(datetime.fromisoformat(ts.replace("Z", "+00:00")))
                except Exception:
                    pass
except Exception:
    pass

if len(timestamps) < 1:
    print("0m")
    sys.exit()

start = min(timestamps)
end   = max(timestamps)
diff  = int((end - start).total_seconds())
h     = diff // 3600
m     = (diff % 3600) // 60

if h > 0:
    print(f"{h}h{m:02d}m")
else:
    print(f"{m}m")
PYEOF
}

session_minutes() {
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
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = obj.get("timestamp")
            if ts:
                try:
                    timestamps.append(datetime.fromisoformat(ts.replace("Z", "+00:00")))
                except Exception:
                    pass
except Exception:
    pass

if len(timestamps) < 2:
    print(0)
    sys.exit()

start = min(timestamps)
end   = max(timestamps)
print(max(1, int((end - start).total_seconds()) // 60))
PYEOF
}

# ── Modos de exibição ─────────────────────────────────────────────────────────

mode_session() {
  local file
  file=$(find_active_session_simple)

  if [[ -z "$file" ]]; then
    echo "${C_GREY}󰚩 sem sessão${C_RESET}"
    return
  fi

  read -r tin tout tcw tcr <<< "$(parse_tokens_from_file "$file")"
  local model
  model=$(detect_model "$file")
  read -r pi po pcw pcr <<< "$(get_prices "$model")"
  local cost
  cost=$(calc_cost "$tin" "$tout" "$tcw" "$tcr" "$pi" "$po" "$pcw" "$pcr")
  local dur
  dur=$(session_duration "$file")
  local ctx_total=$(( tin + tcw + tcr ))
  local ctx_max
  ctx_max=$(ctx_max_for_model "$model")

  # Plan-aware limit and color
  local plan_limit
  plan_limit=$(plan_token_limit)
  local display_max pct
  if (( plan_limit > 0 )); then
    display_max=$plan_limit
    pct=$(( ctx_total * 100 / plan_limit ))
  else
    display_max=$ctx_max
    pct=$(( ctx_total * 100 / ctx_max ))
  fi
  local cc
  cc=$(color_pct "$pct")

  # Burn rate & ETA (only when plan has a limit)
  local eta_str=""
  if (( plan_limit > 0 && ctx_total > 0 )); then
    local mins
    mins=$(session_minutes "$file")
    if (( mins > 0 && ctx_total < plan_limit )); then
      local remaining=$(( (plan_limit - ctx_total) * mins / ctx_total ))
      if (( remaining >= 60 )); then
        eta_str=" ${C_ORANGE}~$(( remaining / 60 ))h$(printf '%02d' $(( remaining % 60 )))m${C_RESET}"
      else
        eta_str=" ${C_ORANGE}~${remaining}m${C_RESET}"
      fi
    fi
  fi

  echo "${C_GREY}󰚩 ${C_RESET}${cc}$(fmt_tokens $ctx_total)${C_RESET}${C_GREY}/${C_RESET}$(fmt_tokens $display_max) ${C_GREY}│${C_RESET} ${C_BLUE}↑$(fmt_tokens $tin)${C_RESET} ${C_CYAN}↓$(fmt_tokens $tout)${C_RESET} ${C_GREY}│${C_RESET} ${C_YELLOW}$(fmt_cost $cost)${C_RESET} ${C_GREY}│${C_RESET} ${C_GREY}${dur}${C_RESET}${eta_str}"
}

mode_daily() {
  read -r tin tout tcw tcr <<< "$(parse_tokens_today)"
  local cost
  cost=$(calc_cost "$tin" "$tout" "$tcw" "$tcr" \
    "$PRICE_INPUT_SONNET" "$PRICE_OUTPUT_SONNET" \
    "$PRICE_CACHE_WRITE_SONNET" "$PRICE_CACHE_READ_SONNET")

  echo "${C_GREY}hoje:${C_RESET} ${C_BLUE}↑$(fmt_tokens $tin)${C_RESET} ${C_CYAN}↓$(fmt_tokens $tout)${C_RESET} ${C_YELLOW}$(fmt_cost $cost)${C_RESET}"
}

mode_context() {
  local file
  file=$(find_active_session_simple)

  if [[ -z "$file" ]]; then
    echo "${C_GREY}ctx: -${C_RESET}"
    return
  fi

  read -r tin tout tcw tcr <<< "$(parse_tokens_from_file "$file")"
  local model
  model=$(detect_model "$file")
  local ctx_total=$(( tin + tcw + tcr ))

  # Plan-aware limit
  local plan_limit
  plan_limit=$(plan_token_limit)
  local display_max
  if (( plan_limit > 0 )); then
    display_max=$plan_limit
  else
    display_max=$(ctx_max_for_model "$model")
  fi
  local pct=$(( ctx_total * 100 / display_max ))
  local cc
  cc=$(color_pct "$pct")

  # Mini barra ASCII
  local bar_len=10
  local filled=$(( pct * bar_len / 100 ))
  if (( filled > bar_len )); then filled=$bar_len; fi
  local bar=""
  for (( i=0; i<bar_len; i++ )); do
    if (( i < filled )); then bar+="█"; else bar+="░"; fi
  done

  echo "${C_GREY}ctx:${C_RESET} ${cc}${bar} ${pct}%${C_RESET}"
}

mode_all() {
  local file
  file=$(find_active_session_simple)

  if [[ -z "$file" ]]; then
    echo "${C_GREY}󰚩 sem sessão ativa${C_RESET}"
    return
  fi

  read -r tin tout tcw tcr <<< "$(parse_tokens_from_file "$file")"
  local model
  model=$(detect_model "$file")
  read -r pi po pcw pcr <<< "$(get_prices "$model")"
  local cost
  cost=$(calc_cost "$tin" "$tout" "$tcw" "$tcr" "$pi" "$po" "$pcw" "$pcr")
  local dur
  dur=$(session_duration "$file")
  local ctx_total=$(( tin + tcw + tcr ))
  local ctx_max
  ctx_max=$(ctx_max_for_model "$model")

  # Plan-aware limit and color
  local plan_limit
  plan_limit=$(plan_token_limit)
  local display_pct
  if (( plan_limit > 0 )); then
    display_pct=$(( ctx_total * 100 / plan_limit ))
  else
    display_pct=$(( ctx_total * 100 / ctx_max ))
  fi
  local cc
  cc=$(color_pct "$display_pct")

  # Burn rate & ETA
  local eta_str=""
  if (( plan_limit > 0 && ctx_total > 0 )); then
    local mins
    mins=$(session_minutes "$file")
    if (( mins > 0 && ctx_total < plan_limit )); then
      local remaining=$(( (plan_limit - ctx_total) * mins / ctx_total ))
      if (( remaining >= 60 )); then
        eta_str=" ${C_ORANGE}~$(( remaining / 60 ))h$(printf '%02d' $(( remaining % 60 )))m${C_RESET}"
      else
        eta_str=" ${C_ORANGE}~${remaining}m${C_RESET}"
      fi
    fi
  fi

  # Tokens diários
  read -r dtin dtout dtcw dtcr <<< "$(parse_tokens_today)"
  local dcost
  dcost=$(calc_cost "$dtin" "$dtout" "$dtcw" "$dtcr" \
    "$PRICE_INPUT_SONNET" "$PRICE_OUTPUT_SONNET" \
    "$PRICE_CACHE_WRITE_SONNET" "$PRICE_CACHE_READ_SONNET")

  echo "${C_GREY}󰚩${C_RESET} sess:${C_BLUE}↑$(fmt_tokens $tin)${C_RESET}${C_CYAN}↓$(fmt_tokens $tout)${C_RESET} ${cc}ctx:${display_pct}%${C_RESET} ${C_YELLOW}$(fmt_cost $cost)${C_RESET} ${C_GREY}${dur}${C_RESET}${eta_str} ${C_GREY}│${C_RESET} dia:${C_BLUE}↑$(fmt_tokens $dtin)${C_RESET} ${C_YELLOW}$(fmt_cost $dcost)${C_RESET}"
}

# ── Entry point ───────────────────────────────────────────────────────────────
MODE="${1:-session}"

case "$MODE" in
  session) mode_session ;;
  daily)   mode_daily   ;;
  context) mode_context ;;
  all)     mode_all     ;;
  *)       mode_session ;;
esac
