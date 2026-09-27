#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tg-bot.py — Telegram-бот диагностики сервера 3x-ui (версия 0.3.1, 27.09.2026).

ОДИН сервер = ОДИН запущенный бот (Telegram не позволяет нескольким процессам
слушать один токен). Мульти-серверная версия (выбор сервера, общий отчёт) — v0.4.

Только стандартная библиотека python3 (без pip). Настройки: /root/scripts/.env
(BOT_TOKEN, CHAT_ID, REPORT_INTERVAL_HOURS, SERVER_NAME, TG_ENABLED).

v0.2: отчёты через report.sh --tg (единый источник «терминал = HTML = Telegram»);
сообщение-заглушка «⏳ Готовлю отчёт...» РЕДАКТИРУЕТСЯ в готовый отчёт;
бэкапы: кнопка «📦 Бэкап сейчас» + автоматическая утренняя отправка файла (09:05 МСК);
ежедневное «жив» в 09:00 МСК; алерты WAL-сторожа только при смене состояния.
v0.3 (26.09): внешняя проверка ПЕРЕДЕЛАНА по заданию владельца:
- ОДНА кнопка «🌍 Внешняя проверка» — проверяет ВСЁ СРАЗУ (Nginx 443 + все
  инбаунды), а не по одному порту;
- код check-host.net из бота УБРАН: проверку делает ext-check.sh all --tg
  (единый источник «терминал = HTML = Telegram», как report.sh);
- исправлена причина «HTTPError 404»: правильный адрес API —
  https://check-host.net/check-result/<request_id> (единственное число;
  «check-results» не существует);
- заглушка «⏳» каждые ~12 с обновляется прогрессом (проценты, этап) — видно,
  что бот жив;
- итог в Telegram: «🌍 Внешняя проверка доступности инбаундов:» + строки
  «Название: ✅/❌/⚠️» + ссылка «🌐 Полный отчёт» (HTML со странами и причинами).
v0.3.1 (27.09): эталон ВЕРСИОННЫЙ (baseline.sh v2.0, задание владельца):
- «💾 Создать новый эталон» — каждый раз НОВЫЙ файл с датой/временем, старые
  НЕ перезаписываются (подтверждение «yes» больше не нужно);
- новая кнопка «📚 Список эталонов» — история снимков;
- сравнение текущего состояния с последним эталоном — как раньше (r:etalon).

Безопасность: обновления принимаются ТОЛЬКО от CHAT_ID из .env; деструктивные
действия — после подтверждения («yes» или кнопка). Токен не покидает сервер.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

ENVF = "/root/scripts/.env"
SCRIPTS = "/root/scripts"
WALLOG = "/root/wal-watch.log"
REBOOT_MARKER = "/root/.tg-diag-reboot-pending"


def load_env():
    env = {}
    try:
        with open(ENVF, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return env


def set_env_key(key, val):
    lines = []
    if os.path.exists(ENVF):
        with open(ENVF, encoding="utf-8") as f:
            lines = f.read().splitlines()
    out, found = [], False
    for l in lines:
        if l.strip().startswith(key + "="):
            out.append("%s=%s" % (key, val))
            found = True
        else:
            out.append(l)
    if not found:
        out.append("%s=%s" % (key, val))
    with open(ENVF, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.chmod(ENVF, 0o600)


ENV = load_env()
TOKEN = ENV.get("BOT_TOKEN", "")
CHAT = ENV.get("CHAT_ID", "")
try:
    CHAT_INT = int(CHAT)
except ValueError:
    CHAT_INT = None
try:
    INTERVAL = max(1, min(168, int(ENV.get("REPORT_INTERVAL_HOURS", "6"))))
except ValueError:
    INTERVAL = 6
SRVNAME = ENV.get("SERVER_NAME", os.uname().nodename)
API = "https://api.telegram.org/bot" + TOKEN


def log(msg):
    print("[%s] %s" % (datetime.datetime.now().strftime("%F %T"), msg), flush=True)


def sh(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        out = p.stdout or ""
        if p.stderr and p.stderr.strip():
            out += "\n[stderr] " + p.stderr.strip()
        return out.strip()
    except subprocess.TimeoutExpired:
        return "[таймаут команды]"
    except Exception as e:
        return "[ошибка: %s]" % e


def tg(method, **params):
    if not TOKEN:
        return {"ok": False}
    data = json.dumps(params).encode("utf-8")
    req = urllib.request.Request(API + "/" + method, data=data,
                                 headers={"Content-Type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:
            log("TG API %s (попытка %d): %r" % (method, attempt + 1, e))
            time.sleep(3)
    return {"ok": False}


def send(text, kb=None):
    params = {"chat_id": CHAT, "text": str(text)[:4000]}
    if kb:
        params["reply_markup"] = {"inline_keyboard": kb}
    return tg("sendMessage", **params)


def edit(text, msg_id, kb=None):
    params = {"chat_id": CHAT, "message_id": msg_id, "text": str(text)[:4000]}
    if kb:
        params["reply_markup"] = {"inline_keyboard": kb}
    return tg("editMessageText", **params)


def send_document(path, caption=""):
    boundary = "----tgboundary%d" % int(time.time() * 1000)
    fn = os.path.basename(path)
    try:
        with open(path, "rb") as f:
            filedata = f.read()
    except Exception as e:
        return {"ok": False, "error": str(e)}
    if len(filedata) > 49 * 1024 * 1024:
        return {"ok": False, "error": "файл больше 49 МБ (лимит Bot API)"}
    parts = []
    parts.append(("--%s\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n%s\r\n" % (boundary, CHAT)).encode())
    if caption:
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n%s\r\n" % (boundary, caption[:1000])).encode())
    parts.append(("--%s\r\nContent-Disposition: form-data; name=\"document\"; filename=\"%s\"\r\nContent-Type: application/gzip\r\n\r\n" % (boundary, fn)).encode())
    parts.append(filedata)
    parts.append(("\r\n--%s--\r\n" % boundary).encode())
    body = b"".join(parts)
    req = urllib.request.Request(API + "/sendDocument", data=body,
                                 headers={"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    for attempt in range(2):
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:
            log("sendDocument (попытка %d): %r" % (attempt + 1, e))
            time.sleep(3)
    return {"ok": False}


def btn(text, cb):
    return {"text": text, "callback_data": cb}


def kbd(*rows):
    return [list(r) for r in rows]


BACK_HOME = (btn("⬅️ Назад", "m:diag"), btn("🏠 Главное меню", "m:home"))
BACK_MAIN = (btn("🏠 Главное меню", "m:home"),)


def resources_text():
    cpu = sh("top -bn1 | grep '%Cpu' | awk '{print 100-$8}' | cut -d. -f1") or "?"
    ram = sh("free -m | awk '/Mem:/ {printf \"%d%% (занято %d MB из %d MB, свободно %d MB)\", $3*100/$2, $3, $2, $7}'")
    disk = sh("df -BG / | awk 'NR==2 {printf \"занято %s из %s, свободно %s\", $3, $2, $4}'")
    diskh = sh("df -h / | awk 'NR==2 {printf \"%s (свободно %s)\", $5, $4}'")
    now = datetime.datetime.now().strftime("%F %T")
    return ("📈 Ресурсы — сервер %s\n\nCPU: %s%%\nRAM: %s\nДиск /: %s (%s)\n\n🕒 %s"
            % (SRVNAME, cpu, ram, disk, diskh, now))


def report_via_sh(args, kb=None):
    """Заглушка «⏳ Готовлю отчёт...» редактируется в готовый отчёт (мусор не остаётся)."""
    m = send("⏳ Готовлю отчёт...")
    mid = (m.get("result") or {}).get("message_id")
    out = sh("bash %s/report.sh %s --tg" % (SCRIPTS, args), timeout=240)
    text = out.strip() or "(report.sh вернул пусто — выполните в терминале: bash %s/report.sh %s --tg)" % (SCRIPTS, args)
    kb = kb or kbd(BACK_HOME)
    if mid:
        r = edit(text, mid, kb)
        if not r.get("ok"):
            send(text, kb)
    else:
        send(text, kb)


def do_backup(daily=False):
    m = send("📦 Создаю бэкап (обычно до 1 минуты)...")
    mid = (m.get("result") or {}).get("message_id")
    out = sh("bash %s/backup.sh" % SCRIPTS, timeout=600)
    mt = re.search(r"✅ Бэкап: (\S+) \(([^)]+)\)", out)
    if not mt:
        text = "❌ Бэкап не создан:\n%s" % out[:600]
    else:
        path, size = mt.group(1), mt.group(2)
        ms = re.search(r"sha256: (\S+)", out)
        sha = ms.group(1) if ms else "?"
        cap = ("🌅 Утренний бэкап" if daily else "📦 Бэкап") + " — сервер %s · %s · %s · sha256 %s…" % (
            SRVNAME, datetime.datetime.now().strftime("%F %T"), size, sha[:12])
        r = send_document(path, cap)
        if r.get("ok"):
            text = "✅ Бэкап создан и отправлен файлом:\n%s\nРазмер: %s\nsha256: %s" % (path, size, sha)
        else:
            text = "⚠️ Бэкап создан, но отправить файлом не удалось (%s).\nФайл на сервере: %s (%s)\nsha256: %s" % (
                r.get("error") or r.get("description") or "ошибка API", path, size, sha)
    if mid:
        r2 = edit(text, mid, kbd(BACK_HOME))
        if not r2.get("ok"):
            send(text, kbd(BACK_HOME))
    else:
        send(text, kbd(BACK_HOME))


EXT_PROGRESS = "/tmp/.tg-ext-check-progress"


def do_external_check_all():
    """Внешняя проверка ВСЕХ инбаундов сразу — делает ext-check.sh all --tg
    (единый источник «терминал = HTML = Telegram»). Заглушка редактируется
    в готовую сводку; по пути каждые ~12 с показываем прогресс (проценты)."""
    m = send("🌍 Внешняя проверка доступности инбаундов\n⏳ Проверяю всё сразу из разных стран (обычно 30–90 с)...")
    mid = (m.get("result") or {}).get("message_id")
    try:
        os.remove(EXT_PROGRESS)
    except OSError:
        pass
    env = dict(os.environ, EXTCHECK_PROGRESS=EXT_PROGRESS)
    text = ""
    try:
        p = subprocess.Popen(["bash", SCRIPTS + "/ext-check.sh", "all", "--tg"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, env=env)
        deadline = time.time() + 280
        last_edit = time.time()
        last_line = ""
        while p.poll() is None:
            time.sleep(3)
            if time.time() > deadline:
                p.kill()
                text = "❌ Внешняя проверка не завершилась за 280 с — прервана.\nПовторите кнопку «🌍» позже."
                break
            if mid and time.time() - last_edit >= 12:
                try:
                    with open(EXT_PROGRESS, encoding="utf-8") as f:
                        lines = [l for l in f.read().splitlines() if "|" in l]
                    if lines:
                        pct, _, what = lines[-1].partition("|")
                        line = "⏳ %s%% — %s" % (pct.strip(), what.strip())
                        if line != last_line:
                            last_line = line
                            edit("🌍 Внешняя проверка доступности инбаундов\n%s" % line, mid)
                            last_edit = time.time()
                except Exception:
                    pass
        if not text:
            text = (p.stdout.read() or "").strip()
    except Exception as e:
        text = "❌ Внешняя проверка не удалась: %r" % e
    if not text:
        text = ("❌ ext-check.sh вернул пусто. Выполните в терминале: "
                "bash %s/ext-check.sh all" % SCRIPTS)
    if mid:
        r = edit(text, mid, kbd((btn("🌍 Проверить ещё раз", "xc:all"),), BACK_HOME))
        if not r.get("ok"):
            send(text, kbd(BACK_HOME))
    else:
        send(text, kbd(BACK_HOME))


def wal_state():
    if not os.path.exists(WALLOG):
        return ("⚠️ Лог сторожа не найден — сторож не работал?", False, "")
    last = sh("tail -1 %s" % WALLOG)
    total = sh("wc -l < %s" % WALLOG) or "?"
    anom = sh("grep -cE 'DELETED|err5m=[1-9]|wal=-' %s" % WALLOG) or "0"
    cron = sh("crontab -l 2>/dev/null | grep -c wal-watch") or "0"
    anom_int = int(anom.strip() or 0)
    txt = ("🛡 WAL-сторож — сервер %s\nCron: %s\nЗамеров: %s · Аномалии: %s\nПоследний замер:\n%s"
           % (SRVNAME, "✅ включён" if cron.strip() != "0" else "⚠️ ВЫКЛЮЧЕН", total, anom, last))
    fresh_bad = ("DELETED" in last) or bool(re.search(r"err5m=[1-9]", last)) or ("wal=-" in last)
    return (txt, anom_int > 0 or fresh_bad, last)


# ------------------------------------------------------------- клавиатуры --

def kb_main():
    return kbd(
        (btn("🔎 Диагностика сервера", "m:diag"),),
        (btn("🔃 Перезагрузка сервера", "act:reboot"),),
        (btn("🛠 Панель X-UI и Xray", "m:panel"),),
        (btn("🔌 Порты и файрвол", "m:ports"),),
        (btn("📋 Логи", "m:logs"),),
        (btn("⏱ Периодичность отчётов", "act:interval"),),
    )


def kb_diag():
    return kbd(
        (btn("📊 Отчёт о состоянии", "r:status"), btn("🛡 WAL-сторож", "m:wal")),
        (btn("📈 Ресурсы (CPU/RAM/диск)", "r:res"), btn("📌 Эталон", "m:etalon")),
        (btn("🛡 fail2ban", "r:f2b"), btn("📋 Логи", "m:logs")),
        (btn("📦 Бэкап сейчас", "bk:now"), btn("🌍 Внешняя проверка", "xc:all")),
        BACK_MAIN,
    )


def kb_wal():
    return kbd(
        (btn("🛡 Включить сторож", "wal:on"), btn("⏹ Выключить", "wal:off")),
        (btn("🌐 Полный HTML-отчёт", "r:wal"),),
        BACK_HOME,
    )


def kb_etalon():
    return kbd(
        (btn("🔍 Сравнить с эталоном", "r:etalon"),),
        (btn("💾 Создать новый эталон", "et:save"),),
        (btn("📚 Список эталонов", "et:list"),),
        BACK_HOME,
    )


def kb_panel():
    return kbd(
        (btn("📡 Статус панели и Xray", "p:status"),),
        (btn("🔄 Перезапустить панель + Xray", "p:restart"),),
        BACK_HOME,
    )


def kb_ports():
    return kbd(
        (btn("👁 Слушающие порты", "po:list"), btn("🛡 Правила UFW", "po:ufw")),
        (btn("➕ Открыть порт", "po:open"), btn("➖ Закрыть порт", "po:close")),
        BACK_HOME,
    )


def kb_logs():
    return kbd(
        (btn("За 1 час", "lg:1"), btn("За 6 часов", "lg:6"), btn("За 24 часа", "lg:24")),
        (btn("За N часов (ввести)", "lg:ask"),),
        (btn("🧹 Очистка логов journald", "lg:vac"),),
        BACK_HOME,
    )


def kb_res():
    return kbd(
        (btn("🔄 Обновить", "res:upd"), btn("⬅️ Назад", "m:diag"), btn("🏠 Главное меню", "m:home")),
    )


# --------------------------------------------------- диалоговые состояния --
STATE = {"mode": None, "until": 0, "data": {}}


def set_mode(mode, seconds=180, **data):
    STATE["mode"] = mode
    STATE["until"] = time.time() + seconds
    STATE["data"] = data


def clear_mode():
    STATE["mode"] = None
    STATE["data"] = {}


def mode_expired():
    if STATE["mode"] and time.time() > STATE["until"]:
        clear_mode()
        send("⌛ Время ввода истекло, действие отменено.", kbd(BACK_MAIN))


# ------------------------------------------------------------- действия ---

def do_resources(msg_id=None):
    text = resources_text()
    if msg_id:
        edit(text, msg_id, kb_res())
    else:
        send(text, kb_res())


def do_wal():
    text, _a, _l = wal_state()
    send(text, kb_wal())


def do_panel_status():
    act = sh("systemctl is-active x-ui")
    xver = sh("/usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1")
    ports = sh("ss -tulnp 2>/dev/null | grep -E 'nginx|x-ui|xray' | awk '{print $1, $5}' | sort -u | head -20")
    up = sh("systemctl show x-ui -p ActiveEnterTimestamp --value")
    send("🛠 Панель и Xray — сервер %s\n\nx-ui: %s (запущена: %s)\n%s\n\nСлушают:\n%s"
         % (SRVNAME, act, up.strip(), xver, ports), kb_panel())


def do_panel_restart():
    send("🔄 Перезапускаю панель + Xray...")
    sh("systemctl restart x-ui && sleep 3")
    send("Готово: x-ui = %s" % sh("systemctl is-active x-ui"), kb_panel())


def do_reboot_ask():
    set_mode("reboot_yes", 120)
    send("⚠️ ПЕРЕЗАГРУЗКА сервера %s!\nVPN прервётся на 1–3 минуты, клиенты переподключатся.\n\n"
         "Для подтверждения отправьте текстом: yes (2 минуты на ввод)" % SRVNAME)


def do_reboot():
    clear_mode()
    try:
        with open(REBOOT_MARKER, "w") as f:
            f.write(str(time.time()))
    except Exception:
        pass
    send("🔃 Сервер перезагружается... После загрузки пришлю подтверждение.")
    sh("nohup bash -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &")


def do_interval_ask():
    set_mode("interval", 180)
    send("⏱ Сейчас регулярные отчёты приходят каждые %d ч.\nВведите новое количество часов (число от 1 до 168):" % INTERVAL)


def save_interval(val):
    global INTERVAL
    INTERVAL = val
    set_env_key("REPORT_INTERVAL_HOURS", str(val))
    clear_mode()
    send("✅ Регулярные отчёты: каждые %d ч." % val, kb_main())


# --------------------------------------------------- обработка обновлений --

def auth_ok(user_id):
    return CHAT_INT is not None and user_id == CHAT_INT


def handle_callback(q):
    if not auth_ok(q.get("from", {}).get("id")):
        tg("answerCallbackQuery", callback_query_id=q["id"], text="Нет доступа")
        return
    data = q.get("data", "")
    msg_id = q.get("message", {}).get("message_id")
    tg("answerCallbackQuery", callback_query_id=q["id"])

    if data == "m:home":
        edit("🏠 Главное меню — сервер %s\n\nВыберите раздел:" % SRVNAME, msg_id, kb_main())
    elif data in ("m:diag", "m:back"):
        edit("🔎 Диагностика сервера %s:" % SRVNAME, msg_id, kb_diag())
    elif data == "m:wal":
        text, _a, _l = wal_state()
        edit(text, msg_id, kb_wal())
    elif data == "m:etalon":
        last = sh("bash %s/baseline.sh latest" % SCRIPTS).strip()
        txt = "📌 Эталон сервера %s:\nПоследний: %s" % (SRVNAME, last if last else "нет — создайте первым")
        edit(txt, msg_id, kb_etalon())
    elif data == "m:panel":
        edit("🛠 Панель X-UI и Xray — сервер %s:" % SRVNAME, msg_id, kb_panel())
    elif data == "m:ports":
        edit("🔌 Порты и файрвол — сервер %s:" % SRVNAME, msg_id, kb_ports())
    elif data == "m:logs":
        edit("📋 Логи x-ui — выбрать период (пришлю сводку + ссылку на полный отчёт):", msg_id, kb_logs())
    elif data == "xc:all":
        do_external_check_all()
    elif data == "r:status":
        report_via_sh("status")
    elif data == "r:res":
        do_resources()
    elif data == "res:upd":
        do_resources(msg_id)
    elif data == "r:wal":
        report_via_sh("wal")
    elif data == "r:etalon":
        report_via_sh("etalon")
    elif data == "r:f2b":
        report_via_sh("fail2ban")
    elif data == "bk:now":
        do_backup(daily=False)
    elif data == "et:save":
        out = sh("bash %s/baseline.sh save" % SCRIPTS) or "✅ Новый эталон создан"
        send(out, kb_etalon())
    elif data == "et:list":
        out = sh("bash %s/baseline.sh list" % SCRIPTS) or "Эталонов ещё нет."
        if len(out) > 3500:
            out = out[:3500] + "\n… (список обрезан)"
        send(out, kb_etalon())
    elif data == "act:reboot":
        do_reboot_ask()
    elif data == "act:interval":
        do_interval_ask()
    elif data == "p:status":
        do_panel_status()
    elif data == "p:restart":
        set_mode("panel_restart_yes", 120)
        send("⚠️ Перезапустить панель x-ui вместе с Xray на сервере %s?\n"
             "Соединения клиентов прервутся на несколько секунд.\nОтправьте: yes" % SRVNAME)
    elif data == "po:list":
        out = sh("ss -tulnp 2>/dev/null | grep -E 'nginx|x-ui|xray' | awk '{print $1, $2, $5, $7}' | sort -u")
        send("🔌 Слушающие порты — сервер %s\n\n%s" % (SRVNAME, out[:3500] or "пусто"), kb_ports())
    elif data == "po:ufw":
        send("🛡 UFW — сервер %s\n\n%s" % (SRVNAME, sh("ufw status verbose 2>/dev/null || echo 'ufw не установлен/не активен'")[:3500]), kb_ports())
    elif data == "po:open":
        set_mode("po_open", 180)
        send("➕ Открыть порт. Введите одной строкой:\nПОРТ ПРОТОКОЛ КОММЕНТАРИЙ\nнапример: 8443 tcp reality")
    elif data == "po:close":
        rules = sh("ufw status numbered 2>/dev/null | head -30")
        set_mode("po_close", 180)
        send("➖ Закрыть порт. Текущие правила:\n%s\n\nВведите НОМЕР правила для удаления:" % (rules or "правил нет"))
    elif data.startswith("lg:"):
        arg = data.split(":", 1)[1]
        if arg == "ask":
            set_mode("logs_hours", 180)
            send("Введите количество часов для отчёта логов (число, например 12):")
        elif arg == "vac":
            set_mode("vac_days", 180)
            send("🧹 Очистка логов journald (затронет ВСЕ системные логи).\nСколько ДНЕЙ логов оставить? (число, например 7):")
        else:
            try:
                report_via_sh("logs %d" % int(arg))
            except ValueError:
                pass


def handle_text(msg):
    if not auth_ok(msg.get("from", {}).get("id")):
        log("игнорирую сообщение от чужого chat_id: %s" % msg.get("chat", {}).get("id"))
        return
    text = (msg.get("text") or "").strip()
    mode_expired()
    mode = STATE["mode"]

    if text in ("/start", "start", "меню"):
        clear_mode()
        send("🏠 Главное меню — сервер %s (%s)\n\nВыберите раздел:" % (SRVNAME, sh("hostname")), kb_main())
        return
    if text in ("статус", "отчет", "отчёт", "status"):
        report_via_sh("status")
        return
    if text == "бэкап":
        do_backup(daily=False)
        return

    if mode == "reboot_yes":
        if text.lower() == "yes":
            do_reboot()
        else:
            clear_mode()
            send("Перезагрузка отменена.", kbd(BACK_MAIN))
        return
    if mode == "panel_restart_yes":
        if text.lower() == "yes":
            clear_mode()
            do_panel_restart()
        else:
            clear_mode()
            send("Перезапуск отменён.", kb_panel())
        return
    if mode == "logs_hours":
        if re.fullmatch(r"\d{1,4}", text) and 1 <= int(text) <= 720:
            clear_mode()
            report_via_sh("logs %d" % int(text))
        else:
            send("Нужно число часов от 1 до 720. Попробуйте ещё раз:")
        return
    if mode == "vac_days":
        if re.fullmatch(r"\d{1,4}", text):
            out = sh("journalctl --vacuum-time=%sd 2>&1 | tail -2" % text)
            clear_mode()
            send("🧹 Очистка выполнена (оставили %s дн.):\n%s\nНовый размер: %s"
                 % (text, out, sh("journalctl --disk-usage")), kb_logs())
        else:
            send("Нужно число дней. Попробуйте ещё раз:")
        return
    if mode == "interval":
        if re.fullmatch(r"\d{1,3}", text) and 1 <= int(text) <= 168:
            save_interval(int(text))
        else:
            send("Нужно число от 1 до 168. Попробуйте ещё раз:")
        return
    if mode == "po_open":
        parts = text.split(None, 2)
        if len(parts) >= 2 and re.fullmatch(r"\d{1,5}", parts[0]) and parts[1] in ("tcp", "udp"):
            port, proto = parts[0], parts[1]
            comment = re.sub(r"[^A-Za-z0-9 _.-]", "", parts[2] if len(parts) > 2 else "tg-bot")[:40]
            set_mode("po_open_yes", 120, cmd="ufw allow %s/%s comment '%s' && ufw reload" % (port, proto, comment))
            send("Будет выполнено:\n  ufw allow %s/%s comment '%s'\n  ufw reload\n\nОтправьте yes для подтверждения:" % (port, proto, comment))
        else:
            send("Формат: ПОРТ ПРОТОКОЛ КОММЕНТАРИЙ (например: 8443 tcp reality). Ещё раз:")
        return
    if mode == "po_open_yes":
        if text.lower() == "yes":
            out = sh(STATE["data"].get("cmd", ""))
            send("✅ Выполнено.\n%s\n\n%s" % (out or "", sh("ufw status | tail -5")), kb_ports())
        else:
            send("Отменено.", kb_ports())
        clear_mode()
        return
    if mode == "po_close":
        if re.fullmatch(r"\d{1,3}", text):
            rule = sh("ufw status numbered | grep -E '^\\[ *%s\\]'" % text)
            warn = "\n⚠️ ВНИМАНИЕ: правило похоже на SSH (22/tcp) — можно потерять доступ!\n" if "22/tcp" in rule else ""
            set_mode("po_close_yes", 120, num=text)
            send("Будет удалено правило:\n%s\n%s\nОтправьте yes для подтверждения:" % (rule or "(не найдено)", warn))
        else:
            send("Нужен номер правила (число). Ещё раз:")
        return
    if mode == "po_close_yes":
        if text.lower() == "yes":
            num = STATE["data"].get("num", "")
            send("✅ Правило %s удалено.\n%s" % (num, sh("ufw --force delete %s && ufw reload" % num) or ""), kb_ports())
        else:
            send("Отменено.", kb_ports())
        clear_mode()
        return

    send("Я понимаю кнопки меню, а также команды:\n/start — меню\n«статус» — отчёт о состоянии\n«бэкап» — создать и прислать бэкап", kbd(BACK_MAIN))


# ------------------------------------------------- фоновые проверки -------

def wal_watch_check(prev):
    if not os.path.exists(WALLOG):
        return prev
    last = sh("tail -1 %s" % WALLOG)
    if not last:
        return prev
    bad = ("DELETED" in last) or bool(re.search(r"err5m=[1-9]", last)) or ("wal=-" in last)
    if bad and not prev:
        send("🔴🔴 АВАРИЯ: WAL-сторож обнаружил проблему на сервере %s!\n%s\n\nСрочно проверьте панель (вероятно повреждение БД)." % (SRVNAME, last))
    elif (not bad) and prev:
        send("🟢 Отбой: WAL-сторож снова в норме (сервер %s).\n%s" % (SRVNAME, last))
    return bad


def daily_alive():
    total = sh("wc -l < %s 2>/dev/null" % WALLOG) or "0"
    anom = sh("grep -cE 'DELETED|err5m=[1-9]|wal=-' %s 2>/dev/null" % WALLOG) or "0"
    send("🟢 Контрольное «жив» — сервер %s\nСторож: замеров %s, аномалий %s\nПанель: %s · Аптайм: %s"
         % (SRVNAME, total.strip(), anom.strip(), sh("systemctl is-active x-ui"), sh("uptime -p | sed 's/up //'")))


def next_daily_epoch(hour_utc, minute_utc):
    now = datetime.datetime.utcnow()
    t = now.replace(hour=hour_utc, minute=minute_utc, second=0, microsecond=0)
    if now >= t:
        t += datetime.timedelta(days=1)
    return (t - datetime.datetime(1970, 1, 1)).total_seconds()


# ---------------------------------------------------------------- main ----

def main():
    global INTERVAL
    if ENV.get("TG_ENABLED", "1") != "1":
        log("TG_ENABLED != 1 — бот выключен настройкой. Выход.")
        sys.exit(0)
    if not TOKEN or CHAT_INT is None:
        log("В %s нет BOT_TOKEN или CHAT_ID — заполните файл. Выход." % ENVF)
        sys.exit(1)

    me = tg("getMe")
    if not me.get("ok"):
        log("getMe не прошёл — проверьте BOT_TOKEN. Выход.")
        sys.exit(1)
    log("Бот запущен: @%s, сервер %s, интервал отчётов %d ч" % (me["result"].get("username"), SRVNAME, INTERVAL))

    if os.path.exists(REBOOT_MARKER):
        try:
            os.remove(REBOOT_MARKER)
        except Exception:
            pass
        send("🟢 Сервер %s ПЕРЕЗАГРУЖЕН (по команде из бота) и снова работает.\nАптайм: %s · Панель: %s"
             % (SRVNAME, sh("uptime -p | sed 's/up //'"), sh("systemctl is-active x-ui")))
    else:
        send("🟢 Бот диагностики v0.3.1 запущен — сервер %s.\nНажмите /start для меню." % SRVNAME)

    offset = 0
    next_report = time.time() + INTERVAL * 3600
    next_alive = next_daily_epoch(6, 0)     # 09:00 МСК
    next_backup = next_daily_epoch(6, 5)    # 09:05 МСК
    wal_bad = False
    last_wal_check = 0.0
    last_interval_seen = INTERVAL

    while True:
        try:
            r = tg("getUpdates", offset=offset, timeout=25,
                   allowed_updates=["message", "callback_query"])
            for u in r.get("result", []):
                offset = u["update_id"] + 1
                try:
                    if "callback_query" in u:
                        handle_callback(u["callback_query"])
                    elif "message" in u:
                        handle_text(u["message"])
                except Exception as e:
                    log("ошибка обработки: %r" % e)
                    try:
                        send("⚠️ Ошибка при обработке команды: %r" % e)
                    except Exception:
                        pass
        except Exception as e:
            log("ошибка getUpdates: %r" % e)
            time.sleep(5)

        now = time.time()

        env_now = load_env()
        try:
            iv = max(1, min(168, int(env_now.get("REPORT_INTERVAL_HOURS", INTERVAL))))
        except ValueError:
            iv = INTERVAL
        if iv != last_interval_seen:
            INTERVAL = iv
            last_interval_seen = iv
            next_report = now + INTERVAL * 3600
            log("интервал отчётов изменён на %d ч" % INTERVAL)

        if now - last_wal_check >= 60:
            last_wal_check = now
            try:
                wal_bad = wal_watch_check(wal_bad)
            except Exception as e:
                log("wal check: %r" % e)

        if now >= next_report:
            next_report = now + INTERVAL * 3600
            try:
                report_via_sh("status")
            except Exception as e:
                log("periodic report: %r" % e)

        if now >= next_alive:
            next_alive = next_daily_epoch(6, 0)
            try:
                daily_alive()
            except Exception as e:
                log("daily alive: %r" % e)

        if now >= next_backup:
            next_backup = next_daily_epoch(6, 5)
            try:
                do_backup(daily=True)
            except Exception as e:
                log("daily backup: %r" % e)


if __name__ == "__main__":
    main()
