#!/usr/bin/env bash
# Claude Code statusline: часы, модель + effort, занятый контекст,
# бары расхода лимитов 5h/7d и недельных лимитов отдельных моделей (Fable).
# Строка 2: <имя каталога> git:<ветка>[*]
#
# Работает на macOS, Linux, WSL и Git Bash/MSYS/Cygwin под Windows: формат дат
# и набор символов подбираются под платформу сами.
#
# Настройки — переменной окружения или в файле ~/.claude/statusline.env
# (он переживает самообновление, правки в самом скрипте — нет):
#   BAR_STYLE=auto|subcell|block|ascii   вид бара (auto: псевдографика, если терминал в UTF-8)
#   BAR_WIDTH=10                         ширина бара в символах
#   MODEL_LIMITS=1|0                     показывать недельные лимиты отдельных моделей (Fable и т.п.)
#   MODEL_LIMITS_TTL=300                 как часто (сек) переспрашивать usage API (чаще нельзя: 429)
#   SELF_UPDATE=1|0                      раз в сутки подтягивать свежую версию скрипта с GitHub
#   SELF_UPDATE_TTL=86400                как часто (сек) проверять обновление

[ -r "$HOME/.claude/statusline.env" ] && . "$HOME/.claude/statusline.env"

BAR_STYLE="${BAR_STYLE:-auto}"
BAR_WIDTH="${BAR_WIDTH:-10}"
MODEL_LIMITS="${MODEL_LIMITS:-1}"
MODEL_LIMITS_TTL="${MODEL_LIMITS_TTL:-300}"
USAGE_CACHE="${USAGE_CACHE:-$HOME/.claude/cache/statusline-usage.json}"
SELF_UPDATE="${SELF_UPDATE:-1}"
SELF_UPDATE_TTL="${SELF_UPDATE_TTL:-86400}"
SELF_UPDATE_URL="${SELF_UPDATE_URL:-https://raw.githubusercontent.com/Daloshka/claude-code-statusline/main/statusline.sh}"
SELF_UPDATE_STAMP="${SELF_UPDATE_STAMP:-$HOME/.claude/cache/statusline-update.stamp}"
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
model_full="$model"
model="${model%% (*}"                  # "Opus 5 (1M context)" → "Opus 5"

# Контекст: сколько занято из окна. Размер окна на старых версиях без
# .context_window берём из суффикса имени модели.
ctx_size=$(j '.context_window.context_window_size')
if [ -z "$ctx_size" ]; then
  case "$model_full" in *"(1M context)"*) ctx_size=1000000 ;; esac
fi
ctx_used=$(j '.context_window.total_input_tokens')
ctx_pct=$(j '.context_window.used_percentage')

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

human() { # 60754 → "61k", 1000000 → "1M"
  awk -v n="$1" 'BEGIN{
    if (n >= 1000000)   { v = n / 1000000; printf (v == int(v) ? "%dM" : "%.1fM"), v }
    else if (n >= 1000) { printf "%dk", int(n / 1000 + 0.5) }
    else if (n > 0)     { printf "%d", n }
  }'
}

ctx() { # занято контекста: "ctx 61k/1M"
  local c
  [ -z "$ctx_pct" ] && return
  c=$(color "$ctx_pct")
  printf ' %s \033[2mctx\033[0m \033[%sm%s\033[0m' "$SEP" "$c" "$(human "$ctx_used")"
  [ -n "$ctx_size" ] && printf '\033[2m/%s\033[0m' "$(human "$ctx_size")"
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

# ── лимиты отдельных моделей (Fable и т.п.) ───────────────────────────────────
# Claude Code передаёт в statusline только 5h/7d, поэтому модельные недельные
# окна берём из usage API сами: OAuth-токен из Keychain (macOS) или
# ~/.claude/.credentials.json, ответ кешируем и обновляем в фоне.
oauth_token() {
  local raw
  if [ "$OS" = macos ]; then
    raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  fi
  [ -z "$raw" ] && [ -r "$HOME/.claude/.credentials.json" ] && raw=$(cat "$HOME/.claude/.credentials.json")
  [ -n "$raw" ] && printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // empty'
}

refresh_usage() { # в фоне: скачать usage в кеш, атомарно; на 429 запомнить, когда можно снова
  local tok tmp hdr code retry
  tok=$(oauth_token); [ -z "$tok" ] && return
  tmp="$USAGE_CACHE.$$"; hdr="$tmp.hdr"
  code=$(curl -s -m 8 -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
       "https://api.anthropic.com/api/oauth/usage" -o "$tmp" -D "$hdr" -w '%{http_code}' 2>/dev/null)
  if [ "$code" = 200 ] && jq -e '.limits' "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$USAGE_CACHE"; rm -f "$USAGE_CACHE.backoff"
  else
    retry=$(tr -d '\r' < "$hdr" 2>/dev/null | awk 'tolower($1)=="retry-after:"{print $2}')
    case "$retry" in ''|*[!0-9]*) retry=$MODEL_LIMITS_TTL ;; esac
    echo $(( $(date +%s) + retry )) > "$USAGE_CACHE.backoff"
    rm -f "$tmp"
  fi
  rm -f "$hdr"
}

in_backoff() { # 0, если API просил подождать и срок ещё не вышел
  local until
  until=$(cat "$USAGE_CACHE.backoff" 2>/dev/null)
  [ -n "$until" ] && [ "$(date +%s)" -lt "$until" ]
}

usage_age() { # возраст кеша в секундах (или 999999)
  local m
  jq -e '.limits' "$USAGE_CACHE" >/dev/null 2>&1 || { echo 999999; return; }   # нет или битый — считаем протухшим
  if [ "$OS" = macos ]; then m=$(stat -f %m "$USAGE_CACHE" 2>/dev/null); else m=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null); fi
  echo $(( $(date +%s) - ${m:-0} ))
}

model_limits() {
  [ "$MODEL_LIMITS" = 1 ] || return
  [ -n "$(j '.rate_limits.seven_day.used_percentage')" ] || return   # нет подписочных лимитов — нечего показывать
  command -v curl >/dev/null 2>&1 || return
  mkdir -p "$(dirname "$USAGE_CACHE")" 2>/dev/null
  if [ "$(usage_age)" -ge "$MODEL_LIMITS_TTL" ] && [ ! -f "$USAGE_CACHE.lock" ] && ! in_backoff; then
    ( touch "$USAGE_CACHE.lock"; refresh_usage; rm -f "$USAGE_CACHE.lock" ) >/dev/null 2>&1 &
    disown 2>/dev/null
  fi
  [ -f "$USAGE_CACHE" ] || return
  # строки weekly_scoped: "<имя модели>\t<процент>\t<reset epoch>"
  jq -r '(.limits // [])[] | select(.kind=="weekly_scoped" and .scope.model.display_name != null and .percent != null)
         | [ .scope.model.display_name, (.percent|tostring),
             ((.resets_at // "") | sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | (try fromdateiso8601 catch "") | tostring) ]
         | @tsv' "$USAGE_CACHE" 2>/dev/null |
  while IFS=$'\t' read -r name pct ts; do
    limit "$name" "$pct" "$ts"
  done
}

# ── самообновление ────────────────────────────────────────────────────────────
# Раз в SELF_UPDATE_TTL секунд в фоне скачиваем скрипт с GitHub и, если он
# отличается и проходит bash -n, подменяем себя атомарно (mv — новый inode,
# уже запущенный экземпляр это не трогает). Старая версия остаётся в .bak.
self_update() {
  local me tmp
  me="${BASH_SOURCE[0]}"
  [ "$SELF_UPDATE" = 1 ] && [ -w "$me" ] && command -v curl >/dev/null 2>&1 || return
  case "$me" in */*) ;; *) return ;; esac       # запущены не по пути — не знаем, что обновлять
  mkdir -p "$(dirname "$SELF_UPDATE_STAMP")" 2>/dev/null
  if [ -f "$SELF_UPDATE_STAMP" ]; then
    local m
    if [ "$OS" = macos ]; then m=$(stat -f %m "$SELF_UPDATE_STAMP" 2>/dev/null); else m=$(stat -c %Y "$SELF_UPDATE_STAMP" 2>/dev/null); fi
    [ $(( $(date +%s) - ${m:-0} )) -lt "$SELF_UPDATE_TTL" ] && return
  fi
  touch "$SELF_UPDATE_STAMP"
  (
    tmp="$me.new.$$"
    if curl -sfL -m 15 "$SELF_UPDATE_URL" -o "$tmp" 2>/dev/null \
       && head -c 2 "$tmp" | grep -q '^#!' && bash -n "$tmp" 2>/dev/null \
       && ! cmp -s "$tmp" "$me"; then
      cp -f "$me" "$me.bak" 2>/dev/null
      chmod +x "$tmp" && mv -f "$tmp" "$me"
    fi
    rm -f "$tmp"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null
}
self_update

printf '\033[97m%s\033[0m \033[2m%s\033[0m \033[1;96m%s\033[0m%s' \
  "$(date +%H:%M)" "$SEP" "$model" "$effort_part"
ctx
limit "5h" "$(j '.rate_limits.five_hour.used_percentage')"  "$(j '.rate_limits.five_hour.resets_at')"
limit "7d" "$(j '.rate_limits.seven_day.used_percentage')"  "$(j '.rate_limits.seven_day.resets_at')"
model_limits
printf '\n'
printf '\033[1;93m%s\033[0m\033[1;92m%s\033[0m\n' "$dir_name" "$git_part"
