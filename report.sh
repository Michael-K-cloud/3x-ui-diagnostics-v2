#!/bin/bash
# Единый генератор отчётов (версия 3.3, 27.09.2026).
# v3.3: отчёты эталона через baseline.sh v2.0 (--public: секреты в HTML/Telegram
#       маскируются; сравнение — unified diff).
# ПРИНЦИП: ОДИН текст для терминала и HTML (идентичность гарантирована).
# v3.2: подпись «clients on-line» без слов «(уникальных внешних IP)» — по заданию
# владельца 26.09 (смысл прежний: уникальные внешние IP с established-соединением
# к портам xray; подробности — в комментарии у online_clients()).
#
# Использование:
#   bash report.sh {status|wal|etalon|fail2ban|logs} [часы]         — создать HTML, напечатать ссылку
#   bash report.sh status --print                                   — текст в терминал + HTML + ссылка
#   bash report.sh status --tg                                      — короткое сообщение для Telegram + ссылка
#
# HTML публикуется БЕЗ правки nginx: в каталог заглушки (webroot), который nginx
# уже отдаёт как статику. Webroot определяется из vhost-конфига домена панели,
# переопределение: REPORT_WEBROOT=... в /root/scripts/.env
# Все обращения к БД — только чтение (mode=ro&immutable=1).
export TZ='Europe/Moscow'
DIR="/root/scripts"
ENVF="$DIR/.env"
DB=/etc/x-ui/x-ui.db
LOG=/root/wal-watch.log

[ -f "$ENVF" ] && . "$ENVF" 2>/dev/null
if [ -z "$REPORT_PATH" ]; then
  REPORT_PATH=$(openssl rand -hex 6 2>/dev/null || head -c 16 /dev/urandom | md5sum | cut -c1-12)
  touch "$ENVF"; chmod 600 "$ENVF"
  echo "REPORT_PATH=$REPORT_PATH" >> "$ENVF"
fi

DOMAIN=$(sqlite3 "file:$DB?mode=ro&immutable=1" "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null)
[ -z "$DOMAIN" ] && DOMAIN=$(hostname -f 2>/dev/null || hostname)
HOSTS=$(hostname -s 2>/dev/null || hostname)

detect_webroot() {
  local vh=""
  vh=$(grep -lE "server_name[^;]*${DOMAIN}" /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf 2>/dev/null | head -1)
  [ -z "$vh" ] && vh=$(grep -lE "server_name[^;]*${DOMAIN}" /etc/nginx/sites-enabled/* 2>/dev/null | head -1)
  [ -n "$vh" ] && awk '/^[[:space:]]*root[[:space:]]/{gsub(/;/,""); print $2; exit}' "$vh"
}
WEB="$REPORT_WEBROOT"
[ -z "$WEB" ] && WEB=$(detect_webroot)
[ -z "$WEB" ] && [ -d /var/www/html ] && WEB=/var/www/html
WEB="${WEB%/}"
if [ -n "$WEB" ] && [ -d "$WEB" ]; then OUT="$WEB/$REPORT_PATH"; SERVED=1; else OUT="/var/www/report/$REPORT_PATH"; SERVED=0; fi
mkdir -p "$OUT"

strip_ansi() { sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b([A-Z0-9])//g' -e 's/\r//g'; }

# ------------------------------------------------------------- данные -----
# Версия установленной панели. Источники по надёжности:
# 1) PANEL_VERSION= из /root/scripts/.env — ручная фиксация, 100% точно;
# 2) «x-ui status» (если панель печатает версию);
# 3) самая частая строка «3.x.y» в бинарнике панели (версия вшита при сборке);
# 4) иначе «? + подсказка прописать PANEL_VERSION».
xui_version() {
  [ -n "$PANEL_VERSION" ] && { echo "$PANEL_VERSION"; return; }
  local v
  v=$(timeout 5 x-ui status </dev/null 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+')
  [ -z "$v" ] && v=$(grep -aoE '3\.[0-9]+\.[0-9]+' /usr/local/x-ui/x-ui 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  echo "${v:-? (пропишите PANEL_VERSION=3.x.y в /root/scripts/.env)}"
}
xray_version() { /usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1 | awk '{print $2}'; }
ipv4() { ip -4 -brief addr show scope global 2>/dev/null | awk 'NR==1{split($3,a,"/"); print a[1]}'; }
ipv6() { local v; v=$(ip -6 -brief addr show scope global 2>/dev/null | awk 'NR==1{split($3,a,"/"); print a[1]}'); echo "${v:-нет}"; }
q() { sqlite3 "file:$DB?mode=ro&immutable=1" "$1" 2>/dev/null; }
traffic_gb() { q "SELECT ROUND((COALESCE(SUM(up),0)+COALESCE(SUM(down),0))/1073741824.0,2) FROM client_traffics;" || echo "?"; }
online_clients() {
  # ВАЖНО: это НЕ «клиенты из базы», а число УНИКАЛЬНЫХ ВНЕШНИХ IP, у которых
  # сейчас есть established-соединение с портами xray. Один клиент с двух
  # устройств/сетей = 2. Мимолётные проверки (check-host, сканеры) тоже попадают.
  local ports f="" p
  ports=$(ss -tlnp 2>/dev/null | grep xray | awk '$4 !~ /^127\./ {n=split($4,a,":"); print a[n]}' | sort -u)
  for p in $ports; do f="$f sport = :$p or"; done
  f="${f% or}"
  if [ -n "$f" ]; then
    ss -tn state established "( $f )" 2>/dev/null | awk 'NR>1{print $4}' | rev | cut -d: -f2- | rev | sort -u | wc -l
  else
    echo 0
  fi
}
err_crit() { journalctl -u x-ui --since "1440 minutes ago" -p err --no-pager 2>/dev/null | grep -vE "^-- |^$|No entries" | wc -l; }
err_db()   { journalctl -u x-ui --since "1440 minutes ago" --no-pager 2>/dev/null | grep -icE "malformed|disk I/O|database disk image|readonly database"; }
cpu_pct() { local i; i=$(mpstat 1 1 2>/dev/null | awk '/Average:/ {print $NF}' | cut -d. -f1); [ -z "$i" ] && i=$(top -bn1 | grep '%Cpu' | awk '{print $8}' | cut -d. -f1); [ -z "$i" ] && i=0; echo $((100 - i)); }

html_wrap() {
  local title="$1"
  {
    echo "<!DOCTYPE html><html lang=\"ru\"><head><meta charset=\"utf-8\">"
    echo "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    echo "<title>$title — $DOMAIN</title>"
    echo "<style>body{background:#111;color:#eee;font-family:Menlo,Consolas,monospace;margin:0;padding:16px;font-size:13px}h2{color:#7ec8ff;margin:0 0 12px}pre{white-space:pre-wrap;word-break:break-word;background:#1a1a1a;padding:12px;border-radius:8px;margin:0}footer{color:#888;margin-top:16px;font-size:12px}</style>"
    echo "</head><body><h2>$title</h2><pre>"
  } > /tmp/.htmlhead.$$
  cat /tmp/.htmlhead.$$
  rm -f /tmp/.htmlhead.$$
  sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b([A-Z0-9])//g' -e 's/\r//g' -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
  echo "</pre><footer>Сервер: $DOMAIN · Сформировано: $(date '+%F %T %Z')</footer></body></html>"
}

# ------------------------------------------------- канонические тексты ----
gen_status_text() {
  local P XV XUIV V4 V6 DBS DBTXT REB CPU MEM DISK UP CRIT DBE ONLINE TRAF
  P=$(systemctl is-active x-ui 2>/dev/null)
  XV=$(xray_version); XUIV=$(xui_version); V4=$(ipv4); V6=$(ipv6)
  DBS=$(q "PRAGMA integrity_check;" | head -1)
  DBTXT="✅ База данных: цела"; [ "$DBS" = "ok" ] || DBTXT="❌ БАЗА ДАННЫХ ПОВРЕЖДЕНА: $DBS"
  [ -f /var/run/reboot-required ] && REB="⚠️ Требуется перезагрузка" || REB="✅ Перезагрузка не требуется"
  CPU=$(cpu_pct)
  MEM=$(free -m | awk '/Mem:/ {printf "Занято %d%% | %dMB / %dMB", $3*100/$2, $3, $2}')
  DISK=$(df -h / | awk 'NR==2 {printf "Занято: %s (%s), свободно %s", $5, $3, $4}')
  UP=$(uptime -p | sed 's/up //')
  CRIT=$(err_crit); DBE=$(err_db); ONLINE=$(online_clients); TRAF=$(traffic_gb)
  cat <<EOF
==========================================
  ОТЧЕТ О СОСТОЯНИИ СЕРВЕРА
==========================================

1. Информация о сервере:
   ℹ️ Версия панели: $XUIV
   ℹ️ Версия Xray: ${XV:-?}
   ℹ️ IPv4: ${V4:-—}
   ℹ️ IPv6: $V6

2. Статус панели 3X-UI:
   $([ "$P" = "active" ] && echo "✅ Панель x-ui: ок" || echo "❌ Панель x-ui: НЕ работает")
   $DBTXT
   📊 inbounds: $(q "SELECT COUNT(*) FROM inbounds;")
   👤 clients: $(q "SELECT COUNT(*) FROM clients;")
   👥 clients on-line: $ONLINE
   ⛓️ client_inbounds: $(q "SELECT COUNT(*) FROM client_inbounds;")
   🔗 nodes: $(q "SELECT COUNT(*) FROM nodes;")
   ⛔️ limit_ip>0: $(q "SELECT COUNT(*) FROM clients WHERE limit_ip>0;")
   📈 Трафик клиентов: $TRAF GB

3. Перезагрузка системы:
   $REB

4. Ресурсы сервера:
   📊 Нагрузка (CPU): ${CPU}%
   📈 Память: $MEM
   💾 Диск /: $DISK

5. Время работы (Uptime):
   🕒 Сервер работает: $UP

==========================================
  СТАТУС ОШИБОК
==========================================
$([ "$CRIT" = "0" ] && echo "✅ Критических ошибок за последние 24 часа нет" || echo "⚠️ Критических ошибок за последние 24 часа: $CRIT")
$([ "$DBE" = "0" ] && echo "✅ Ошибки базы данных в логах за последние 24 часа: нет" || echo "❌ Ошибки базы данных в логах за последние 24 часа: $DBE (malformed / disk I/O)")

==========================================
  ВЕРСИИ, СЕРВИСЫ, ПОРТЫ
==========================================
$(/usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1)
Сервисы: x-ui=$(systemctl is-active x-ui 2>/dev/null) nginx=$(systemctl is-active nginx 2>/dev/null) fail2ban=$(systemctl is-active fail2ban 2>/dev/null)
$(ss -tulnp 2>/dev/null | grep -E 'nginx|x-ui|xray' | awk '{print $1, $2, $5, $7}' | sort -u)
==========================================
EOF
  if [ "$DBE" != "0" ]; then
    echo "--- Последние 5 записей об ошибках БД: ---"
    journalctl -u x-ui --since "1440 minutes ago" --no-pager 2>/dev/null | grep -iE "malformed|disk I/O|database disk image|readonly database" | tail -5
  fi
}

gen_status_tg() {
  local P DBS CRIT DBE
  P=$(systemctl is-active x-ui 2>/dev/null)
  DBS=$(q "PRAGMA integrity_check;" | head -1)
  CRIT=$(err_crit); DBE=$(err_db)
  cat <<EOF
📊 Отчёт о состоянии сервера $HOSTS
Версия панели: $(xui_version)
Версия Xray: $(xray_version)
IPv4: $(ipv4)
IPv6: $(ipv6)
Панель: $P $([ "$P" = "active" ] && echo "✅" || echo "❌")
База данных: $([ "$DBS" = "ok" ] && echo "цела ✅" || echo "ПОВРЕЖДЕНА ❌")
Перезагрузка системы: $([ -f /var/run/reboot-required ] && echo "⚠️ нужна" || echo "не требуется ✅")
Сервер работает: $(uptime -p | sed 's/up //')
CPU: $(cpu_pct)%
RAM: $(free -m | awk '/Mem:/ {printf "%d%% (%d из %d MB)", $3*100/$2, $3, $2}')
Диск: $(df -h / | awk 'NR==2 {printf "%s (свободно %s)", $5, $4}')
Трафик: $(traffic_gb) GB
Статус сервера: $([ "$P" = "active" ] && echo "running ✅" || echo "STOPPED ❌")
Критических ошибок за 24 ч: $([ "$CRIT" = "0" ] && echo "нет ✅" || echo "$CRIT ⚠️")
Ошибки БД в логах за 24 ч: $([ "$DBE" = "0" ] && echo "нет ✅" || echo "$DBE ❌")
EOF
}

wal_vars() {
  WW=""; for p in "$DIR/wal-watch.sh" /root/wal-watch.sh; do [ -f "$p" ] && WW="$p" && break; done
  WCRON=$(crontab -l 2>/dev/null | grep wal-watch | head -1)
  WLINES=0; WANOM=0; WLAST=""
  if [ -f "$LOG" ]; then
    WLINES=$(wc -l < "$LOG"); WANOM=$(grep -cE "DELETED|err5m=[1-9]|wal=-" "$LOG"); WLAST=$(tail -1 "$LOG")
  fi
}
gen_wal_text() {
  wal_vars
  echo "=========================================="
  echo "  ОТЧЁТ ПО WAL-СТОРОЖУ"
  echo "=========================================="
  echo "Скрипт: ${WW:-НЕ НАЙДЕН}"
  [ -n "$WW" ] && sha256sum "$WW"
  echo "Cron: ${WCRON:-не установлен}"
  echo "Замеров: $WLINES · Аномалии: $WANOM"
  if [ -f "$LOG" ]; then
    echo "Первый замер: $(head -1 "$LOG")"
    echo ""
    echo "--- Последние 30 замеров ---"
    tail -30 "$LOG"
  else
    echo "Лог ещё не создан"
  fi
}
gen_wal_tg() {
  wal_vars
  echo "🛡 WAL-сторож — сервер $HOSTS"
  echo "Cron: $([ -n "$WCRON" ] && echo "включён ✅" || echo "ВЫКЛЮЧЕН ⚠️")"
  echo "Замеров: $WLINES · Аномалии: $([ "$WANOM" = "0" ] && echo "0 ✅" || echo "$WANOM ❌")"
  [ -n "$WLAST" ] && echo "Последний: $WLAST"
}

gen_etalon_text() {
  if [ ! -f "$DIR/etalon/etalon.txt" ]; then
    echo "⚠️ Эталон ещё не сохранён (menu → Диагностика → Эталон сервера → Сохранить)."
    echo ""
    echo "=== Текущий снапшот ==="
    bash "$DIR/baseline.sh" now --public
    return
  fi
  echo "Эталон: $(head -1 "$DIR/etalon/etalon.txt" | sed 's/^# Снимок: //')"
  echo "(в отчёте секреты замаскированы; полный снимок — на сервере, /root/scripts/etalon/)"
  echo ""
  bash "$DIR/baseline.sh" compare --public 2>&1 | strip_ansi
}
gen_etalon_tg() {
  if [ ! -f "$DIR/etalon/etalon.txt" ]; then echo "📌 Эталон ещё не сохранён."; return; fi
  local n; n=$(bash "$DIR/baseline.sh" compare --public 2>&1 | grep -vE '^(\+\+\+|---)' | grep -cE '^[+-]')
  echo "📌 Эталон — сервер $HOSTS ($(head -1 "$DIR/etalon/etalon.txt" | sed 's/^# Снимок: //'))"
  if [ "$n" = "0" ]; then echo "✅ Отличий от эталона нет"; else echo "⚠️ Отличий от эталона: $n строк"; fi
}

gen_fail2ban_text() {
  echo "=========================================="
  echo "  ОТЧЁТ ПО FAIL2BAN"
  echo "=========================================="
  fail2ban-client status 2>/dev/null || { echo "fail2ban не запущен"; return; }
  local j
  for j in $(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*://; s/,/ /g'); do
    echo ""
    echo "=== Jail: $j ==="
    fail2ban-client status "$j" 2>/dev/null
  done
  if [ -f "$DIR/fail2ban.sh" ]; then
    echo ""
    timeout 15 bash "$DIR/fail2ban.sh" </dev/null 2>&1 | strip_ansi
  fi
}
gen_fail2ban_tg() {
  echo "🛡 fail2ban — сервер $HOSTS"
  local j cb tb
  for j in $(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*://; s/,/ /g'); do
    cb=$(fail2ban-client status "$j" 2>/dev/null | awk -F: '/Currently banned/{gsub(/[ \t]/,"",$2); print $2}')
    tb=$(fail2ban-client status "$j" 2>/dev/null | awk -F: '/Total banned/{gsub(/[ \t]/,"",$2); print $2}')
    echo "jail «$j»: сейчас забанено ${cb:-0} (всего ${tb:-0})"
  done
}

gen_logs_text() {
  local hrs="${1:-24}"
  j() { journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null; }
  echo "Период: последние $hrs ч (x-ui)"
  echo ""
  echo "========== СВОДКА: самые частые записи (дубли схлопнуты) =========="
  j | grep -E "WARNING|ERROR" \
    | sed -E 's/^[A-Za-z]{3} +[0-9]+ [0-9:]{8} [^ ]+ [^:]+: //; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+/IP:PORT/g; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/IP/g' \
    | sort | uniq -c | sort -rn | head -20
  echo ""
  echo "========== ОШИБКИ (уровень ERROR) — все за период, до 100 =========="
  j | grep "ERROR" | tail -100
  echo ""
  echo "========== ПРЕДУПРЕЖДЕНИЯ (WARNING) — последние 20 =========="
  j | grep "WARNING" | tail -20
  echo ""
  echo "========== ИНФО (INFO) — последние 50 =========="
  j | grep "INFO" | tail -50
  echo ""
  echo "Примечание: массовые повторяющиеся WARNING про X-Forwarded-For (nginx передаёт запросы в xray) и про OCSP (в сертификате не указан OCSP-сервер) — штатные для схемы x-ui-pro, действий не требуют."
}
gen_logs_tg() {
  local hrs="${1:-24}" nerr nwrn ninf
  nerr=$(journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null | grep -c "ERROR")
  nwrn=$(journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null | grep -c "WARNING")
  ninf=$(journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null | grep -c "INFO")
  echo "📋 Логи x-ui за ${hrs} ч — сервер $HOSTS"
  echo "ERROR: ${nerr:-0} · WARNING: ${nwrn:-0} · INFO: ${ninf:-0}"
  if [ "${nerr:-0}" = "0" ]; then echo "✅ Ошибок уровня ERROR нет"; else echo "❌ Есть ERROR — список в полном отчёте"; fi
  echo "(массовые WARNING про X-Forwarded-For и OCSP — штатные)"
}

# ------------------------------------------------------- сборка отчёта ----
TYPE="${1:-}"; shift 2>/dev/null
MODE="html"; HOURS=""
for a in "$@"; do
  case "$a" in
    --print) MODE="print";;
    --tg)    MODE="tg";;
    *) [[ "$a" =~ ^[0-9]+$ ]] && HOURS="$a";;
  esac
done

case "$TYPE" in
  status|wal|etalon|fail2ban|logs) ;;
  *) echo "Использование: report.sh {status|wal|etalon|fail2ban|logs} [часы] [--print|--tg]"; exit 1;;
esac

case "$TYPE" in
  status)   TITLE="Отчёт о состоянии сервера"; BASE="status";;
  wal)      TITLE="Отчёт по WAL-сторожу";       BASE="wal";;
  etalon)   TITLE="Сравнение с эталоном";       BASE="etalon";;
  fail2ban) TITLE="Отчёт по fail2ban";          BASE="fail2ban";;
  logs)
    [[ "$HOURS" =~ ^[0-9]+$ ]] || HOURS=24
    [ "$HOURS" -eq 0 ] && HOURS=24
    TITLE="Отсортированные логи x-ui за ${HOURS} ч"; BASE="logs-${HOURS}h";;
esac

BODY=$(mktemp)
case "$TYPE" in
  status)   gen_status_text > "$BODY";;
  wal)      gen_wal_text > "$BODY";;
  etalon)   gen_etalon_text > "$BODY";;
  fail2ban) gen_fail2ban_text > "$BODY";;
  logs)     gen_logs_text "$HOURS" > "$BODY";;
esac

STAMP=$(date -u +%F_%H%M%S)
FILE="$OUT/$STAMP-$BASE.html"
LATEST="$OUT/latest-$BASE.html"
html_wrap "$TITLE" < "$BODY" > "$FILE"
cp -f "$FILE" "$LATEST"
ls -1t "$OUT"/*-"$BASE".html 2>/dev/null | grep -v latest | tail -n +31 | xargs -r rm -f

if [ "$SERVED" = "1" ]; then
  URL="https://$DOMAIN/$REPORT_PATH/latest-$BASE.html?v=$(date +%s)"
else
  URL="(webroot заглушки не найден — укажите REPORT_WEBROOT= в $ENVF; файл: $FILE)"
fi

case "$MODE" in
  print)
    cat "$BODY"
    echo ""
    echo "🌐 Ссылка на отчет: $URL"
    ;;
  tg)
    case "$TYPE" in
      status)   gen_status_tg;;
      wal)      gen_wal_tg;;
      etalon)   gen_etalon_tg;;
      fail2ban) gen_fail2ban_tg;;
      logs)     gen_logs_tg "$HOURS";;
    esac
    echo ""
    echo "🌐 Полный отчёт: $URL"
    ;;
  *)
    echo "✅ Отчёт сформирован: $TITLE"
    echo "Файл:  $FILE"
    echo "Ссылка: $URL"
    ;;
esac
rm -f "$BODY"
