# docker-nftables-scripts

Интегрированные правила nftables для хоста + Docker с фильтрацией по GeoIP/ASN.

## Архитектура

```
docker-nft.conf               — основной конфиг (хост + Docker + ASN)
docker-native-user-rules.conf — пользовательские правила для Docker 29+ native backend
```

### Схема прохождения трафика

```
                          ┌─────────────────────┐
                          │   geoip-mark-input   │  priority -1
                          │  (маркировка @try,   │
                          │   @asn по src IP)     │
                          └──────────┬────────────┘
                                     ▼
ВХОДЯЩИЙ ──────────────────►  chain input  ◄──── policy DROP
                              │ $BLACKLIST → drop
                              │ $ASN tcp 443,22 → accept
                              │ ct established → accept
                              │ docker0 → accept
                              └─► всё остальное → drop

                          ┌──────────────────────┐
                          │  geoip-mark-forward   │  priority -1
                          │  (маркировка @try,    │
                          │   @asn по src IP)      │
                          └──────────┬─────────────┘
                                     ▼
FORWARD ───────────────────►  chain forward  ◄── policy DROP
                              │ ct established → accept
                              │ docker0↔docker0 → accept
                              │ 10.0.0.0/8 внутр. → accept
                              │ docker→DNS(53,443) → accept
                              │ $BLACKLIST→docker → drop
                              │ $ASN→docker → jump docker (порты)
                              └─► всё остальное → drop
```

## Настройка

### 1. Docker daemon

`/etc/docker/daemon.json`:

```json
{
  "iptables": false
}
```

### 2. IP forwarding

```bash
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/docker.conf
```

### 3. Загрузка правил

```bash
nft -f docker-nft.conf
```

## Политика доступа

| Направление | Что разрешено | Фильтрация |
|---|---|---|
| Внешний мир → хост | TCP 443, 22; UDP 443 | Только @asn, блокировка @BLACKLIST |
| Внешний мир → контейнеры | Опубликованные порты | Только @asn, блокировка @BLACKLIST |
| Контейнер → контейнер | Весь трафик на docker0 | Без ограничений |
| Контейнер → Docker сети | 10.0.0.0/8 | Без ограничений |
| Контейнер → интернет | DNS: 8.8.8.8, 1.1.1.1, 8.8.4.4, 1.0.0.1 (53, 443) | Только указанные IP/порты |
| Контейнер → всё остальное | Заблокировано | DROP |

## Публикация портов

Для публикации порта контейнера (например host:8080 → container 172.17.0.2:80) добавьте правила в два места:

```bash
# 1. table ip filter → chain docker — разрешить форвард:
iifname != "docker0" tcp dport 8080 counter accept

# 2. table ip dockernat → chain docker — DNAT:
tcp dport 8080 dnat to 172.17.0.2:80
```

## Управление DNS для контейнеров

DNS-серверы задаются через именованный set `dns_servers`. Для изменения списка:

```bash
# Просмотр текущего set
nft list set ip filter dns_servers

# Добавить DNS-сервер на лету
nft add element ip filter dns_servers { 9.9.9.9 }

# Удалить DNS-сервер
nft delete element ip filter dns_servers { 9.9.9.9 }
```

## Пользовательские правила (docker-user)

Добавляйте свои правила форвардинга в `chain docker-user`:

```bash
# Заблокировать контейнерам доступ к LAN
nft add rule ip filter docker-user iifname "docker0" ip daddr 192.168.0.0/16 drop

# Заблокировать конкретный контейнер
nft add rule ip filter docker-user ip saddr 172.17.0.5 drop
```

## Docker 29+ native nftables (experimental)

Альтернативный подход — Docker сам управляет таблицами. См. `docker-native-user-rules.conf`.

```json
{ "firewall-backend": "nftables" }
```

## Ссылки

- [Docker with nftables](https://docs.docker.com/engine/network/firewall-nftables/)
- [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Docker with iptables](https://docs.docker.com/engine/network/firewall-iptables/)
