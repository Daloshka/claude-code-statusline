#!/usr/bin/env bash
# Claude Code statusline: часы, модель + effort, бары расхода лимитов 5h/7d.
# Строка 2: <имя каталога> git:<ветка>[*]
#
# Работает на macOS, Linux, WSL и Git Bash/MSYS/Cygwin под Windows: формат дат
# и набор символов подбираются под платформу сами.
#
# Настройки — переменной окружения или правкой значений ниже:
#   BAR_STYLE=auto|subcell|block|ascii   вид бара (auto: псевдографика, если терминал в UTF-8)
#   BAR_WIDTH=10                         ширина бара в символах

BAR_STYLE="${BAR_STYLE:-auto}"
BAR_WIDTH="${BAR_WIDTH:-10}"
WEEKDAYS="${WEEKDAYS:-пн вт ср чт пт сб вс}"
WEEKDAYS_ASCII="${WEEKDAYS_ASCII:-Mon Tue Wed Thu Fri Sat Sun}"

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf 'statusline: jq not found (brew install jq / apt install jq / pacman -S jq)\n'
  exit 0
fi
j() { printf '%s' "$input" | jq -r "$1 // empty"; }

# ── платформа ─────────────────────────────────────────────────────────────────
case "$(uname -s 2>/dev/null)" in
  Darwin*)              OS=macos ;;
  Linux*)               OS=linux ;;   # сюда же WSL
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *)                    OS=other ;;
esac

# Формат времени: GNU date (Linux, WSL, Git Bash) понимает -d @ts, BSD date (macOS) — -r ts.
if date -d "@0" +%Y >/dev/null 2>&1; then
  ts_fmt() { date -d "@$1" "+$2" 2>/dev/null; }
elif date -r 0 +%Y >/dev/null 2>&1; then
  ts_fmt() { date -r "$1" "+$2" 2>/dev/null; }
else
  ts_fmt() { return 0; }               # экзотический date — время сброса просто не покажем
fi

# Псевдографику рисуем, только если терминал точно в UTF-8.
utf8=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) utf8=1 ;;
esac
if [ "$OS" = windows ] && [ "$utf8" -eq 0 ]; then
  chcp.com 2>/dev/null | grep -q 65001 && utf8=1   # Windows Terminal часто без локали, но с CP65001
fi

if [ "$BAR_STYLE" = auto ]; then
  if [ "$utf8" -eq 1 ]; then BAR_STYLE=subcell; else BAR_STYLE=ascii; fi
elif [ "$utf8" -eq 0 ]; then
  BAR_STYLE=ascii                      # явно заданный юникодный стиль в не-UTF-8 терминале превратится в кашу
fi

if [ "$utf8" -eq 1 ]; then
  SEP="│"; DOT="·"; ARROW="→"
else
  SEP="|"; DOT="-"; ARROW="->"
  WEEKDAYS="$WEEKDAYS_ASCII"           # кириллица в не-UTF-8 терминале тоже превратится в кашу
fi

# ── данные ────────────────────────────────────────────────────────────────────
model=$(j '.model.display_name'); [ -z "$model" ] && model="?"
model="${model%% (*}"                  # "Opus 5 (1M context)" → "Opus 5"

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
  effort_part=$(printf ' \033[2m%s\033[0m \033[%sm%s\033[0m' "$DOT" "$ec" "$effort")
fi

cwd=$(j '.workspace.current_dir'); [ -z "$cwd" ] && cwd=$(j '.cwd')
cwd="${cwd//\\//}"                     # C:\path\proj → C:/path/proj (Git Bash)
dir_name=$(basename "${cwd:-?}")

git_part=""
if [ -n "$cwd" ] && git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=""
    [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="*"
    git_part=" git:${branch}${dirty}"
  fi
fi

# ── бар ───────────────────────────────────────────────────────────────────────
bar() { # $1 = занятый процент (0..100)
  local pct=$1 cells=$BAR_WIDTH out="" i
  awk -v p="$pct" 'BEGIN{exit !(p<0)}'   && pct=0
  awk -v p="$pct" 'BEGIN{exit !(p>100)}' && pct=100
  case "$BAR_STYLE" in
    ascii|block)
      local full ch_full ch_empty
      if [ "$BAR_STYLE" = block ]; then ch_full="▓"; ch_empty="░"; else ch_full="#"; ch_empty="."; fi
      full=$(awk -v p="$pct" -v c="$cells" 'BEGIN{printf "%d", int(p*c/100+0.5)}')
      for ((i=0;i<cells;i++)); do
        if [ $i -lt "$full" ]; then out+="$ch_full"; else out+="$ch_empty"; fi
      done
      ;;
    *) # subcell — точность до 1/8 клетки
      local eighths full rem parts=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉")
      eighths=$(awk -v p="$pct" -v c="$cells" 'BEGIN{printf "%d", int(p*c*8/100+0.5)}')
      full=$((eighths/8)); rem=$((eighths%8))
      for ((i=0;i<full && i<cells;i++)); do out+="█"; done
      if [ $full -lt "$cells" ] && [ $rem -gt 0 ]; then out+="${parts[$rem]}"; full=$((full+1)); fi
      for ((i=full;i<cells;i++)); do out+="·"; done
      ;;
  esac
  printf '%s' "$out"
}

color() { # цвет по зоне заполнения
  awk -v p="$1" 'BEGIN{ if(p>=80) print "91"; else if(p>=50) print "93"; else print "92" }'
}

at() { # unix ts → "15:37" (сегодня) или "пт 18:00"
  local ts=$1 d
  [ -z "$ts" ] && return
  if [ "$(ts_fmt "$ts" %Y%j)" = "$(date +%Y%j)" ]; then
    ts_fmt "$ts" %H:%M
  else
    d=$(ts_fmt "$ts" %u)
    [ -z "$d" ] && return
    printf '%s %s' "$(echo "$WEEKDAYS" | cut -d' ' -f"$d")" "$(ts_fmt "$ts" %H:%M)"
  fi
}

limit() { # $1 = ярлык, $2 = занято %, $3 = resets_at
  local label=$1 pct=$2 ts=$3 c t
  [ -z "$pct" ] && return
  c=$(color "$pct"); t=$(at "$ts")
  printf ' %s \033[2m%s\033[0m \033[%sm%s\033[0m %3.0f%%' "$SEP" "$label" "$c" "$(bar "$pct")" "$pct"
  [ -n "$t" ] && printf ' \033[2m%s %s\033[0m' "$ARROW" "$t"
}

printf '\033[97m%s\033[0m \033[2m%s\033[0m \033[1;96m%s\033[0m%s' \
  "$(date +%H:%M)" "$SEP" "$model" "$effort_part"
limit "5h" "$(j '.rate_limits.five_hour.used_percentage')"  "$(j '.rate_limits.five_hour.resets_at')"
limit "7d" "$(j '.rate_limits.seven_day.used_percentage')"  "$(j '.rate_limits.seven_day.resets_at')"
printf '\n'
printf '\033[1;93m%s\033[0m\033[1;92m%s\033[0m\n' "$dir_name" "$git_part"
