#!/bin/bash
export TZ='Europe/Moscow'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; PINK='\033[95m'; WHITE='\033[0;37m'; NC='\033[0m'
DIR="/root/scripts"
pause() { echo ""; read -p "Нажмите Enter для возврата..."; }

menu_panel() {
  while true; do
    clear
    echo -e "${PINK}==========================================${NC}"
    echo -e "${PINK}  УПРАВЛЕНИЕ ПАНЕЛЬЮ X-UI И XRAY${NC}"
    echo -e "${PINK}==========================================${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 🔄 Перезапуск панели x-ui (перезапускает сервис панели + Xray)"
    echo -e "  ${GREEN}2.${NC} 📡 Статус Xray (состояние панели, Xray, слушаемые порты)"
    echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
    echo ""
    echo -e "${WHITE}==========================================${NC}"
    echo -e "${WHITE}  ОТЧЕТ О СОСТОЯНИИ X-UI И XRAY${NC}"
    echo -e "${WHITE}==========================================${NC}"
    echo ""
    echo -e "${WHITE}=== Статус x-ui ===${NC}"
    if systemctl is-active --quiet x-ui; then
        echo -e "${GREEN}✅ активен${NC}"
    else
        echo -e "${RED}❌ не активен${NC}"
    fi
    echo ""
    echo -e "${WHITE}=== Процесс Xray ===${NC}"
    ps aux | grep -v grep | grep xray | awk '{print "PID:", $2, "| запущен в:", $9}' || echo "Xray не запущен"
    echo ""
    echo -e "${WHITE}=== Сокеты в /dev/shm ===${NC}"
    ls -la /dev/shm/uds*.sock 2>/dev/null || echo "сокетов нет"
    echo ""
    echo -e "${WHITE}=== Ошибки за последний час ===${NC}"
    ERROR_COUNT=$(journalctl -u x-ui --since "1 hour ago" --no-pager | grep -c "ERROR")
    echo "$ERROR_COUNT"
    echo ""
    read -p "  Ваш выбор: " c
    case $c in
      1)
        echo ""
        read -p "Перезапустить панель x-ui? (Enter = yes, или введите no): " ans
        ans=${ans:-yes}
        if [ "$ans" = "yes" ]; then
          systemctl restart x-ui
          sleep 2
          systemctl is-active --quiet x-ui && echo -e "${GREEN}✅ Панель перезапущена${NC}" || echo -e "${RED}❌ Ошибка перезапуска${NC}"
          echo ""
          echo -e "${WHITE}=== Статус после перезапуска ===${NC}"
          if systemctl is-active --quiet x-ui; then PANEL_STATE="${GREEN}Running${NC}"; else PANEL_STATE="${RED}Stopped${NC}"; fi
          if pgrep -f xray >/dev/null 2>&1; then XRAY_STATE="${GREEN}Running${NC}"; else XRAY_STATE="${RED}Stopped${NC}"; fi
          echo -e "Panel state: $PANEL_STATE"
          echo -e "xray state: $XRAY_STATE"
        else
          echo "Перезапуск отменен"
        fi
        pause;;
      2)
        echo ""
        if systemctl is-active --quiet x-ui; then PANEL_STATE="${GREEN}Running${NC}"; else PANEL_STATE="${RED}Stopped${NC}"; fi
        if systemctl is-enabled --quiet x-ui 2>/dev/null; then AUTOSTART="${GREEN}Yes${NC}"; else AUTOSTART="${RED}No${NC}"; fi
        if pgrep -f xray >/dev/null 2>&1; then XRAY_STATE="${GREEN}Running${NC}"; else XRAY_STATE="${RED}Stopped${NC}"; fi
        echo -e "Panel state: $PANEL_STATE"
        echo -e "Start automatically: $AUTOSTART"
        echo -e "xray state: $XRAY_STATE"
        echo ""
        echo -e "${WHITE}=== Процесс Xray ===${NC}"
        ps aux | grep -v grep | grep xray || echo -e "${RED}Xray не запущен${NC}"
        echo ""
        echo -e "${WHITE}=== Порты, которые слушает Xray ===${NC}"
        ss -tulpn 2>/dev/null | grep xray || echo "Порты не найдены"
        pause;;
      0|""|" ") return;;
    esac
  done
}

menu_ports() {
  while true; do
    clear
    echo -e "${PINK}==========================================${NC}"
    echo -e "${PINK}  УПРАВЛЕНИЕ ПОРТАМИ${NC}"
    echo -e "${PINK}==========================================${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 🔌 Проверка открытых портов (правила ufw и слушаемые порты)"
    echo -e "  ${GREEN}2.${NC} ➕ Открыть порт (разрешить порт в файрволе)"
    echo -e "  ${GREEN}3.${NC} ➖ Закрыть порт (запретить порт в файрволе)"
    echo -e "  ${GREEN}4.${NC} 🔁 Перезапуск файрвола (применить изменения ufw)"
    echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
    echo ""
    read -p "  Ваш выбор: " c
    case $c in
      1)
        echo ""
        echo -e "${WHITE}=== Правила файрвола (ufw) ===${NC}"
        ufw status
        echo ""
        echo -e "${WHITE}=== Реально слушающие порты ===${NC}"
        ss -tulpn | grep LISTEN
        pause;;
      2)
        echo ""
        read -p "Введите номер порта: " port
        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
          echo -e "${RED}❌ Порт должен быть числом${NC}"; pause; continue
        fi
        read -p "Протокол (tcp/udp) [tcp по умолчанию]: " proto
        if [ -z "$proto" ]; then
          proto="tcp"
          echo -e "${YELLOW}Используется протокол по умолчанию: tcp${NC}"
        fi
        read -p "Название порта (комментарий): " name
        ufw allow $port/$proto comment "$name"
        ufw reload
        echo -e "${GREEN}✅ Порт $port/$proto открыт${NC}"
        pause;;
      3)
        echo ""
        echo -e "${WHITE}=== Текущие правила (с номерами) ===${NC}"
        ufw status numbered
        echo ""
        read -p "Введите номер правила для удаления: " num
        if [[ "$num" =~ ^[0-9]+$ ]]; then
          RULE=$(ufw status numbered | grep "^\[ *$num\]")
          echo -e "${YELLOW}Будет удалено: $RULE${NC}"
          if echo "$RULE" | grep -q "22/tcp"; then
            echo -e "${RED}⚠️ ВНИМАНИЕ: это SSH порт! Вы потеряете доступ к серверу!${NC}"
            read -p "Точно удалить? (yes/no): " ssh_ans
            if [ "$ssh_ans" != "yes" ]; then echo "Отменено"; pause; continue; fi
          fi
          read -p "Подтвердить удаление? (yes/no): " del_ans
          if [ "$del_ans" = "yes" ]; then
            ufw --force delete $num
            ufw reload
            echo -e "${GREEN}✅ Правило удалено${NC}"
          else
            echo "Отменено"
          fi
        else
          echo -e "${RED}❌ Введите номер правила${NC}"
        fi
        pause;;
      4)
        echo ""
        ufw reload
        echo -e "${GREEN}✅ Файрвол перезапущен${NC}"
        pause;;
      0|""|" ") return;;
    esac
  done
}

ww_find_script() {
  WW=""
  for p in "$DIR/wal-watch.sh" /root/wal-watch.sh; do
    [ -f "$p" ] && WW="$p" && break
  done
}

ww_header() {
  ww_find_script
  CRON=$(crontab -l 2>/dev/null | grep wal-watch | head -1)
  LOG=/root/wal-watch.log
  echo -e "${WHITE}=== Статус ===${NC}"
  if [ -n "$WW" ]; then echo -e "Скрипт: ${GREEN}есть${NC} ($WW)"; else echo -e "Скрипт: ${RED}нет${NC} (запустите install.sh из репозитория)"; fi
  if [ -n "$CRON" ]; then echo -e "Cron:   ${GREEN}включён${NC} ($CRON)"; else echo -e "Cron:   ${YELLOW}выключен${NC}"; fi
  if [ -f "$LOG" ]; then
    LINES=$(wc -l < "$LOG")
    ANOM=$(grep -cE "DELETED|err5m=[1-9]|wal=-" "$LOG")
    if [ "$ANOM" = "0" ]; then
      echo -e "Лог:    $LINES замеров, аномалии: ${GREEN}0${NC}"
    else
      echo -e "Лог:    $LINES замеров, аномалии: ${RED}$ANOM${NC}"
    fi
    echo -e "${WHITE}=== Последний замер ===${NC}"
    tail -1 "$LOG"
  else
    echo -e "Лог:    ещё не создан"
  fi
}

ww_enable() {
  ww_find_script
  if [ -z "$WW" ]; then
    echo -e "${RED}❌ Скрипт сторожа не найден. Запустите install.sh из репозитория 3x-ui-diagnostics.${NC}"
    return 1
  fi
  chmod +x "$WW"
  ( crontab -l 2>/dev/null | grep -v 'wal-watch.sh' ; echo "*/5 * * * * $WW" ) | crontab -
  "$WW"
  echo -e "${GREEN}✅ Сторож включён.${NC}"
  echo -e "Строка cron: $(crontab -l | grep wal-watch)"
  echo -e "Первый замер: $(tail -1 /root/wal-watch.log)"
}

menu_walwatch() {
  while true; do
    clear
    echo -e "${PINK}==========================================${NC}"
    echo -e "${PINK}  WAL-СТОРОЖ (контроль базы данных x-ui)${NC}"
    echo -e "${PINK}==========================================${NC}"
    echo ""
    ww_header
    echo ""
    echo -e "  ${GREEN}1.${NC} 📊 Статус (подробно: скрипт, cron, лог, последние 10 замеров)"
    echo -e "  ${GREEN}2.${NC} 📋 Лог (последние 30 строк)"
    echo -e "  ${GREEN}3.${NC} ▶️  Включить (cron каждые 5 минут + первый замер)"
    echo -e "  ${GREEN}4.${NC} ⏹  Выключить (убрать из cron, лог сохранится)"
    echo -e "  ${GREEN}5.${NC} 🔄 Перезапустить (перезаписать cron-строку + замер сейчас)"
    echo -e "  ${GREEN}6.${NC} 🌐 HTML-отчёт по сторожу (ссылка)"
    echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
    echo ""
    read -p "  Ваш выбор: " c
    case $c in
      1)
        echo ""
        ww_find_script
        if [ -n "$WW" ]; then echo "Скрипт: $WW"; sha256sum "$WW"; else echo "Скрипт не найден"; fi
        echo "Cron: $(crontab -l 2>/dev/null | grep wal-watch || echo 'не установлен')"
        if [ -f /root/wal-watch.log ]; then
          echo "Всего замеров: $(wc -l < /root/wal-watch.log)"
          echo "Аномалии (DELETED / err5m>0 / wal=-): $(grep -cE 'DELETED|err5m=[1-9]|wal=-' /root/wal-watch.log)"
          echo "--- Последние 10 замеров ---"
          tail -10 /root/wal-watch.log
        else
          echo "Лога ещё нет"
        fi
        pause;;
      2)
        echo ""
        if [ -f /root/wal-watch.log ]; then tail -30 /root/wal-watch.log; else echo "Лога ещё нет"; fi
        pause;;
      3)
        echo ""
        ww_enable
        pause;;
      4)
        echo ""
        if ! crontab -l 2>/dev/null | grep -q wal-watch; then
          echo "Сторож не включён в cron"
        else
          read -p "Выключить сторож? Строка cron будет удалена, лог сохранится (yes/no): " ans
          if [ "$ans" = "yes" ]; then
            crontab -l 2>/dev/null | grep -v 'wal-watch.sh' | crontab -
            echo -e "${GREEN}✅ Сторож выключен${NC}"
          else
            echo "Отменено"
          fi
        fi
        pause;;
      5)
        echo ""
        echo "Перезапуск: cron-строка перезаписывается, замер выполняется сразу."
        ww_enable
        pause;;
      6)
        echo ""
        bash $DIR/report.sh wal
        pause;;
      0|""|" ") return;;
    esac
  done
}

menu_etalon() {
  while true; do
    clear
    echo -e "${PINK}==========================================${NC}"
    echo -e "${PINK}  ЭТАЛОН СЕРВЕРА (версионные снапшоты)${NC}"
    echo -e "${PINK}==========================================${NC}"
    echo ""
    LAST=$(bash $DIR/baseline.sh latest 2>/dev/null)
    if [ -n "$LAST" ]; then
      CNT=$(ls -1 "$DIR"/etalon/etalon-*.txt 2>/dev/null | wc -l)
      echo -e "Последний эталон: ${GREEN}$LAST${NC} (всего в истории: $CNT)"
    else
      echo -e "Сохранённых эталонов: ${YELLOW}нет${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}1.${NC} 📄 Показать последний эталон"
    echo -e "  ${GREEN}2.${NC} 💾 Создать новый эталон (старые НЕ перезаписываются)"
    echo -e "  ${GREEN}3.${NC} 📚 Список всех эталонов (история)"
    echo -e "  ${GREEN}4.${NC} 🔍 Сравнить текущее состояние с последним эталоном"
    echo -e "  ${GREEN}5.${NC} ⚖️ Сравнить два эталона между собой (по номерам)"
    echo -e "  ${GREEN}6.${NC} 📊 Показать текущий снапшот (без сохранения)"
    echo -e "  ${GREEN}7.${NC} 🌐 HTML-отчёт: сравнение с эталоном (ссылка)"
    echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
    echo ""
    read -p "  Ваш выбор: " c
    case $c in
      1) echo ""; bash $DIR/baseline.sh show; pause;;
      2) echo ""; bash $DIR/baseline.sh save; pause;;
      3) echo ""; bash $DIR/baseline.sh list; pause;;
      4) echo ""; bash $DIR/baseline.sh compare; pause;;
      5)
        echo ""
        bash $DIR/baseline.sh list
        echo ""
        read -p "  Номер ПЕРВОГО эталона (A): " na
        read -p "  Номер ВТОРОГО эталона (B): " nb
        [ -n "$na" ] && [ -n "$nb" ] && { echo ""; bash $DIR/baseline.sh compare "$na" "$nb"; }
        pause;;
      6) echo ""; bash $DIR/baseline.sh now; pause;;
      7) echo ""; bash $DIR/report.sh etalon; pause;;
      0|""|" ") return;;
    esac
  done
}

menu_report() {
  while true; do
    clear
    echo -e "${PINK}==========================================${NC}"
    echo -e "${PINK}  HTML-ОТЧЁТЫ (страница + ссылка)${NC}"
    echo -e "${PINK}==========================================${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 📊 Отчёт о состоянии сервера"
    echo -e "  ${GREEN}2.${NC} 🛡 Отчёт по WAL-сторожу"
    echo -e "  ${GREEN}3.${NC} 📌 Сравнение с эталоном"
    echo -e "  ${GREEN}4.${NC} 🛡 Отчёт по fail2ban"
    echo -e "  ${GREEN}5.${NC} 📋 Отсортированные логи за N часов"
    echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
    echo ""
    read -p "  Ваш выбор: " c
    case $c in
      1) echo ""; bash $DIR/report.sh status; pause;;
      2) echo ""; bash $DIR/report.sh wal; pause;;
      3) echo ""; bash $DIR/report.sh etalon; pause;;
      4) echo ""; bash $DIR/report.sh fail2ban; pause;;
      5)
        echo ""
        read -p "За сколько часов показать логи? (число, например 1, 6, 24; Enter = 24): " hrs
        [[ "$hrs" =~ ^[0-9]+$ ]] || hrs=24
        [ "$hrs" -eq 0 ] && hrs=24
        bash $DIR/report.sh logs "$hrs"
        pause;;
      0|""|" ") return;;
    esac
  done
}

menu_diag() {
  while true; do
    clear
    echo -e "${PINK}==========================================${NC}"
    echo -e "${PINK}  ДИАГНОСТИКА СЕРВЕРА${NC}"
    echo -e "${PINK}==========================================${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 📊 Отчет о состоянии сервера (статус панели, БД, CPU, память, диск, ошибки)"
    echo -e "  ${GREEN}2.${NC} 🛡 WAL-сторож (контроль базы x-ui каждые 5 минут: статус, лог, вкл/выкл)"
    echo -e "  ${GREEN}3.${NC} 📈 htop (диспетчер задач)"
    echo -e "  ${GREEN}4.${NC} 📌 Эталон сервера (версионные снапшоты: создать / список / сравнить)"
    echo -e "  ${GREEN}5.${NC} 🌐 HTML-отчёты (создать страницу и получить ссылку)"
    echo -e "  ${GREEN}6.${NC} 🌍 Внешняя проверка инбаундов (check-host.net: доступен ли порт извне / не блокирует ли провайдер)"
    echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
    echo ""
    read -p "  Ваш выбор: " c
    case $c in
      1) bash $DIR/system_report.sh; pause;;
      2) menu_walwatch;;
      3)
        if command -v htop >/dev/null 2>&1; then
          htop
        else
          echo ""
          echo -e "${RED}htop не установлен. Команда для установки: apt install -y htop${NC}"
          pause
        fi;;
      4) menu_etalon;;
      5) menu_report;;
      6) bash $DIR/ext-check.sh; pause;;
      0|""|" ") return;;
    esac
  done
}

while true; do
  clear
  echo -e "${PINK}==========================================${NC}"
  echo -e "${PINK}   МЕНЮ УПРАВЛЕНИЯ СЕРВЕРОМ${NC}"
  echo -e "${PINK}==========================================${NC}"
  echo ""
  echo -e "  ${GREEN}1.${NC} 🔎 Диагностика сервера (отчёт, WAL-сторож, htop, эталон, HTML-отчёты)"
  echo -e "  ${GREEN}2.${NC} 🔃 Перезагрузка сервера (полная перезагрузка VPS)"
  echo -e "  ${GREEN}3.${NC} 🛠  Управление панелью X-UI и Xray (перезапуск, статус)"
  echo -e "  ${GREEN}4.${NC} 🔌 Управление портами (проверка, открытие, закрытие, файрвол)"
  echo -e "  ${GREEN}5.${NC} 📋 Логи (просмотр / очистка)"
  echo -e "  ${GREEN}6.${NC} 🚀 Запуск меню x-ui (родное меню управления панелью)"
  echo -e "  ${GREEN}0.${NC} Выход"
  echo ""
  read -p "  Выберите пункт: " c
  case $c in
    1) menu_diag;;
    2)
      echo ""
      echo -e "${PINK}⚠️ Внимание ⚠️${NC}"
      echo -e "${PINK}Во время перезагрузки:${NC}"
      echo -e "${PINK}- VPN прервется на 1–3 минуты${NC}"
      echo -e "${PINK}- Разорвется соединение с сервером${NC}"
      echo -e "${PINK}- Все клиенты будут переподключаться${NC}"
      echo ""
      read -p "Вы уверены, что хотите перезагрузить сервер? (yes/no): " ans1
      if [ "$ans1" = "yes" ]; then
        echo -e "${YELLOW}⏳ Сервер перезагружается...${NC}"
        sleep 2
        reboot
      else
        echo "Перезагрузка отменена"
      fi
      pause;;
    3) menu_panel;;
    4) menu_ports;;
    5) bash $DIR/logs.sh; pause;;
    6) x-ui; pause;;
    0) echo "Выход..."; exit 0;;
    *) echo -e "${RED}Неверный выбор${NC}"; sleep 1;;
  esac
done
