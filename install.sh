#!/bin/bash
# Установка/обновление системы диагностики сервера 3x-ui-diagnostics.
# Версия 2.7 (27.09.2026)
# Новое в 2.7: репозиторий ПЕРЕИМЕНОВАН — комплект v3.3 живёт в Michael-K-cloud/
#   3x-ui-diagnostics-v2 (старый 3x-ui-diagnostics возвращается к исходному
#   состоянию 25.08.2026 по решению владельца). Все URL установки — на -v2.
#
# Способ 1 (основной): запуск из распакованного архива/папки репозитория — без сети.
# Способ 2: скачивание ВСЕГО репозитория одним tar-архивом с codeload.github.com (IPv4).
# Пофайловое скачивание с raw.githubusercontent.com НЕ используется (нестабильные IP Fastly).
#
# Новое в 2.6 (задание владельца 26.09: «оставь спиннер и добавь проценты»):
#  - спиннер [|/-\] СОХРАНЁН, рядом с ним — процент общего прогресса установки:
#    «[|]  35% — Скачивание репозитория...»; шаги: 15/35/55/70/85/100%.
# Новое в 2.5:
#  - установщик СПРАШИВАЕТ: ставить ли Telegram-бота (1-да/2-нет);
#    если да — пошагово запрашивает BOT_TOKEN (с инструкцией и проверкой через getMe)
#    и CHAT_ID (с инструкцией про @myidbot), пишет /root/scripts/.env и ставит бота;
#  - если .env уже заполнен — бот просто обновляется/перезапускается без вопросов.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DIAG_VERSION="2.7"
FILES="main.sh logs.sh system_report.sh fail2ban.sh wal-watch.sh baseline.sh report.sh backup.sh ext-check.sh tg-bot.py tg-bot-install.sh tg-diag-bot.service"
GITHUB_USER="Michael-K-cloud"
GITHUB_REPO="3x-ui-diagnostics-v2"
BRANCH="main"
TARBALL_URL="https://codeload.github.com/${GITHUB_USER}/${GITHUB_REPO}/tar.gz/refs/heads/${BRANCH}"

SPIN_PID=""
STEP_PCT=0
spin_start() {   # $1 = текст; процент берётся из STEP_PCT (ставить ДО вызова)
  ( s='|/-\'; i=0; while :; do printf "\r  ${YELLOW}[%s]${NC} %3d%% — %s" "${s:i++%${#s}:1}" "$STEP_PCT" "$1"; sleep 0.15; done ) &
  SPIN_PID=$!
}
spin_stop() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null; fi
  printf "\r\033[K"
  SPIN_PID=""
}

echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  Установка системы диагностики сервера${NC}"
echo -e "${GREEN}  (install.sh v${DIAG_VERSION})${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""

# 1. root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ Пожалуйста, запустите скрипт от имени root (sudo su)${NC}"
  exit 1
fi

# 2. Зависимости (со спиннером)
STEP_PCT=15
spin_start "Установка зависимостей (sqlite3, sysstat)..."
( apt update -qq && apt install sqlite3 sysstat -y -qq ) >/dev/null 2>&1
APT_OK=$?
spin_stop
if [ "$APT_OK" = "0" ]; then
  echo -e "  ${GREEN}✅ Зависимости установлены${NC}"
else
  echo -e "  ${RED}⚠️ Не удалось установить зависимости, продолжаем...${NC}"
fi

# 3. Директория
mkdir -p /root/scripts

# 4. Источник файлов
SRC=""
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -n "$SRC_DIR" ]; then
  OK=1
  for f in $FILES; do [ -s "$SRC_DIR/$f" ] || OK=0; done
  if [ "$OK" = "1" ]; then
    SRC="$SRC_DIR"
    echo -e "  ${GREEN}✅ Найден локальный комплект файлов ($SRC_DIR) — установка без сети${NC}"
  fi
fi

if [ -z "$SRC" ]; then
  STEP_PCT=35
  spin_start "Скачивание репозитория одним архивом (codeload.github.com, IPv4)..."
  TMPD=$(mktemp -d)
  wget --inet4-only --timeout=30 --tries=3 -qO "$TMPD/repo.tar.gz" "$TARBALL_URL"
  WGET_OK=$?
  spin_stop
  if [ "$WGET_OK" = "0" ] && tar -xzf "$TMPD/repo.tar.gz" -C "$TMPD" 2>/dev/null; then
    EXDIR=$(find "$TMPD" -maxdepth 1 -type d -name "${GITHUB_REPO}-*" | head -1)
    OK=1
    for f in $FILES; do [ -n "$EXDIR" ] && [ -s "$EXDIR/$f" ] || OK=0; done
    if [ "$OK" = "1" ]; then
      SRC="$EXDIR"
      echo -e "  ${GREEN}✅ Архив скачан и распакован${NC}"
    else
      echo -e "  ${RED}❌ В архиве не хватает файлов${NC}"
    fi
  else
    echo -e "  ${RED}❌ Не удалось скачать архив с codeload.github.com${NC}"
  fi
fi

if [ -z "$SRC" ]; then
  echo -e "${RED}❌ Установка прервана: нет источника файлов. Существующие файлы в /root/scripts НЕ тронуты.${NC}"
  exit 1
fi

# 5. Копирование (только после проверки источника)
STEP_PCT=55
spin_start "Копирование файлов в /root/scripts..."
for f in $FILES; do cp -f "$SRC/$f" "/root/scripts/$f"; done
spin_stop

# 6. Контроль непустоты
FAIL=0
for f in $FILES; do
  if [ ! -s "/root/scripts/$f" ]; then
    echo -e "  ${RED}❌ Файл /root/scripts/$f пуст или не скопирован${NC}"
    FAIL=1
  fi
done
if [ "$FAIL" = "1" ]; then
  echo -e "${RED}❌ Установка прервана: повторите установку.${NC}"
  exit 1
fi
echo -e "  ${GREEN}✅ 70% — все файлы установлены и проверены${NC}"

# 7. Права и команда menu
chmod +x /root/scripts/*.sh
ln -sf /root/scripts/main.sh /usr/local/bin/menu

# 8. Telegram-бот: вопрос или автообновление
ENVF=/root/scripts/.env
BOT_CONFIGURED=0
if [ -f "$ENVF" ] && grep -q '^BOT_TOKEN=..' "$ENVF" && grep -q '^CHAT_ID=..' "$ENVF" && ! grep -q 'СЮДА_' "$ENVF"; then
  BOT_CONFIGURED=1
fi

echo ""
if [ "$BOT_CONFIGURED" = "1" ]; then
  echo -e "${GREEN}🤖 85% — Telegram-бот уже настроен (.env заполнен): обновляю и перезапускаю...${NC}"
  bash /root/scripts/tg-bot-install.sh
else
  echo "🤖 Установить Telegram БОТа?"
  echo -e "   ${GREEN}1${NC} - да    ${GREEN}2${NC} - нет"
  read -p "Ваш выбор [по умолчанию 2]: " bot_ans
  bot_ans=${bot_ans:-2}
  if [ "$bot_ans" = "1" ]; then
    touch "$ENVF"; chmod 600 "$ENVF"
    TOKEN_OK=""
    for try in 1 2; do
      echo ""
      echo "── Как получить BOT_TOKEN ────────────────────────────"
      echo "  1) В Telegram найдите бота @BotFather и отправьте ему: /newbot"
      echo "  2) Введите имя бота (любое), например: Tunless Diag"
      echo "  3) Введите username бота — ОБЯЗАТЕЛЬНО заканчивается на «bot»,"
      echo "     например: tunless_diag_fi_bot"
      echo "  4) BotFather пришлёт токен вида 1234567890:AAE... — скопируйте его"
      echo "──────────────────────────────────────────────────────"
      read -rsp "Вставьте BOT_TOKEN (ввод не отображается): " tk; echo ""
      if [ -n "$tk" ] && wget --inet4-only --timeout=15 -qO- "https://api.telegram.org/bot${tk}/getMe" 2>/dev/null | grep -q '"ok":true'; then
        TOKEN_OK="$tk"
        echo -e "  ${GREEN}✅ Токен проверен (getMe ok)${NC}"
        break
      else
        echo -e "  ${RED}❌ Токен не прошёл проверку. Скопируйте его целиком и попробуйте ещё раз.${NC}"
      fi
    done
    if [ -z "$TOKEN_OK" ]; then
      echo -e "${RED}Бот НЕ установлен. Позже: заполните $ENVF и выполните bash /root/scripts/tg-bot-install.sh${NC}"
    else
      echo ""
      echo "── Как узнать свой CHAT_ID ───────────────────────────"
      echo "  1) В Telegram найдите бота @myidbot и нажмите Start"
      echo "  2) Он ответит вашим id — число, например 123456789"
      echo "     (для группы: добавьте @myidbot в группу — id группы отрицательное число)"
      echo "──────────────────────────────────────────────────────"
      read -p "Вставьте CHAT_ID: " cid
      if echo "$cid" | grep -qE '^-?[0-9]+$'; then
        # перезаписываем .env, сохраняя REPORT_PATH и существующие настройки
        grep -v -E '^(BOT_TOKEN|CHAT_ID|REPORT_INTERVAL_HOURS|SERVER_NAME|TG_ENABLED)=' "$ENVF" > "$ENVF.tmp" 2>/dev/null
        {
          cat "$ENVF.tmp" 2>/dev/null
          echo "BOT_TOKEN=$TOKEN_OK"
          echo "CHAT_ID=$cid"
          grep -q '^REPORT_INTERVAL_HOURS=' "$ENVF.tmp" 2>/dev/null || echo "REPORT_INTERVAL_HOURS=6"
          grep -q '^SERVER_NAME=' "$ENVF.tmp" 2>/dev/null || echo "SERVER_NAME=$(hostname -s)"
          grep -q '^TG_ENABLED=' "$ENVF.tmp" 2>/dev/null || echo "TG_ENABLED=1"
        } > "$ENVF"
        rm -f "$ENVF.tmp"
        chmod 600 "$ENVF"
        echo -e "  ${GREEN}✅ .env заполнен${NC}"
        echo -e "${GREEN}🤖 85% — устанавливаю и запускаю Telegram-бота...${NC}"
        bash /root/scripts/tg-bot-install.sh
      else
        echo -e "${RED}❌ CHAT_ID должен быть числом. Допишите его вручную в $ENVF (строка CHAT_ID=...)${NC}"
        echo -e "   и запустите: bash /root/scripts/tg-bot-install.sh"
      fi
    fi
  else
    echo -e "${YELLOW}ℹ️ Бот не установлен. Когда решите поставить — повторный запуск install.sh снова${NC}"
    echo -e "${YELLOW}   задаст этот вопрос; либо заполните $ENVF вручную и выполните bash /root/scripts/tg-bot-install.sh${NC}"
  fi
fi

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  ✅ 100% — Установка успешно завершена!${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo "Контрольные суммы установленных файлов:"
sha256sum /root/scripts/*.sh /root/scripts/tg-bot.py 2>/dev/null
echo ""
echo "Запуск меню:"
echo -e "${YELLOW}  menu${NC}"
echo ""
echo "WAL-сторож устанавливается, но НЕ включается автоматически. Включить:"
echo -e "${YELLOW}  menu → 1 (Диагностика) → 2 (WAL-сторож) → 3 (Включить)${NC}"
echo ""
echo "HTML-отчёты по ссылкам: menu → 1 → 5 (nginx править НЕ нужно — отчёты"
echo "публикуются в каталог сайта-заглушки)."
echo ""
echo "Повторный запуск install.sh = безопасное обновление скриптов"
echo "(cron, лог сторожа, .env и эталон не затрагиваются; бот перезапускается)."
echo ""
