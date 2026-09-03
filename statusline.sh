#!/bin/bash
# Claude Code statusline: модель + effort, часы + бары лимитов 5h/7d.
# Строка 2: <basename каталога> git:<ветка>[*]
# BAR_STYLE=subcell — бар с точностью до 1/8 клетки (вариант 2)
# BAR_STYLE=block   — простой ▓/░ (вариант 1)
BAR_STYLE="${BAR_STYLE:-subcell}"
BAR_WIDTH=10

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1 // empty"; }

model=$(j '.model.display_name'); [ -z "$model" ] && model="?"
model="${model%% (*}"   # "Opus 5 (1M context)" → "Opus 5"

effort=$(j '.effort.level')
effort_part=""
if [ -n "$effort" ]; then
  case "$effort" in
    low)    ec=32 ;;   # зелёный
    medium) ec=36 ;;   # голубой
    high)   ec=33 ;;   # жёлтый
    xhigh)  ec=35 ;;   # пурпурный
    max)    ec=91 ;;   # красный
    *)      ec=37 ;;
  esac
  effort_part=$(printf ' \033[2m·\033[0m \033[%sm%s\033[0m' "$ec" "$effort")
fi
cwd=$(j '.workspace.current_dir'); [ -z "$cwd" ] && cwd=$(j '.cwd')
dir_name=$(basename "${cwd:-?}")

git_part=""
if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=""
    [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="*"
    git_part=" git:${branch}${dirty}"
  fi
fi

# ── бар ───────────────────────────────────────────────────────────────────────
bar() { # $1 = used percent (0..100)
  local pct=$1 cells=$BAR_WIDTH out="" i
  awk -v p="$pct" 'BEGIN{exit !(p<0)}' && pct=0
  awk -v p="$pct" 'BEGIN{exit !(p>100)}' && pct=100
  if [ "$BAR_STYLE" = "block" ]; then
    local full
    full=$(awk -v p="$pct" -v c="$cells" 'BEGIN{printf "%d", int(p*c/100+0.5)}')
    for ((i=0;i<cells;i++)); do [ $i -lt "$full" ] && out+="▓" || out+="░"; done
  else
    local eighths full rem parts=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉")
    eighths=$(awk -v p="$pct" -v c="$cells" 'BEGIN{printf "%d", int(p*c*8/100+0.5)}')
    full=$((eighths/8)); rem=$((eighths%8))
    for ((i=0;i<full && i<cells;i++)); do out+="█"; done
    if [ $full -lt "$cells" ] && [ $rem -gt 0 ]; then out+="${parts[$rem]}"; full=$((full+1)); fi
    for ((i=full;i<cells;i++)); do out+="·"; done
  fi
  printf '%s' "$out"
}

color() { # цвет по зоне заполнения
  awk -v p="$1" 'BEGIN{ if(p>=80) print "91"; else if(p>=50) print "93"; else print "92" }'
}

at() { # unix ts → "15:37" (сегодня) или "пт 18:00"
  local ts=$1 d
  [ -z "$ts" ] && return
  if [ "$(date -r "$ts" +%Y%j)" = "$(date +%Y%j)" ]; then
    date -r "$ts" +%H:%M
  else
    d=$(date -r "$ts" +%u)
    printf '%s %s' "$(echo 'пн вт ср чт пт сб вс' | cut -d' ' -f"$d")" "$(date -r "$ts" +%H:%M)"
  fi
}

limit() { # $1 = ярлык, $2 = used%, $3 = resets_at
  local label=$1 pct=$2 ts=$3 c t
  [ -z "$pct" ] && return
  c=$(color "$pct"); t=$(at "$ts")
  printf ' │ \033[2m%s\033[0m \033[%sm%s\033[0m %3.0f%%' "$label" "$c" "$(bar "$pct")" "$pct"
  [ -n "$t" ] && printf ' \033[2m→ %s\033[0m' "$t"
}

printf '\033[97m%s\033[0m \033[2m│\033[0m \033[1;96m%s\033[0m%s' \
  "$(date +%H:%M)" "$model" "$effort_part"
limit "5h" "$(j '.rate_limits.five_hour.used_percentage')"  "$(j '.rate_limits.five_hour.resets_at')"
limit "7d" "$(j '.rate_limits.seven_day.used_percentage')"  "$(j '.rate_limits.seven_day.resets_at')"
printf '\n'
printf '\033[1;93m%s\033[0m\033[1;92m%s\033[0m\n' "$dir_name" "$git_part"
