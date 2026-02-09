# docker-nftables-scripts

nftables rules for running Docker without iptables.

## Approach 1: Manual rules (all Docker versions)

Use `docker-nft.conf` when you want full control over firewall rules and run Docker with iptables disabled.

### Setup

1. Disable Docker's iptables management in `/etc/docker/daemon.json`:

```json
{
  "iptables": false
}
```

Or start the daemon with: `dockerd --iptables=false`

2. Enable IP forwarding:

```bash
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/docker.conf
```

3. Load the rules:

```bash
nft -f docker-nft.conf
```

### Publishing ports

When publishing container ports, add rules to both tables:

```
# In "chain docker" of table inet docker — allow forwarded traffic:
iif != docker0 tcp dport 8080 accept

# In "chain docker" of table ip dockernat — DNAT to container:
tcp dport 8080 dnat to 172.17.0.2:80
```

### Custom Docker networks

For additional Docker networks (e.g. `br-abcdef123456` with subnet `172.18.0.0/16`), duplicate the relevant rules replacing `docker0` / `172.17.0.0/16` with your bridge name and subnet. Add isolation rules between networks in `docker-isolation-stage-1` and `docker-isolation-stage-2`.

## Approach 2: Docker 29+ native nftables backend (experimental)

Docker 29+ has experimental nftables support. Docker manages its own tables (`ip docker-bridges`, `ip6 docker-bridges`) automatically.

### Setup

1. Configure the nftables backend in `/etc/docker/daemon.json`:

```json
{
  "firewall-backend": "nftables"
}
```

2. Enable IP forwarding (Docker will **not** do this automatically with the nftables backend):

```bash
sysctl -w net.ipv4.ip_forward=1
```

3. Use `docker-native-user-rules.conf` for custom rules:

```bash
nft -f docker-native-user-rules.conf
```

### Key differences from iptables backend

- No `DOCKER-USER` chain — use separate tables with priority-based ordering instead
- Docker fully owns its tables — do not modify `ip docker-bridges` directly
- Use `--bridge-accept-fwmark` to allow traffic Docker would otherwise drop
- Does not work with Swarm mode (overlay network rules not yet migrated)

## References

- [Docker with nftables](https://docs.docker.com/engine/network/firewall-nftables/)
- [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Docker with iptables](https://docs.docker.com/engine/network/firewall-iptables/)
