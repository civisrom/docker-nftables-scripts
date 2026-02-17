#!/bin/bash
# Скрипт настройки логирования nftables для NAT-релея + logrotate
# Совместим с конфигом: relay-nft.conf (сервер 1-ru)
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

echo -e "${YELLOW}=== Настройка логирования nftables (NAT-релей) ===${NC}"

LOGS_DIR="/var/log/nftables"

# Определение пользователя rsyslog
if id "syslog" &>/dev/null; then
    SYSLOG_USER="syslog"
elif id "rsyslog" &>/dev/null; then
    SYSLOG_USER="rsyslog"
else
    SYSLOG_USER="root"
fi
SYSLOG_GROUP="adm"
id -gn "$SYSLOG_USER" &>/dev/null || SYSLOG_GROUP="root"

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
# Префиксы из relay-nft.conf:
#
# INPUT chain:
#   INPUT-DROP:       — дроп входящего трафика (финальный)
#   INPUT-SPOOF:      — спуфинг loopback IP извне
#   INPUT-BOGON:      — приватные IP извне (bogon)
#   INPUT-SYNFLOOD:   — SYN-flood на хост (per-source meter)
#   INPUT-PORTSCAN:   — сканирование портов (per-source meter)
#   INPUT-SSH:        — успешные SSH-подключения (ASN)
#   IPTABLES-RK:      — RKN blacklist INPUT
#
# FORWARD chain:
#   FORWARD-DROP:     — дроп forward трафика (финальный)
#   FWD-SPOOF:        — спуфинг в forward (fib check)
#   FWD-SYNFLOOD:     — SYN-flood на релей (per-source meter)
#   RELAY-BL:         — RKN blacklist → relay targets
#   RELAY-GE-ASN:     — релей → 2-ge от ASN (VLESS TCP 443)
#   RELAY-GE-TG:      — релей → 2-ge от TG  (VLESS TCP 443)
#   RELAY-NL-ASN:     — релей → 3-nl от ASN (VLESS TCP 443)
#   RELAY-NL-TG:      — релей → 3-nl от TG  (VLESS TCP 443)
#
# Закомментированы в nft (готовы при активации):
#   RELAY-GE-WG-ASN:  — релей → 2-ge от ASN (AmneziaWG UDP)
#   RELAY-GE-WG-TG:   — релей → 2-ge от TG  (AmneziaWG UDP)
#   RELAY-NL-WG-ASN:  — релей → 3-nl от ASN (AmneziaWG UDP)
#   RELAY-NL-WG-TG:   — релей → 3-nl от TG  (AmneziaWG UDP)
#   RELAY-GE-WEB:     — релей → 2-ge Web UI (TCP)
#   RELAY-NL-WEB:     — релей → 3-nl Web UI (TCP)

echo "3. Обновление конфигурации rsyslog..."
cat > /etc/rsyslog.d/10-nftables.conf << 'EOF'
# Конфигурация логирования nftables (relay-nft.conf)
# Порядок важен: сначала catch-all (без stop), потом конкретные правила (со stop)

# ─── Catch-all: все nft-логи в один файл ───
:msg,contains,"INPUT-" /var/log/nftables/nft-all.log
:msg,contains,"FORWARD-" /var/log/nftables/nft-all.log
:msg,contains,"FWD-" /var/log/nftables/nft-all.log
:msg,contains,"RELAY-" /var/log/nftables/nft-all.log
:msg,contains,"IPTABLES-RK:" /var/log/nftables/nft-all.log

# ─── INPUT: основные события ───

# SSH-подключения (ASN)
:msg,contains,"INPUT-SSH:" /var/log/nftables/input-ssh.log
& stop

# Атаки и защита
:msg,contains,"INPUT-SYNFLOOD:" /var/log/nftables/input-attacks.log
& stop

:msg,contains,"INPUT-PORTSCAN:" /var/log/nftables/input-attacks.log
& stop

:msg,contains,"INPUT-SPOOF:" /var/log/nftables/input-attacks.log
& stop

:msg,contains,"INPUT-BOGON:" /var/log/nftables/input-attacks.log
& stop

# RKN blacklist (INPUT)
:msg,contains,"IPTABLES-RK:" /var/log/nftables/blacklist.log
& stop

# Финальный дроп INPUT
:msg,contains,"INPUT-DROP:" /var/log/nftables/input-drop.log
& stop

# ─── FORWARD: релей и защита ───

# Спуфинг в forward
:msg,contains,"FWD-SPOOF:" /var/log/nftables/fwd-attacks.log
& stop

# RKN blacklist → relay
:msg,contains,"RELAY-BL:" /var/log/nftables/blacklist.log
& stop

# Релей → 2-ge (VLESS + WG + Web UI)
:msg,contains,"RELAY-GE-" /var/log/nftables/relay-ge.log
& stop

# Релей → 3-nl (VLESS + WG + Web UI)
:msg,contains,"RELAY-NL-" /var/log/nftables/relay-nl.log
& stop

# SYN-flood в forward
:msg,contains,"FWD-SYNFLOOD:" /var/log/nftables/fwd-attacks.log
& stop

# Финальный дроп FORWARD
:msg,contains,"FORWARD-DROP:" /var/log/nftables/forward-drop.log
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
    input-ssh.log
    input-attacks.log
    input-drop.log
    blacklist.log
    fwd-attacks.log
    relay-ge.log
    relay-nl.log
    forward-drop.log
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
    rotate 14
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
echo -e "${GREEN}✓ Конфигурация logrotate обновлена (хранение 14 дней)${NC}"

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

# 10. Тест ротации
echo "10. Принудительная ротация nftables логов..."
logrotate -f /etc/logrotate.d/nftables
echo -e "${GREEN}✓ Тестовая ротация выполнена${NC}"

# 11. Проверка работы таймера logrotate
echo "11. Проверка таймера logrotate..."
systemctl list-timers --all | grep logrotate || echo -e "${RED}✗ Таймер logrotate не найден${NC}"

# 12. Тестовое сообщение в логи
echo "12. Генерация тестового сообщения..."
logger -p kern.warning "INPUT-DROP: TEST nftables relay logging check"
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

# 13. Очистка старых архивов логов
echo "13. Очистка старых архивов nftables логов..."
for logfile in "$LOGS_DIR"/*.log; do
    [ -f "$logfile" ] || continue
    base=$(basename "$logfile")
    find "$LOGS_DIR" -type f -name "${base}.*.gz" | sort | head -n -14 | xargs -r rm -f
done
echo -e "${GREEN}✓ Старые архивы очищены, оставлены только последние 14 для каждого файла${NC}"

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
echo
echo "  INPUT chain:"
echo "  INPUT-SSH:        → input-ssh.log      (SSH-подключения ASN)"
echo "  INPUT-SYNFLOOD:   → input-attacks.log   (SYN-flood на хост)"
echo "  INPUT-PORTSCAN:   → input-attacks.log   (сканирование портов)"
echo "  INPUT-SPOOF:      → input-attacks.log   (спуфинг loopback)"
echo "  INPUT-BOGON:      → input-attacks.log   (bogon IP извне)"
echo "  IPTABLES-RK:      → blacklist.log       (RKN blacklist INPUT)"
echo "  INPUT-DROP:       → input-drop.log      (финальный дроп)"
echo
echo "  FORWARD chain:"
echo "  RELAY-GE-ASN:     → relay-ge.log        (→ 2-ge от ASN, VLESS)"
echo "  RELAY-GE-TG:      → relay-ge.log        (→ 2-ge от TG, VLESS)"
echo "  RELAY-GE-WG-ASN:  → relay-ge.log        (→ 2-ge от ASN, WG)*"
echo "  RELAY-GE-WG-TG:   → relay-ge.log        (→ 2-ge от TG, WG)*"
echo "  RELAY-GE-WEB:     → relay-ge.log        (→ 2-ge Web UI)*"
echo "  RELAY-NL-ASN:     → relay-nl.log        (→ 3-nl от ASN, VLESS)"
echo "  RELAY-NL-TG:      → relay-nl.log        (→ 3-nl от TG, VLESS)"
echo "  RELAY-NL-WG-ASN:  → relay-nl.log        (→ 3-nl от ASN, WG)*"
echo "  RELAY-NL-WG-TG:   → relay-nl.log        (→ 3-nl от TG, WG)*"
echo "  RELAY-NL-WEB:     → relay-nl.log        (→ 3-nl Web UI)*"
echo "  RELAY-BL:         → blacklist.log       (RKN blacklist → relay)"
echo "  FWD-SPOOF:        → fwd-attacks.log     (спуфинг forward)"
echo "  FWD-SYNFLOOD:     → fwd-attacks.log     (SYN-flood relay)"
echo "  FORWARD-DROP:     → forward-drop.log    (финальный дроп)"
echo
echo "  * — закомментированы в nft, активируются при включении"
echo "  (все вместе)      → nft-all.log"

echo
echo -e "${YELLOW}Полезные команды мониторинга:${NC}"
echo "  tail -f $LOGS_DIR/nft-all.log        # все события"
echo "  tail -f $LOGS_DIR/relay-ge.log       # трафик → 2-ge"
echo "  tail -f $LOGS_DIR/relay-nl.log       # трафик → 3-nl"
echo "  tail -f $LOGS_DIR/blacklist.log      # RKN блокировки"
echo "  tail -f $LOGS_DIR/input-attacks.log  # атаки на хост"
echo "  tail -f $LOGS_DIR/forward-drop.log   # отклонённый relay"

echo
echo -e "${YELLOW}Скрипт настройки завершён.${NC}"
