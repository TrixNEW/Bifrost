# Running Bifrost in front of Quark

The recommended setup is **managed mode with auth on**. Bifrost checks each player's Xbox login, then logs in to
Quark on their behalf with a key Quark trusts. Quark gets the player's name, UUID, XUID, skin and real IP.

```
player ──NetherNet──> Bifrost (public, verifies Xbox) ──NetherNet──> Quark (private, trusts Bifrost's key)
```

## 1. Bifrost

Download Microsoft's signing keys and save them next to the config:

```sh
curl -o minecraft-keys.json https://authorization.franchise.minecraft-services.net/.well-known/keys
```

Microsoft rotates these keys. Bifrost downloads them again every `refresh_hours` (12 by default) and soon after
a login names a key it doesn't know, writes them to `keys_file`, and also picks up any change you make to the file
yourself, all without a restart. Downloads check Microsoft's certificate against the system's CA bundle, so slim
images need `ca-certificates` installed. See [Running Bifrost](operations.md#microsofts-signing-keys).

In `config/bifrost.toml`:

```toml
[auth]
mode = "verify"
keys_file = "minecraft-keys.json"
refresh_hours = 12

[session]
mode = "managed"
proxy_key_file = "bifrost-proxy.key"

[nethernet]
backend_ice = "private"

[routing]
join = ["lobby"]

[commands]
# XUIDs of the players allowed to run privileged plugin commands
operators = ["2535400000000001"]

[[backend]]
name = "lobby"
address = "10.0.0.2:19132"   # Quark's private address
```

Start Bifrost once. It creates the private key file and logs its public key:

```
Backends must trust proxy key MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE...
```

## 2. Quark

Use a Quark v6 build that supports `proxy-only`. In `config/server.toml`:

```toml
[network]
xbox-auth = true
proxy-only = true
trusted-proxy-keys = ["MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE..."]

[transport]
name = 'nethernet'
```

Quark logs `Trusting 1 proxy key(s)` at startup. With several Bifrost instances, list each one's key.
Quark will only admit trusted proxy connections carrying a signed Xbox identity. The setting disables Query,
UPnP and NetherNet LAN discovery. Set `bind-address` to the private interface when Quark can bind to it directly.

Pin Quark's identity too. After Quark has created its identity file, export only its public key on the backend:

```sh
openssl pkey -inform DER -in nethernet-identity.der -pubout -outform DER | openssl base64 -A
```

Copy the result to `identity_key` in that backend's `[[backend]]` table. Bifrost checks that Quark signed
its WebRTC certificate fingerprint with the pinned key before sending the player's login. Keep the backend
identity file across restarts. Rotate the pin when you replace the key.

## 3. Lock it down

- **Firewall Quark.** Restrict both its signaling TCP port and its ICE UDP range to Bifrost on the private
  interface. Proxy-only admission runs after native signaling and WebRTC setup, so filtering also protects
  backend connection capacity and keeps its status endpoint private.
- **Guard `bifrost-proxy.key`.** Whoever has it can join Quark as any player. Bifrost creates it with mode 0600
  and warns at startup if another account can read it. Keep it out of backups you share. If it leaks, delete it, restart Bifrost, and replace the key in
  `trusted-proxy-keys`.
- **Keep `bifrost-identity.der` too.** Players confirm it the first time they join, so losing it makes them
  confirm a new one.
- **Only list proxies you run** in `trusted-proxy-keys`.

## Behind Docker, Pterodactyl or NAT

Players connect to the UDP ports Bifrost offers during signaling. In a container those are private addresses the
player can't reach, so tell Bifrost its public IP and pin the ports:

```toml
[nethernet]
port_min = 50000
port_max = 50100
advertise_addresses = ["203.0.113.10"]
```

Forward that UDP range with the same port numbers on both sides, plus the TCP signaling port from `bind`. The
addresses are IP literals without a port, at most 8, and Bifrost adds them beside what ICE finds on its own.

On the same Pterodactyl node, use a private backend allocation. Wings maps allocations on `127.0.0.1` to
the Docker bridge gateway, usually `172.18.0.1`. Configure Bifrost to dial the reachable gateway allocation,
and have Quark bind its container interface or wildcard inside the container. For ICE, keep the containers
on a network where Bifrost can reach Quark's container UDP candidates, or use a private, port-preserving
UDP mapping. Assign distinct Quark ICE ranges where host ports are mapped. Across VPS nodes, use an internal
network or VPN and restrict both protocols to Bifrost there.

Docker-published ports can bypass UFW input rules. On nodes using Docker's iptables backend, apply Docker
forwarding rules in `DOCKER-USER` and check IPv4 and IPv6 from outside the node. See the
[Pterodactyl proxy guide](https://docs.pterodactyl.io/v2/guides/games/minecraft) and
[Docker firewall documentation](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

## Operating it

Type `status`, `players`, `send <player> <backend>`, `drain <backend>` and the other
[console commands](operations.md#console) into Bifrost's console, including Pterodactyl's.

## Logging

```toml
[logging]
level = "info"          # error, warn, info, debug, trace
color = "auto"          # auto, always, never
timestamps = true
file = "logs/bifrost.log"
file_level = "debug"
file_max_mb = 16
```

`info` covers startup, players joining, moving and leaving, and backends going down or coming back. `debug` adds
routing, dial times, handshake stages and why a connection closed before login. `trace` adds transfer state steps
and NetherNet's own signaling and WebRTC diagnostics, which print unformatted and only to the console.

`auto` colors only a terminal and honors `NO_COLOR`. Pterodactyl's console renders ANSI, so set `color = "always"`
if it shows plain text, and `timestamps = false` when something else already stamps each line. The file never has
colors. Each start moves the previous log to `<file>.1`, and so does reaching `file_max_mb`, so the two files
never take more than twice that.

## Other modes

| setup | use it for | what Quark sees |
| --- | --- | --- |
| managed + `auth = "verify"` | **production** | name, UUID, XUID, skin, real IP |
| passthrough + `auth = "verify"` | when Quark must check every Xbox login itself | name, UUID, XUID, skin, Bifrost's IP |
| passthrough + `auth = "off"` | local testing | offline players only, with `xbox-auth = false`. Bifrost dials with a throwaway key, so Quark can't be made to trust it |

In passthrough, the key to trust is the one Bifrost logs, which comes from `identity_file`. IP forwarding isn't
available there, so IP bans and per-IP limits in Quark see every player as Bifrost. Keep `proxy-only = false`
for passthrough or standalone Quark. Apply the same network isolation for a passthrough backend.

## What the trust covers

- Quark honours a Bifrost-signed login only on a NetherNet connection that proves it holds a trusted key. A
  captured login can't be replayed from anywhere else, and never over RakNet.
- Bifrost signs logins for 60 seconds at most, so a stolen one goes stale quickly.
- A trusted proxy is believed about who the player is. That's the point of trusting it, and it's why the key
  must stay private.

See [Testing](testing.md) for the real Quark loopback test with a synthetic Bedrock client.
