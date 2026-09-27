#!/bin/bash
# ext-check.sh v2.0 (26.09.2026) — внешняя проверка доступности инбаундов через check-host.net.
# Отвечает на вопрос «блокирует ли провайдер?» — проверяют внешние узлы из разных стран.
#
# Запуск:
#   bash /root/scripts/ext-check.sh                  — интерактивное меню (пункты 1..9)
#   bash /root/scripts/ext-check.sh all [--tg]       — всё сразу (Nginx 443 + все инбаунды)
#   bash /root/scripts/ext-check.sh port 8443 [--tg] — один порт
#   bash /root/scripts/ext-check.sh sub URL [--tg]   — ссылка клиентской подписки (HTTP-проверка)
#   bash /root/scripts/ext-check.sh 8443             — совместимость с v3.1 (один порт)
#
# Режим --tg печатает короткую сводку для Telegram-бота (единый источник:
# терминал = HTML = Telegram, как в report.sh).
#
# API check-host.net (проверено вживую 26.09.2026):
#   отправка:  GET https://check-host.net/check-tcp?host=ДОМЕН:ПОРТ&max_nodes=N
#              (Accept: application/json) → {"request_id","nodes","permanent_link"}
#   результат: GET https://check-host.net/check-result/<request_id>   ← ЕДИНСТВЕННОЕ число!
#              («check-results» во множественном числе НЕ существует → HTTP 404,
#               именно так ломалась проверка в v3.1)
#   успех узла: [{"address":IP,"time":сек}] · отказ: [{"error":"Connection timed out"}]
#   HTTP-проверка: [[1,время,"OK","200",IP]] · [[0,время,"Not Found","404",IP]]
#   ещё не готово: null
export TZ='Europe/Moscow'
export LC_ALL=C
DIR="/root/scripts"
ENVF="$DIR/.env"
DB="/etc/x-ui/x-ui.db"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; WHITE='\033[0;37m'; PINK='\033[95m'; NC='\033[0m'

# ------------------------------------------------- разбор аргументов -----
MODE="menu"; ARG=""; TGFLAG=""
case "${1:-}" in
  all)  MODE="all"; shift;;
  port) MODE="port"; ARG="${2:-}"; shift 2 2>/dev/null || shift;;
  sub)  MODE="sub";  ARG="${2:-}"; shift 2 2>/dev/null || shift;;
  list) MODE="list"; shift;;
  "")   MODE="menu";;
  *)
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then MODE="port"; ARG="$1"; shift
    else echo "Использование: ext-check.sh [all|port ПОРТ|sub URL|list] [--tg]"; exit 1; fi;;
esac
for a in "$@"; do [ "$a" = "--tg" ] && TGFLAG="--tg"; done

# --------------------------- .env, REPORT_PATH, домен, webroot (как в report.sh) --
[ -f "$ENVF" ] && . "$ENVF" 2>/dev/null
if [ -z "$REPORT_PATH" ]; then
  REPORT_PATH=$(openssl rand -hex 6 2>/dev/null || head -c 16 /dev/urandom | md5sum | cut -c1-12)
  touch "$ENVF" 2>/dev/null; chmod 600 "$ENVF" 2>/dev/null
  echo "REPORT_PATH=$REPORT_PATH" >> "$ENVF" 2>/dev/null
fi

pyq() { python3 -c "
import sqlite3,sys
try:
    c=sqlite3.connect('file:$DB?mode=ro&immutable=1',uri=True)
    print((c.execute(sys.argv[1]).fetchone() or [''])[0] or '')
except Exception:
    pass" "$1" 2>/dev/null; }

DOMAIN=$(pyq "SELECT value FROM settings WHERE key='webDomain';")
DOMAIN="${DOMAIN//[$'\t\r\n ']/}"
[ -z "$DOMAIN" ] && DOMAIN=$(hostname -f 2>/dev/null || hostname)

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
SERVED=0
if [ -n "$WEB" ] && [ -d "$WEB" ]; then OUT="$WEB/$REPORT_PATH"; SERVED=1; else OUT="/var/www/report/$REPORT_PATH"; fi
mkdir -p "$OUT" 2>/dev/null
URLBASE="https://$DOMAIN/$REPORT_PATH"

export EXTCHECK_DOMAIN="$DOMAIN" EXTCHECK_OUT="$OUT" EXTCHECK_SERVED="$SERVED" EXTCHECK_URLBASE="$URLBASE"

# ----------------------------------------------------- ядро (python3) ----
ext_core() {
python3 - "$MODE" "$ARG" "$TGFLAG" <<'PYEOF'
import datetime, json, os, sqlite3, sys, time, urllib.parse, urllib.request

try:
    time.tzset()      # подхватить TZ=Europe/Moscow из оболочки (для %Z в дате)
except AttributeError:
    pass

DB = "/etc/x-ui/x-ui.db"
MODE = sys.argv[1] if len(sys.argv) > 1 else "all"
ARG = sys.argv[2] if len(sys.argv) > 2 else ""
TG = (len(sys.argv) > 3 and sys.argv[3] == "--tg")
DOMAIN = os.environ.get("EXTCHECK_DOMAIN", "").strip()
OUT = os.environ.get("EXTCHECK_OUT", "")
SERVED = os.environ.get("EXTCHECK_SERVED", "0") == "1"
URLBASE = os.environ.get("EXTCHECK_URLBASE", "")
PROG = os.environ.get("EXTCHECK_PROGRESS", "")
MAX_NODES = "10"
DEADLINE_S = 150          # общий лимит ожидания ответов узлов
MAX_POLL_FAILS = 5        # подряд ошибок опроса одного request_id → больше не пробуем (v3.1 тут висела вечно)

def progress(pct, text):
    if PROG:
        try:
            with open(PROG, "a") as f:
                f.write("%d|%s\n" % (pct, text))
        except Exception:
            pass

def db_rows(sql):
    try:
        conn = sqlite3.connect("file:%s?mode=ro&immutable=1" % DB, uri=True)
        rows = conn.execute(sql).fetchall()
        conn.close()
        return rows
    except Exception:
        return []

def inbounds():
    out = []
    for remark, port, proto in db_rows(
            "SELECT remark, port, protocol FROM inbounds WHERE enable=1 AND port>0 ORDER BY id;"):
        remark = (remark or "").strip()
        proto = (proto or "").strip().lower()
        label = remark or ("%s :%s" % (proto or "инбаунд", port))
        kind = "udp" if "hysteria" in proto else "tcp"
        out.append({"label": label[:24], "port": str(port), "kind": kind})
    return out

def ch_get(url, params=None):
    if params:
        url = url + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Accept": "application/json",
                                               "User-Agent": "3x-ui-diagnostics/3.2"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode("utf-8", "replace"))

def build_targets():
    if MODE == "sub":
        return [{"label": "Подписка клиента", "url": ARG, "kind": "http"}]
    if MODE == "port":
        for ib in inbounds():
            if ib["port"] == ARG:
                return [dict(ib)]
        if ARG == "443":
            return [{"label": "Nginx 443", "port": "443", "kind": "tcp"}]
        return [{"label": "Порт " + ARG, "port": ARG, "kind": "tcp"}]
    t = [{"label": "Nginx 443", "port": "443", "kind": "tcp"}]
    t += inbounds()
    return t

def submit(t):
    if t["kind"] == "udp":
        t["skip"] = "UDP-протокол: check-host.net умеет проверять только TCP"
        return
    try:
        if t["kind"] == "http":
            r = ch_get("https://check-host.net/check-http", {"host": t["url"], "max_nodes": MAX_NODES})
        else:
            r = ch_get("https://check-host.net/check-tcp",
                       {"host": "%s:%s" % (DOMAIN, t["port"]), "max_nodes": MAX_NODES})
        if isinstance(r, dict) and r.get("error") == "limit_exceeded":
            t["error"] = ("check-host.net отклонил запрос: слишком частые проверки с этого IP "
                          "(limit_exceeded). Подождите 1–2 минуты и повторите.")
            return
        t["rid"] = r.get("request_id") or ""
        t["nodes"] = r.get("nodes") or {}
        t["link"] = r.get("permanent_link") or ""
        if not t["rid"]:
            t["error"] = "check-host не вернул request_id: %s" % str(r)[:120]
    except Exception as e:
        t["error"] = "ошибка запроса к check-host: %s" % e

def node_verdict(v):
    """Вердикт одного узла. Форматы (проверены вживую 26.09.2026):
    TCP успех: [{'address':IP,'time':сек}] · TCP отказ: [{'error':'текст'}] · не готово: None
    HTTP: [[1, время, 'OK', '200', IP]] / [[0, время, 'Not Found', '404', IP]]"""
    if v is None:
        return "pending", ""
    items = v if isinstance(v, list) else [v]
    for it in items:
        if it is None:
            return "pending", ""
        if isinstance(it, dict):
            if it.get("error"):
                return "bad", str(it["error"])[:60]
            if "address" in it or "time" in it:
                try:
                    return "ok", "%.2f с" % float(it.get("time"))
                except (TypeError, ValueError):
                    return "ok", ""
            return "pending", ""
        if isinstance(it, list) and it:
            head = it[0]
            if head is None:
                return "pending", ""
            if head in (1, True):
                if len(it) >= 4 and str(it[3]).strip().isdigit():     # HTTP-формат
                    code, phrase = str(it[3]).strip(), str(it[2])
                    return ("ok" if code.startswith("2") else "bad"), "HTTP %s %s" % (code, phrase)
                try:
                    return "ok", "%.2f с" % float(it[1])
                except (TypeError, ValueError, IndexError):
                    return "ok", ""
            if head in (0, False):
                if len(it) >= 4 and str(it[3]).strip().isdigit():
                    return "bad", "HTTP %s %s" % (str(it[3]).strip(), it[2])
                for x in it[1:]:
                    if isinstance(x, str) and x.strip():
                        return "bad", x.strip()[:60]
                return "bad", "нет ответа"
            if isinstance(head, str) and head.strip():
                s = head.strip()
                return ("ok", "") if s.lower() in ("connected", "ok") else ("bad", s[:60])
    return "pending", ""

def poll(targets):
    pend = {}
    for t in targets:
        if t.get("rid"):
            t["res"] = {}
            pend[t["rid"]] = t
    fails = {rid: 0 for rid in pend}
    total = len(pend)
    t0 = time.time()
    while pend and time.time() - t0 < DEADLINE_S:
        time.sleep(4)
        for rid in list(pend):
            t = pend[rid]
            try:
                res = ch_get("https://check-host.net/check-result/" + rid)   # ЕДИНСТВЕННОЕ число!
                if isinstance(res, dict) and res.get("error") == "limit_exceeded":
                    raise RuntimeError("limit_exceeded (слишком частые запросы)")
                fails[rid] = 0
                if isinstance(res, dict):
                    t["res"] = res
                    if res and all(v is not None for v in res.values()):
                        del pend[rid]
            except Exception as e:
                fails[rid] += 1
                time.sleep(2)      # мягкий бэкофф при ошибках/лимитах
                if fails[rid] >= MAX_POLL_FAILS:
                    t["error"] = "не удалось получить результат (%d ошибок подряд: %s)" % (fails[rid], e)
                    del pend[rid]
            time.sleep(0.4)
        done = total - len(pend)
        progress(30 + int(55 * done / max(total, 1)),
                 "Жду ответы узлов из разных стран: готово %d из %d" % (done, total))
    for t in pend.values():
        t["timeout"] = True

def summarize(t):
    if t.get("skip"):
        t["mark"] = "⚠️"
        return
    if t.get("error"):
        t["mark"] = "⛔"
        return
    rows = []
    nodes = t.get("nodes") or {}
    for nid, v in (t.get("res") or {}).items():
        meta = (list(nodes.get(nid) or []) + ["?", "?", "?"])[:3]
        cc, country, city = meta[0], meta[1], meta[2]
        st, det = node_verdict(v)
        rows.append(((cc or "?").upper()[:3], country or "?", city or "", st, det))
    rows.sort()
    t["rows"] = rows
    ans = [r for r in rows if r[3] in ("ok", "bad")]
    t["ok"] = sum(1 for r in ans if r[3] == "ok")
    t["bad"] = len(ans) - t["ok"]
    t["pend"] = len(rows) - len(ans)
    t["mark"] = "⚠️" if not ans or (t["ok"] and t["bad"]) else ("✅" if t["ok"] else "❌")
    hints = []
    errs = [r[4].lower() for r in ans if r[3] == "bad"]
    if errs:
        n_to = sum(1 for e in errs if "timed out" in e or "timeout" in e)
        n_rf = sum(1 for e in errs if "refused" in e)
        thr = max(1, int(len(errs) * 0.6))
        n_all = t["ok"] + t["bad"]
        if t["ok"] == 0 and n_rf >= thr:
            hints.append("сервер ОТКАЗЫВАЕТ в соединении: порт никто не слушает "
                         "(сервис не запущен / vhost пуст) или файрвол REJECT")
        elif t["ok"] == 0 and n_to >= thr:
            hints.append("ответа нет ни из одной страны: пакеты теряются — "
                         "файрвол DROP, порт не открыт в ufw или блокировка у провайдера")
        elif n_all and t["ok"] * 2 < n_all:
            ok_c = ", ".join(sorted(set(r[1] for r in ans if r[3] == "ok")))
            hints.append("работает лишь из %d стран из %d (%s) — скорее всего порт закрыт "
                         "или фильтруется почти везде; проверить ufw и слушает ли порт сервис"
                         % (t["ok"], n_all, ok_c))
        elif t["ok"] > 0:
            bad_c = ", ".join(sorted(set(r[1] for r in ans if r[3] == "bad")))
            hints.append("из части стран работает — вероятна точечная блокировка "
                         "(DPI/провайдер) в странах: " + bad_c)
        else:
            uniq = sorted(set(e for e in errs))[:3]
            hints.append("ошибки узлов: " + "; ".join(uniq))
    if t.get("timeout") and t.get("pend"):
        hints.append("%d узлов не ответили вовремя (check-host тормозит) — повторите проверку" % t["pend"])
    t["hints"] = hints

def target_head(t):
    if t["kind"] == "http":
        return "%s — %s" % (t["label"], t["url"])
    return "%s — %s:%s%s" % (t["label"], DOMAIN, t["port"], " (UDP)" if t["kind"] == "udp" else "")

def detail_text(targets, url):
    L = []
    bar = "=" * 56
    L.append(bar)
    L.append(" ПОДПИСКА" if MODE == "sub" else " ВНЕШНЯЯ ПРОВЕРКА ДОСТУПНОСТИ ИНБАУНДОВ")
    L.append(bar)
    if MODE == "sub":
        L.append("Ссылка: %s" % ARG)
        L.append("Сервис: check-host.net · узлов: до %s" % MAX_NODES)
    else:
        L.append("Домен: %s · Сервис: check-host.net · узлов на проверку: до %s" % (DOMAIN, MAX_NODES))
    L.append("Время: %s" % time.strftime("%F %T %Z"))
    for t in targets:
        L.append("")
        L.append("── %s ──" % target_head(t))
        if t.get("skip"):
            L.append("⚠️ НЕ проверялось: %s" % t["skip"])
            continue
        if t.get("error"):
            L.append("⛔ %s" % t["error"])
            continue
        n = t["ok"] + t["bad"]
        L.append("%s доступно: %d из %d стран%s" % (t["mark"], t["ok"], n,
                 " (ещё не ответили узлов: %d)" % t["pend"] if t.get("pend") else ""))
        for cc, country, city, st, det in t["rows"]:
            if st == "ok":
                L.append("  ✅ %-3s %-14s %-16s %s" % (cc, country[:14], city[:16], det))
            elif st == "bad":
                L.append("  ❌ %-3s %-14s %-16s %s" % (cc, country[:14], city[:16], det or "нет доступа"))
            else:
                L.append("  …  %-3s %-14s %-16s нет ответа узла" % (cc, country[:14], city[:16]))
        for h in t.get("hints", []):
            L.append("  💡 Похоже: %s" % h)
        if t.get("link"):
            L.append("  Подробно (check-host): %s" % t["link"])
    if MODE != "sub":
        ok = sum(1 for t in targets if t["mark"] == "✅")
        bad = sum(1 for t in targets if t["mark"] == "❌")
        part = sum(1 for t in targets if t["mark"] == "⚠️")
        err = sum(1 for t in targets if t["mark"] == "⛔")
        L.append("")
        L.append("ИТОГ: ✅ %d · ❌ %d · ⚠️ %d%s" % (ok, bad, part, (" · ⛔ %d" % err) if err else ""))
    L.append("")
    L.append("🌐 Полный отчёт: %s" % url)
    return "\n".join(L)

def tg_text(targets, url):
    if MODE == "sub":
        t = targets[0]
        mark = t.get("mark", "⛔")
        codes = {}
        for r in t.get("rows", []):
            if r[3] in ("ok", "bad") and r[4].startswith("HTTP"):
                c = r[4].split()[1]
                codes[c] = codes.get(c, 0) + 1
        top = max(codes, key=codes.get) if codes else ""
        lines = ["🌍 Проверка подписки: %s%s" % (mark, (" HTTP " + top) if top else "")]
        if t.get("error"):
            lines.append("⛔ %s" % t["error"])
        elif t.get("rows"):
            n = t["ok"] + t["bad"]
            lines.append("HTTP-ответ получен из %d стран" % n)
    else:
        lines = ["🌍 Внешняя проверка доступности инбаундов:"]
        udp = False
        for t in targets:
            if t.get("skip"):
                udp = True
            lines.append("%s: %s" % (t["label"], t["mark"]))
        if udp:
            lines.append("⚠️ — UDP-протокол (Hysteria2): check-host проверяет только TCP")
        errl = [t for t in targets if t.get("error")]
        if errl:
            if all("limit_exceeded" in t["error"] or "слишком частые" in t["error"] for t in errl):
                lines.append("⛔ — лимит check-host.net (слишком частые проверки): повторите через 1–2 минуты")
            else:
                lines.append("⛔ — ошибка запроса check-host: %s" % ", ".join(t["label"] for t in errl))
    lines.append("")
    lines.append("🌐 Полный отчёт: %s" % url)
    return "\n".join(lines)

def write_html(text):
    if not OUT:
        return
    esc = (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
    title = "Проверка подписки" if MODE == "sub" else "Внешняя проверка доступности инбаундов"
    html = ("<!DOCTYPE html><html lang=\"ru\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>%s — %s</title>"
            "<style>body{background:#111;color:#eee;font-family:Menlo,Consolas,monospace;"
            "margin:0;padding:16px;font-size:13px}h2{color:#7ec8ff;margin:0 0 12px}"
            "pre{white-space:pre-wrap;word-break:break-word;background:#1a1a1a;padding:12px;"
            "border-radius:8px;margin:0}footer{color:#888;margin-top:16px;font-size:12px}</style>"
            "</head><body><h2>%s</h2><pre>%s</pre>"
            "<footer>Сервер: %s · Сформировано: %s</footer></body></html>"
            % (title, DOMAIN, title, esc, DOMAIN, time.strftime("%F %T %Z")))
    try:
        stamp = datetime.datetime.utcnow().strftime("%F_%H%M%S")
        path = os.path.join(OUT, stamp + "-ext-check.html")
        with open(path, "w", encoding="utf-8") as f:
            f.write(html)
        latest = os.path.join(OUT, "latest-ext-check.html")
        with open(latest, "w", encoding="utf-8") as f:
            f.write(html)
        old = sorted(x for x in os.listdir(OUT)
                     if x.endswith("-ext-check.html") and x != "latest-ext-check.html")
        for x in old[:-30]:
            try:
                os.remove(os.path.join(OUT, x))
            except Exception:
                pass
    except Exception as e:
        sys.stderr.write("HTML не записан: %r\n" % e)

# ----------------------------------------------------------------- main --
if MODE == "list":
    for ib in inbounds():
        print("%s|%s|%s" % (ib["label"], ib["port"], ib["kind"]))
    sys.exit(0)

progress(5, "Читаю инбаунды из базы панели")
targets = build_targets()
if MODE != "sub" and not targets:
    print("❌ В базе панели нет включённых инбаундов с портами — проверять нечего.")
    sys.exit(1)
if MODE == "sub" and not ARG.startswith(("http://", "https://")):
    print("❌ Ссылка подписки должна начинаться с http:// или https://")
    sys.exit(1)

tcp_n = sum(1 for t in targets if not t.get("kind") == "udp")
progress(10, "Отправляю проверки на check-host.net (%d шт.)" % max(tcp_n, 1))
i = 0
for t in targets:
    submit(t)
    i += 1
    progress(10 + int(15 * i / max(len(targets), 1)),
             "Отправлено проверок: %d из %d" % (i, len(targets)))
    time.sleep(0.4)

progress(28, "Жду ответы узлов из разных стран")
poll(targets)

progress(90, "Формирую отчёт (терминал + HTML)")
for t in targets:
    summarize(t)
url = ("%s/latest-ext-check.html?v=%d" % (URLBASE, int(time.time()))) if SERVED else \
      "(webroot заглушки не найден — укажите REPORT_WEBROOT= в /root/scripts/.env)"
detail = detail_text(targets, url)
write_html(detail if SERVED else detail)
progress(100, "Готово")
print(tg_text(targets, url) if TG else detail)
PYEOF
}

# ------------------------------------------- спиннер с процентами -------
PROG_FILE="/tmp/.ext-check-progress.$$"
run_core() {
  local out rc
  out=$(mktemp)
  if [ -t 1 ]; then
    : > "$PROG_FILE"
    EXTCHECK_PROGRESS="$PROG_FILE" ext_core "$@" > "$out" 2>&1 &
    local cpid=$! s='|/-\' i=0 pct txt
    while kill -0 "$cpid" 2>/dev/null; do
      pct=""; txt=""
      IFS='|' read -r pct txt <<< "$(tail -1 "$PROG_FILE" 2>/dev/null)"
      [ -z "$pct" ] && pct=0
      [ -z "$txt" ] && txt="запуск..."
      printf "\r\033[K  ${YELLOW}[%s]${NC} %3s%% — %s" "${s:i++%${#s}:1}" "$pct" "$txt"
      sleep 0.2
    done
    wait "$cpid"; rc=$?
    printf "\r\033[K"
    cat "$out"
  else
    EXTCHECK_PROGRESS="$PROG_FILE" ext_core "$@" > "$out" 2>&1
    rc=$?
    cat "$out"
  fi
  rm -f "$out" "$PROG_FILE"
  return $rc
}

# ------------------------------------------------- прямые режимы ---------
if [ "$MODE" != "menu" ]; then
  run_core
  exit $?
fi

# ------------------------------------------------ интерактивное меню -----
while true; do
  [ -t 1 ] && clear
  echo -e "${PINK}========================================${NC}"
  echo -e "${PINK}  ВНЕШНЯЯ ПРОВЕРКА ДОСТУПНОСТИ ИНБАУНДОВ${NC}"
  echo -e "${PINK}========================================${NC}"
  echo ""
  echo -e "${WHITE}Домен: $DOMAIN · сервис check-host.net (узлы из разных стран)${NC}"
  echo ""
  echo "Выберите из списка"
  echo -e "  ${GREEN}1.${NC} Все сразу (Nginx 443 + все инбаунды)"
  n=1; declare -a MPORTS=()
  while IFS='|' read -r lbl prt kind; do
    [ -z "$prt" ] && continue
    n=$((n+1)); MPORTS+=("$prt")
    suffix=""; [ "$kind" = "udp" ] && suffix=", UDP — не проверяется снаружи"
    echo -e "  ${GREEN}${n}.${NC} $lbl ($prt$suffix)"
  done < <(EXTCHECK_DOMAIN="$DOMAIN" python3 -c "
import sqlite3
try:
    c = sqlite3.connect('file:$DB?mode=ro&immutable=1', uri=True)
    for remark, port, proto in c.execute('SELECT remark, port, protocol FROM inbounds WHERE enable=1 AND port>0 ORDER BY id;'):
        proto = (proto or '').strip().lower()
        label = (remark or '').strip() or (proto or 'inbound') + ' :' + str(port)
        print('%s|%s|%s' % (label[:24], port, 'udp' if 'hysteria' in proto else 'tcp'))
except Exception:
    pass")
  n=$((n+1)); NGINX_ITEM=$n
  echo -e "  ${GREEN}${n}.${NC} Nginx 443"
  n=$((n+1)); MANUAL_ITEM=$n
  echo -e "  ${GREEN}${n}.${NC} Введите порт вручную"
  n=$((n+1)); SUB_ITEM=$n
  echo -e "  ${GREEN}${n}.${NC} Проверить подписку клиента (вставить ссылку)"
  echo -e "  ${GREEN}0.${NC} ← Назад"
  echo ""
  read -p "  Ваш выбор: " c || exit 0
  case "$c" in
    1) echo ""; MODE="all"; run_core; MODE="menu" ;;
    0|"") exit 0 ;;
    *)
      if [ "$c" = "$SUB_ITEM" ]; then
        echo ""
        echo "Вставьте ссылку подписки (http:// или https://):"
        echo -e "${YELLOW}⚠️ Ссылка содержит ключ клиента: внешние узлы check-host.net скачают её"
        echo -e "содержимое при проверке. Используйте только на своём тестовом клиенте.${NC}"
        read -r suburl || exit 0
        if [[ "$suburl" =~ ^https?:// ]]; then
          ARG="$suburl"; MODE="sub"; run_core; MODE="menu"; ARG=""
        else
          echo -e "${RED}❌ Ссылка должна начинаться с http:// или https://${NC}"
        fi
      elif [ "$c" = "$MANUAL_ITEM" ]; then
        echo ""
        read -p "  Введите порт для проверки (число): " mport || exit 0
        if [[ "$mport" =~ ^[0-9]+$ ]] && [ "$mport" -ge 1 ] && [ "$mport" -le 65535 ]; then
          ARG="$mport"; MODE="port"; run_core; MODE="menu"; ARG=""
        else
          echo -e "${RED}❌ Нужно число от 1 до 65535${NC}"
        fi
      elif [ "$c" = "$NGINX_ITEM" ]; then
        echo ""; ARG="443"; MODE="port"; run_core; MODE="menu"; ARG=""
      elif [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 2 ] && [ "$c" -le $((NGINX_ITEM-1)) ]; then
        echo ""; ARG="${MPORTS[$((c-2))]}"; MODE="port"; run_core; MODE="menu"; ARG=""
      else
        echo -e "${RED}Неверный выбор${NC}"; sleep 1
      fi
      ;;
  esac
  echo ""
  read -p "Нажмите Enter для возврата в меню..." || exit 0
done
