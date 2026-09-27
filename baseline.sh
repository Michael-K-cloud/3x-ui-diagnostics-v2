#!/bin/bash
# Эталон сервера v2.0 (27.09.2026) — ВЕРСИОННЫЕ снапшоты опорного состояния.
#
# Главное отличие от v1: «Создать эталон» больше НЕ перезаписывает старый —
# каждый раз сохраняется НОВЫЙ файл с датой и временем создания, и любые два
# эталона можно сравнить между собой (с выводом различий).
#
# Хранилище: /root/scripts/etalon/
#   etalon-YYYY-MM-DD_HHMMSS.txt   — эталоны (история, ничего не удаляется)
#   etalon.txt                     — копия НОВЕЙШЕГО (для совместимости с report.sh/ботом v3.x)
#
# Состав снимка (по заданию владельца — «весь эталон»):
#   версии панели/Xray · целостность и счётчики БД · схема таблицы inbounds (контроль миграций) ·
#   ВСЕ настройки панели (settings) · ПОЛНЫЙ дамп инбаундов (settings/stream_settings/sniffing, JSON) ·
#   sha256 и РАЗМЕРЫ конфигов nginx (урок инцидента SE: пустые vhost) · файрвол ufw ·
#   слушающие порты · crontab root · fail2ban · статус WAL-сторожа.
#
# Безопасность: файл эталона на сервере содержит секреты как есть (uuid/пароли клиентов,
#   secret панели) — поэтому каталог 700, файлы 600, только root. Для показа наружу
#   (HTML-отчёт, Telegram) есть режим --public: секреты маскируются ***.
# Все обращения к базе — только для чтения (mode=ro&immutable=1), безопасно на живой панели.
#
# Использование:
#   bash baseline.sh save                        — создать НОВЫЙ эталон (старые не трогаются)
#   bash baseline.sh list                        — список всех эталонов (номера для compare)
#   bash baseline.sh show [N|имя] [--public]     — показать эталон (по умолчанию последний)
#   bash baseline.sh compare [A] [B] [--public|--all]
#         без аргументов  — ТЕКУЩЕЕ состояние vs последний эталон
#         один аргумент   — ТЕКУЩЕЕ состояние vs эталон A
#         два аргумента   — эталон A vs эталон B (различия МЕЖДУ эталонами)
#         A/B — номер из list или имя файла; --all = не скрывать волатильные строки (трафик)
#   bash baseline.sh now [--public]              — снимок текущего состояния в stdout (без сохранения)
#   bash baseline.sh latest                      — имя последнего эталона (или пусто)

export TZ='Europe/Moscow'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
DIR="/root/scripts/etalon"
DB=/etc/x-ui/x-ui.db
ENVF=/root/scripts/.env
mkdir -p "$DIR" && chmod 700 "$DIR" 2>/dev/null
RO="file:$DB?mode=ro&immutable=1"
HAS_PY=0; command -v python3 >/dev/null 2>&1 && HAS_PY=1

sql() { sqlite3 "$RO" "$1" 2>&1; }

# --- маскирование секретов (режим --public) -----------------------------------
mask_public() {
  if [ "$HAS_PY" = "1" ]; then
    python3 -c '
import re, sys, hashlib
KEYS = re.compile(r"^(secret|subURI|subPath|subJsonExt|webBasePath|.*[Tt]oken.*|.*[Pp]assword.*|apiKey.*|tgBot.*|chatId|.*privateKey.*|.*secretKey.*)$")
SENS = "uuid|password|id|privateKey|secretKey|token|shortId|shortIds|SecretKey|PrivateKey"
JFLD = re.compile(r"\"(" + SENS + r")\"(\s*:\s*)\"([^\"]*)\"")
JARR = re.compile(r"\"(" + SENS + r")\"(\s*:\s*)\[$")
UUID = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
STR = re.compile(r"\"([^\"]*)\"")
def fp(s):
    s = s.strip()
    if not s:
        return ""
    return "***" + hashlib.sha256(s.encode("utf-8", "ignore")).hexdigest()[:6]
in_arr = False
for line in sys.stdin:
    line = line.rstrip("\n")
    if in_arr:
        if "]" in line:
            in_arr = False
        print(STR.sub(lambda m: "\"" + fp(m.group(1)) + "\"", line))
        continue
    if "=" in line and not line.startswith((" ", "\t", "#")):
        k, _, v = line.partition("=")
        if KEYS.match(k.strip()):
            line = k + "=" + fp(v)
    if JARR.search(line):
        in_arr = True
    line = JFLD.sub(lambda m: "\"" + m.group(1) + "\"" + m.group(2) + "\"" + fp(m.group(3)) + "\"", line)
    line = UUID.sub(lambda m: fp(m.group(0)), line)
    print(line)
' 2>/dev/null || sed_fallback
  else
    sed_fallback
  fi
}
sed_fallback() {
  sed -E \
    -e 's/^((secret|subURI|subPath|subJsonExt|webBasePath|[Tt]oken|[Pp]assword|apiKey|tgBot|chatId)[A-Za-z_]*)=.*/\1=***/' \
    -e 's/("uuid"|"password"|"id"|"privateKey"|"secretKey"|"token"|"shortId"|"shortIds")("[[:space:]]*:[[:space:]]*)("[^"]*"|\[[^]]*\])/\1\2"***"/g'
}

# --- нормализация JSON (стабильный порядок ключей → честный diff) --------------
pretty_json() {
  if [ "$HAS_PY" = "1" ]; then
    python3 -c 'import json,sys
try:
    print(json.dumps(json.load(sys.stdin), indent=1, sort_keys=True, ensure_ascii=False))
except Exception:
    sys.exit(1)' 2>/dev/null && return 0
  fi
  return 1
}

# --- один снимок ---------------------------------------------------------------
snapshot() {
  echo "# Снимок: $(hostname) — $(date -u '+%F %T') UTC / $(date '+%F %T') MSK — baseline v2"

  echo "## Версия панели"
  local pv=""
  [ -f "$ENVF" ] && pv=$(grep -E '^PANEL_VERSION=' "$ENVF" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -z "$pv" ] && pv=$(x-ui status 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+')
  echo "${pv:-нет данных (пропишите PANEL_VERSION= в /root/scripts/.env)}"

  echo "## Версия Xray"
  /usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1 || echo "нет данных"

  echo "## БД: целостность"
  sql "PRAGMA integrity_check;" | head -1

  echo "## БД: счётчики (стабильные)"
  sql "SELECT 'inbounds='||COUNT(*) FROM inbounds UNION ALL SELECT 'clients='||COUNT(*) FROM clients UNION ALL SELECT 'client_inbounds='||COUNT(*) FROM client_inbounds UNION ALL SELECT 'users='||COUNT(*) FROM users UNION ALL SELECT 'nodes='||COUNT(*) FROM nodes UNION ALL SELECT 'limit_ip_gt0='||COUNT(*) FROM clients WHERE limit_ip>0;"

  echo "## БД: счётчики (волатильные — в сравнении скрыты по умолчанию)"
  sql "SELECT 'client_traffics='||COUNT(*) FROM client_traffics;" | sed 's/^/#!volatile /'
  sql "SELECT 'inbound_client_ips='||COUNT(*) FROM inbound_client_ips;" | sed 's/^/#!volatile /'

  echo "## БД: схема (контроль миграций панели)"
  echo "user_version=$(sql 'PRAGMA user_version;' | head -1)"
  echo "tables: $(sql "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | tr '\n' ' ')"
  echo "inbounds columns: $(sql "PRAGMA table_info(inbounds);" | awk -F'|' '{printf "%s ", $2}')"

  echo "## Настройки панели (таблица settings полностью; в --public секреты замаскированы)"
  sql "SELECT key||'='||value FROM settings ORDER BY key;"

  echo "## Инбаунды (полный дамп)"
  local id col val
  for id in $(sql "SELECT id FROM inbounds ORDER BY id;"); do
    sql "SELECT '### #'||id||' | '||COALESCE(NULLIF(remark,''),'(без имени)')||' | '||protocol||' | порт '||port||' | enable='||enable||' | listen='||COALESCE(NULLIF(listen,''),'*')||' | tag='||COALESCE(NULLIF(tag,''),'-')||' | node_id='||node_id||' | expiry='||expiry_time||' | traffic_reset='||COALESCE(traffic_reset,0) FROM inbounds WHERE id=$id;"
    sql "SELECT '#!volatile трафик #'||id||': up='||up||' down='||down||' total='||total FROM inbounds WHERE id=$id;"
    for col in settings stream_settings sniffing; do
      val=$(sqlite3 "$RO" "SELECT COALESCE($col,'') FROM inbounds WHERE id=$id;" 2>/dev/null)
      [ -z "$val" ] && continue
      echo "--- $col:"
      printf '%s' "$val" | pretty_json || printf '%s\n' "$val"
    done
  done

  echo "## sha256 конфигов nginx"
  find /etc/nginx -type f \( -name '*.conf' -o -path '*sites-available/*' -o -path '*sites-enabled/*' -o -path '*stream-enabled/*' -o -path '*snippets/*' \) 2>/dev/null | sort | xargs -r sha256sum 2>/dev/null

  echo "## Размеры vhost-файлов nginx (урок SE-26.09: пустой vhost = мёртвые инбаунды)"
  wc -c /etc/nginx/sites-available/* /etc/nginx/stream-enabled/* 2>/dev/null | sort -k2

  echo "## Файрвол ufw"
  ufw status numbered 2>/dev/null || echo "ufw недоступен/не установлен"

  echo "## Слушающие порты (x-ui/nginx/xray, без PID)"
  ss -tulnp 2>/dev/null | grep -E 'nginx|x-ui|xray' | awk '{print $1, $2, $5}' | sort -u

  echo "## crontab root"
  crontab -l 2>/dev/null || echo "(пусто)"

  echo "## fail2ban jail"
  fail2ban-client status 2>/dev/null | grep 'Jail list' || echo "fail2ban не запущен"

  echo "## WAL-сторож"
  crontab -l 2>/dev/null | grep wal-watch || echo "сторож не в cron"
}

# снимок с учётом режима: public → маска, иначе как есть
snapshot_mode() {
  if [ "$PUBLIC" = "1" ]; then snapshot | mask_public; else snapshot; fi
}

# --- хранилище: миграция старого etalon.txt и список файлов ---------------------
migrate_legacy() {
  # старый одиночный эталон (v1) → первый версионный файл (по mtime), чтобы история не потерялась
  if [ -f "$DIR/etalon.txt" ] && ! ls "$DIR"/etalon-*.txt >/dev/null 2>&1; then
    local old_stamp
    old_stamp=$(date -r "$DIR/etalon.txt" '+%F_%H%M%S' 2>/dev/null || date '+%F_%H%M%S')
    { echo "# (импортирован из etalon.txt v1 — $(date '+%F %T') MSK)"; cat "$DIR/etalon.txt"; } > "$DIR/etalon-$old_stamp.txt"
    chmod 600 "$DIR/etalon-$old_stamp.txt" 2>/dev/null
    echo -e "${YELLOW}ℹ️ Старый эталон v1 импортирован в историю как etalon-$old_stamp.txt${NC}"
  fi
}

files_sorted() { ls -1 "$DIR"/etalon-*.txt 2>/dev/null | sort; }

resolve() {  # номер из list или имя файла → полный путь
  local a="$1" n
  case "$a" in
    ''|*[!0-9]*) # не число → имя файла
      [ -f "$DIR/$a" ] && { echo "$DIR/$a"; return 0; }
      [ -f "$a" ] && { echo "$a"; return 0; }
      return 1;;
    *)
      n=$(files_sorted | sed -n "${a}p")
      [ -n "$n" ] && { echo "$n"; return 0; }
      return 1;;
  esac
}

latest_file() { files_sorted | tail -1; }

strip_volatile() { grep -v '^#!volatile' | grep -v '^# Снимок:' | grep -v '^# (импортирован'; }

do_diff() {  # $1=файлA(или - = живой снимок) $2=файлB(или -) $3=лейблA $4=лейблB
  local A="$1" B="$2" LA="$3" LB="$4" tA tB hidden=0
  tA=$(mktemp /tmp/etalonA-XXXXXX.txt); tB=$(mktemp /tmp/etalonB-XXXXXX.txt)
  # ОБЕ стороны приводятся к одному виду: живой снимок или файл; в --public маскируются ОБА,
  # иначе сохранённые секреты утекли бы в отчёт и diff был бы ложным (секрет vs ***)
  if [ "$A" = "-" ]; then snapshot > "$tA.raw"; else cat "$A" > "$tA.raw"; fi
  if [ "$B" = "-" ]; then snapshot > "$tB.raw"; else cat "$B" > "$tB.raw"; fi
  if [ "$PUBLIC" = "1" ]; then
    mask_public < "$tA.raw" > "$tA.raw.m"; mv "$tA.raw.m" "$tA.raw"
    mask_public < "$tB.raw" > "$tB.raw.m"; mv "$tB.raw.m" "$tB.raw"
  fi
  if [ "$ALLMODE" = "1" ]; then
    grep -v '^# Снимок:' "$tA.raw" | grep -v '^# (импортирован' > "$tA"
    grep -v '^# Снимок:' "$tB.raw" | grep -v '^# (импортирован' > "$tB"
  else
    hidden=$(grep -c '^#!volatile' "$tA.raw" 2>/dev/null); hidden=${hidden:-0}
    strip_volatile < "$tA.raw" > "$tA"
    strip_volatile < "$tB.raw" > "$tB"
  fi
  if diff -q "$tA" "$tB" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Отличий нет${NC} ($LA ↔ $LB)"
    [ "$ALLMODE" != "1" ] && [ "$hidden" -gt 0 ] && echo -e "${YELLOW}ℹ️ Волатильные строки (трафик/IP-статистика) скрыты; полный diff: compare ... --all${NC}"
    rm -f "$tA" "$tB" "$tA.raw" "$tB.raw"; return 0
  fi
  echo -e "${YELLOW}⚠️ Найдены отличия ($LA ↔ $LB): '-' — $LA, '+' — $LB${NC}"
  diff -u --label "$LA" --label "$LB" "$tA" "$tB"
  local rc=$?
  [ "$ALLMODE" != "1" ] && [ "$hidden" -gt 0 ] && echo -e "${YELLOW}ℹ️ Волатильные строки (трафик/IP-статистика) скрыты; полный diff: compare ... --all${NC}"
  rm -f "$tA" "$tB" "$tA.raw" "$tB.raw"
  return $rc
}

# --- разбор флагов ---------------------------------------------------------------
PUBLIC=0; ALLMODE=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --public) PUBLIC=1;;
    --all)    ALLMODE=1;;
    *)        ARGS+=("$a");;
  esac
done
CMD="${ARGS[0]:-help}"; A1="${ARGS[1]:-}"; A2="${ARGS[2]:-}"

case "$CMD" in
  save)
    migrate_legacy
    STAMP=$(date '+%F_%H%M%S')
    F="$DIR/etalon-$STAMP.txt"
    tries=0
    while [ -f "$F" ] && [ "$tries" -lt 5 ]; do   # два save в одну секунду — ждём, имя остаётся хронологическим
      sleep 1; STAMP=$(date '+%F_%H%M%S'); F="$DIR/etalon-$STAMP.txt"; tries=$((tries+1))
    done
    snapshot > "$F"
    chmod 600 "$F" 2>/dev/null
    cp -f "$F" "$DIR/etalon.txt" && chmod 600 "$DIR/etalon.txt" 2>/dev/null   # совместимость с report.sh/ботом
    N=$(files_sorted | wc -l)
    IB=$(grep -m1 '^inbounds=' "$F" 2>/dev/null)
    echo -e "${GREEN}✅ Новый эталон создан: $(basename "$F")${NC} ($IB, всего эталонов: $N)"
    echo "   Старые эталоны не изменялись. Список: baseline.sh list"
    ;;
  list)
    migrate_legacy
    if ! ls "$DIR"/etalon-*.txt >/dev/null 2>&1; then
      echo -e "${YELLOW}Эталонов ещё нет — создайте: baseline.sh save (или пункт меню «Эталон»)${NC}"; exit 0
    fi
    echo "Эталоны сервера $(hostname) — всего: $(files_sorted | wc -l):"
    i=0
    files_sorted | while read -r f; do
      i=$((i+1))
      hdr=$(grep -m1 '^# Снимок:' "$f" | sed 's/^# Снимок: //')
      cnt=$(grep -m1 '^inbounds=' "$f" | tr -d '\n'); cl=$(grep -m1 '^clients=' "$f")
      sz=$(du -h "$f" | cut -f1)
      mark=""; [ "$f" = "$(latest_file)" ] && mark=" ← последний"
      printf "%2d) %s | %s | %s %s | %s%s\n" "$i" "$(basename "$f")" "${hdr:-?}" "$cnt" "$cl" "$sz" "$mark"
    done
    ;;
  show)
    migrate_legacy
    if [ -n "$A1" ]; then
      F=$(resolve "$A1") || { echo -e "${RED}❌ Эталон '$A1' не найден (см. list)${NC}"; exit 1; }
    else
      F=$(latest_file)
      [ -z "$F" ] && { echo -e "${YELLOW}Эталонов ещё нет — создайте: baseline.sh save${NC}"; exit 0; }
    fi
    echo "=== $(basename "$F") ==="
    if [ "$PUBLIC" = "1" ]; then mask_public < "$F"; else cat "$F"; fi
    ;;
  compare)
    migrate_legacy
    if [ -n "$A1" ] && [ -n "$A2" ]; then          # два эталона между собой
      FA=$(resolve "$A1") || { echo -e "${RED}❌ '$A1' не найден${NC}"; exit 1; }
      FB=$(resolve "$A2") || { echo -e "${RED}❌ '$A2' не найден${NC}"; exit 1; }
      do_diff "$FA" "$FB" "$(basename "$FA")" "$(basename "$FB")"
    elif [ -n "$A1" ]; then                         # текущее vs выбранный эталон
      FA=$(resolve "$A1") || { echo -e "${RED}❌ '$A1' не найден${NC}"; exit 1; }
      do_diff "$FA" "-" "$(basename "$FA")" "текущее состояние"
    else                                            # текущее vs последний
      F=$(latest_file)
      [ -z "$F" ] && { echo -e "${RED}❌ Эталонов нет — сначала сохраните (save)${NC}"; exit 1; }
      do_diff "$F" "-" "$(basename "$F")" "текущее состояние"
    fi
    ;;
  now)
    snapshot_mode
    ;;
  latest)
    latest_file | xargs -r basename
    ;;
  *)
    echo "Использование: baseline.sh {save|list|show [N|имя]|compare [A [B]]|now|latest} [--public] [--all]"
    echo "  save     — создать новый эталон (старые НЕ перезаписываются)"
    echo "  list     — список эталонов (номера для compare)"
    echo "  show     — показать эталон (по умолчанию последний); --public — с маской секретов"
    echo "  compare  — без арг.: текущее vs последний; 1 арг.: текущее vs N; 2 арг.: эталон N vs эталон M"
    echo "  now      — снимок текущего состояния (без сохранения)"
    echo "  --public — маскировать секреты (для HTML/Telegram); --all — показывать волатильные строки"
    ;;
esac
