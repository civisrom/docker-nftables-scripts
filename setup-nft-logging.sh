#!/bin/bash
# Скрипт настройки и диагностики логирования nftables + logrotate
# Совместим с конфигом: docker-nft.conf (хост nginx + Docker mtproto)
# Автор: Nik
# Требует: root

set -euo pipefail

# Цвета для вывода
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
NC="\e[0m"

# Проверка прав доступа
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен быть запущен с правами root${NC}"
   exit 1
fi

echo -e "${YELLOW}=== Диагностика и исправление проблем с логированием nftables ===${NC}"

LOGS_DIR="/var/log/nftables"

# Определение пользователя rsyslog (syslog на Debian/Ubuntu, root на RHEL/CentOS)
if id "syslog" &>/dev/null; then
    SYSLOG_USER="syslog"
elif id "rsyslog" &>/dev/null; then
    SYSLOG_USER="rsyslog"
else
    SYSLOG_USER="root"
fi
SYSLOG_GROUP="adm"
id -gn "$SYSLOG_USER" &>/dev/null || SYSLOG_GROUP="root"

# Проверяем что группа adm существует, иначе используем группу пользователя
if ! getent group "$SYSLOG_GROUP" &>/dev/null; then
    SYSLOG_GROUP=$(id -gn "$SYSLOG_USER")
fi

echo "   Пользователь rsyslog: ${SYSLOG_USER}:${SYSLOG_GROUP}"

# 1. Проверка существования директории логов
echo "1. Проверка директории логов..."
if [ ! -d "$LOGS_DIR" ]; then
    echo "Создание директории: $LOGS_DIR"
    mkdir -p "$LOGS_DIR"
fi
echo -e "${GREEN}✓ Директория логов готова${NC}"

# 2. Установка правильных прав доступа
echo "2. Настройка прав доступа..."
chown -R "${SYSLOG_USER}:${SYSLOG_GROUP}" "$LOGS_DIR"
chmod -R 750 "$LOGS_DIR"
echo -e "${GREEN}✓ Права доступа установлены${NC}"

# 3. Конфигурация rsyslog
# Префиксы из docker-nft.conf:
#
# INPUT chain:
#   INPUT-DROP:       — дроп входящего трафика
#   INPUT-SYNFLOOD:   — SYN-flood на хост (per-source meter)
#   INPUT-PORTSCAN:   — сканирование портов (per-source meter)
#   IPTABLES-RK:      — RKN blacklist INPUT
#
# FORWARD chain:
#   FORWARD-DROP:     — дроп forward трафика
#   FWD-INET:         — контейнеры → интернет (mtproto)
#   FWD-SYNFLOOD:     — SYN-flood на контейнеры (per-source meter)
#   FWD-ASN:          — ASN-фильтрация → контейнеры
#   FWD-TG:           — TG GeoIP → контейнеры
#   DOCKER-BL:        — blacklist FORWARD

echo "3. Обновление конфигурации rsyslog..."
cat > /etc/rsyslog.d/10-nftables.conf << 'EOF'
# Конфигурация логирования nftables (docker-nft.conf)
# Порядок важен: сначала catch-all (без stop), потом конкретные правила (со stop)

# ── Catch-all: все nft-логи в один файл ──
:msg,contains,"INPUT-DROP:" /var/log/nftables/nft-all.log
:msg,contains,"INPUT-SYNFLOOD:" /var/log/nftables/nft-all.log
:msg,contains,"INPUT-PORTSCAN:" /var/log/nftables/nft-all.log
:msg,contains,"FORWARD-DROP:" /var/log/nftables/nft-all.log
:msg,contains,"FWD-" /var/log/nftables/nft-all.log
:msg,contains,"IPTABLES-RK:" /var/log/nftables/nft-all.log
:msg,contains,"DOCKER-BL:" /var/log/nftables/nft-all.log

# ── INPUT: DROP и атаки ──
:msg,contains,"INPUT-DROP:" /var/log/nftables/input-drop.log
& stop

:msg,contains,"INPUT-SYNFLOOD:" /var/log/nftables/input-attacks.log
& stop

:msg,contains,"INPUT-PORTSCAN:" /var/log/nftables/input-attacks.log
& stop

# ── FORWARD: DROP и атаки ──
:msg,contains,"FORWARD-DROP:" /var/log/nftables/forward-drop.log
& stop

:msg,contains,"FWD-SYNFLOOD:" /var/log/nftables/fwd-synflood.log
& stop

# ── Forward трафик по категориям ──
:msg,contains,"FWD-INET:" /var/log/nftables/fwd-inet.log
& stop

:msg,contains,"FWD-ASN:" /var/log/nftables/fwd-geo.log
:msg,contains,"FWD-TG:" /var/log/nftables/fwd-geo.log
& stop

# ── Blacklist ──
:msg,contains,"IPTABLES-RK:" /var/log/nftables/blacklist.log
& stop

:msg,contains,"DOCKER-BL:" /var/log/nftables/blacklist.log
& stop
EOF

echo -e "${GREEN}✓ Конфигурация rsyslog обновлена${NC}"

# Удаление старых конфигов если существуют
for old_conf in /etc/rsyslog.d/10-iptables.conf; do
    if [ -f "$old_conf" ]; then
        echo "   Удаление устаревшего $old_conf"
        rm -f "$old_conf"
    fi
done

# 4. Создание файлов логов
echo "4. Создание файлов логов..."
LOG_FILES=(
    nft-all.log
    input-drop.log
    input-attacks.log
    forward-drop.log
    fwd-synflood.log
    fwd-inet.log
    fwd-geo.log
    blacklist.log
)

for f in "${LOG_FILES[@]}"; do
    touch "$LOGS_DIR/$f"
done
chown "${SYSLOG_USER}:${SYSLOG_GROUP}" "$LOGS_DIR"/*.log
chmod 640 "$LOGS_DIR"/*.log
echo -e "${GREEN}✓ Файлы логов созданы (${#LOG_FILES[@]} файлов)${NC}"

# 5. Проверка kern.log
echo "5. Проверка kern.log..."
if ! grep -q "kern.*" /etc/rsyslog.conf; then
    echo "Добавление kern.* в rsyslog.conf"
    echo "kern.*                          /var/log/kern.log" >> /etc/rsyslog.conf
else
    echo -e "${GREEN}✓ Настройка kern.log уже есть${NC}"
fi

# 6. Настройки ядра
echo "6. Проверка настроек логирования ядра..."
if [ -f /proc/sys/kernel/printk ]; then
    echo "Текущие настройки:"
    cat /proc/sys/kernel/printk
    echo "7 4 1 7" > /proc/sys/kernel/printk
    echo -e "${GREEN}✓ Настройки ядра обновлены${NC}"
else
    echo -e "${RED}✗ Не найден /proc/sys/kernel/printk${NC}"
fi

# 7. Настройка logrotate
echo "7. Настройка logrotate..."
cat > /etc/logrotate.d/nftables << EOF
/var/log/nftables/*.log {
    rotate 7
    daily
    missingok
    notifempty
    compress
    delaycompress
    create 640 ${SYSLOG_USER} ${SYSLOG_GROUP}
    postrotate
        systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || true
    endscript
}
EOF

# Удаление старого конфига logrotate если существует
if [ -f /etc/logrotate.d/iptables ]; then
    echo "   Удаление устаревшего /etc/logrotate.d/iptables"
    rm -f /etc/logrotate.d/iptables
fi
echo -e "${GREEN}✓ Конфигурация logrotate обновлена${NC}"

# 8. Перезапуск rsyslog
echo "8. Перезапуск rsyslog..."
systemctl restart rsyslog
systemctl is-active --quiet rsyslog && \
    echo -e "${GREEN}✓ rsyslog запущен${NC}" || \
    echo -e "${RED}✗ rsyslog не удалось запустить${NC}"

# 9. Проверка logrotate конфигурации
echo "9. Проверка конфигурации logrotate..."
if logrotate --debug /etc/logrotate.d/nftables 2>&1 | grep -qi "error"; then
    echo -e "${RED}✗ Обнаружены ошибки в конфигурации logrotate${NC}"
else
    echo -e "${GREEN}✓ Конфигурация logrotate корректна${NC}"
fi

# 10. Тест ротации (только nftables логи, не все)
echo "10. Принудительная ротация nftables логов..."
logrotate -f /etc/logrotate.d/nftables
echo -e "${GREEN}✓ Тестовая ротация выполнена${NC}"

# 11. Проверка работы таймера logrotate
echo "11. Проверка таймера logrotate..."
systemctl list-timers --all | grep logrotate || echo -e "${RED}✗ Таймер logrotate не найден${NC}"

# 12. Тестовое сообщение в логи (используем актуальный nft-префикс)
echo "12. Генерация тестового сообщения..."
logger -p kern.warning "INPUT-DROP: TEST nftables logging check"
sleep 2
if grep -q "INPUT-DROP: TEST" "$LOGS_DIR/nft-all.log" 2>/dev/null; then
    echo -e "${GREEN}✓ Тестовое сообщение записано в nft-all.log${NC}"
elif grep -q "INPUT-DROP: TEST" "$LOGS_DIR/input-drop.log" 2>/dev/null; then
    echo -e "${GREEN}✓ Тестовое сообщение записано в input-drop.log${NC}"
elif grep -q "INPUT-DROP: TEST" /var/log/kern.log 2>/dev/null; then
    echo -e "${YELLOW}⚠ Тестовое сообщение в kern.log, но не в nftables логах — проверьте rsyslog${NC}"
else
    echo -e "${RED}✗ Тестовое сообщение не найдено в логах${NC}"
fi

# 13. Очистка старых архивов логов (оставляем только последние 7 для каждого файла)
echo "13. Очистка старых архивов nftables логов..."
for logfile in "$LOGS_DIR"/*.log; do
    [ -f "$logfile" ] || continue
    base=$(basename "$logfile")
    find "$LOGS_DIR" -type f -name "${base}.*.gz" | sort | head -n -7 | xargs -r rm -f
done
echo -e "${GREEN}✓ Старые архивы очищены, оставлены только последние 7 для каждого файла${NC}"

# 14. Итоговый статус
echo
echo -e "${YELLOW}=== Итого ===${NC}"
echo "Директория логов: $LOGS_DIR"
echo
echo "Файлы логов:"
for f in "${LOG_FILES[@]}"; do
    if [ -f "$LOGS_DIR/$f" ]; then
        echo -e "  ${GREEN}✓${NC} $f"
    else
        echo -e "  ${RED}✗${NC} $f"
    fi
done

echo
echo "Соответствие префиксов → лог-файлов:"
echo "  INPUT-DROP:       → input-drop.log"
echo "  INPUT-SYNFLOOD:   → input-attacks.log"
echo "  INPUT-PORTSCAN:   → input-attacks.log"
echo "  IPTABLES-RK:      → blacklist.log"
echo "  FORWARD-DROP:     → forward-drop.log"
echo "  FWD-SYNFLOOD:     → fwd-synflood.log"
echo "  FWD-INET:         → fwd-inet.log"
echo "  FWD-ASN/TG:       → fwd-geo.log"
echo "  DOCKER-BL:        → blacklist.log"
echo "  (все вместе)      → nft-all.log"

echo
echo -e "${YELLOW}Скрипт диагностики завершён.${NC}"
