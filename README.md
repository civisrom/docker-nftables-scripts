# docker-nftables-scripts


## Архитектура vpnbot + nftables

```
docker-nft.conf               — основной конфиг (хост + vpnbot + ASN)
docker-native-user-rules.conf — пользовательские правила для Docker 29+ native backend
```

### Сетевая схема vpnbot

```
Внешний клиент
    │
    ├─ :80/tcp ──DNAT──► nginx (10.10.0.2)
    │                      └─► php (10.10.0.7:8080)
    │                      └─► adguard DoH (/dns-query)
    │
    ├─ :443/tcp+udp ─DNAT─► upstream (10.10.0.10) ─── SNI routing:
    │                          ├─► nginx (10.10.0.2:443)    [default]
    │                          ├─► xray (10.10.0.9:443)     [VLESS Reality]
    │                          ├─► openconnect (10.10.0.11)  [ocserv]
    │                          └─► naive (10.10.0.12:443)    [NaiveProxy]
    │
    ├─ :51820/udp ──DNAT──► wireguard (10.10.0.4)
    │                          └─► VPN клиенты 10.0.1.0/24
    │
    └─ :51821/udp ──DNAT──► wireguard1 (10.10.0.14)
                               └─► VPN клиенты 10.0.3.0/24

Docker-сети:
  default:  10.10.0.0/24  (все контейнеры)
  xray:     10.10.1.0/24  (nginx ↔ xray)

VPN-клиенты:
  WG:  10.0.1.0/24
  OC:  10.0.2.0/24
  WG1: 10.0.3.0/24

DNS (AdGuard): 10.10.0.5 → upstream: 8.8.8.8, 1.1.1.1
```

### Схема прохождения трафика

```
                          ┌─────────────────────┐
                          │  geoip-mark-input    │  priority -1
                          │  @try, @asn          │
                          └──────────┬───────────┘
                                     ▼
ВХОДЯЩИЙ ──────────────────►  chain input  ◄──── policy DROP
                              │ $BLACKLIST → drop
                              │ $ASN tcp {443,22}, udp 443 → accept
                              │ $ASN udp {51820,51821} → accept (WG)
                              │ ct established → accept
                              │ Docker nets → accept
                              └─► остальное → drop

                          ┌──────────────────────┐
                          │  geoip-mark-forward   │  priority -1
                          │  @try, @asn           │
                          └──────────┬────────────┘
                                     ▼
FORWARD ───────────────────►  chain forward  ◄── policy DROP
                              │ ct established → accept
                              │ docker ↔ docker → accept
                              │ vpn_clients ↔ docker → accept
                              │ docker → DNS (53,443) → accept
                              │ docker → интернет → accept (VPN)
                              │ $BLACKLIST → docker → drop
                              │ $ASN → docker → accept (DNAT)
                              └─► остальное → drop

DNAT (prerouting):
  :80    → nginx    (10.10.0.2)
  :443   → upstream (10.10.0.10)
  :51820 → wg       (10.10.0.4)
  :51821 → wg1      (10.10.0.14)

MASQUERADE (postrouting):
  10.10.0.0/24 → публичный IP
  10.10.1.0/24 → публичный IP
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

### 4. Запуск vpnbot

```bash
systemctl start vpnbot
```

## Политика доступа

| Направление | Что разрешено | Фильтрация |
|---|---|---|
| Внешний мир → хост | TCP 443, 22; UDP 443, 51820, 51821 | Только @asn, блокировка @BLACKLIST |
| Внешний мир → контейнеры | Порты 80, 443, 51820, 51821 (через DNAT) | Только @asn, блокировка @BLACKLIST |
| Контейнер ↔ контейнер | 10.10.0.0/24, 10.10.1.0/24 | Без ограничений |
| VPN-клиенты ↔ контейнеры | 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24 | Без ограничений |
| Контейнеры → DNS | 8.8.8.8, 1.1.1.1, 8.8.4.4, 1.0.0.1 (53, 443) | Без ограничений |
| Контейнеры → интернет | Весь трафик (VPN-маршрутизация клиентов) | Без ограничений |
| Всё остальное | Заблокировано | DROP |

## Именованные наборы (sets)

Наборы можно менять на лету без перезагрузки конфига:

```bash
# Просмотр DNS-серверов
nft list set ip filter dns_servers

# Добавить DNS
nft add element ip filter dns_servers { 9.9.9.9 }

# Просмотр Docker-подсетей
nft list set ip filter docker_nets

# Добавить новую Docker-сеть
nft add element ip filter docker_nets { 172.18.0.0/24 }

# Просмотр VPN-клиентских подсетей
nft list set ip filter vpn_clients

# Добавить VPN-подсеть
nft add element ip filter vpn_clients { 10.0.4.0/24 }
```

## Кастомизация

### Порты WireGuard

Если WG порты отличаются от 51820/51821, измените переменные в начале конфига:

```
define WGPORT  = 51820
define WG1PORT = 51821
```

### Добавление нового сервиса

Для нового контейнера с пробросом порта:

```bash
# 1. Добавить DNAT в prerouting (table ip dockernat):
nft add rule ip dockernat prerouting tcp dport 8443 dnat to 10.10.0.X:8443

# 2. Добавить подсеть в docker_nets (если новая сеть):
nft add element ip filter docker_nets { 10.10.2.0/24 }
```

## Ссылки

- [vpnbot](https://github.com/mercurykd/vpnbot)
- [Docker with nftables](https://docs.docker.com/engine/network/firewall-nftables/)
- [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
