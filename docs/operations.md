# Running Bifrost

## Startup

`Bifrost ready in ...` comes once the signaling port is bound, measured on the monotonic clock from process start.
On Linux, Bifrost can't start until the kernel has seeded its random number generator. Kernels before 5.4 on a VM
without a hardware RNG may take hours after boot, so a server started with the machine logs `Waiting for the
kernel's random number generator to be seeded` and stalls there. Add a virtio-rng device to the VM, or run haveged
or rng-tools on the host.

## Console

Bifrost reads commands from its standard input, which is where Pterodactyl's console and `docker attach` type.
Output goes to the log under the `Console` category.

| command | does |
|---|---|
| `status` | players online, and for each backend whether it's up, draining, how many players this proxy has there and how many it reports |
| `players` (or `list`) | every player with their backend, address and time online |
| `find <player>` | the same for one player, by display name in any case; names may contain spaces |
| `send <player> <backend>` | transfers a player (managed sessions) |
| `kick <player> [reason]` | disconnects a player, with the reason when managed; quote a name with spaces |
| `drain <backend>` / `undrain <backend>` | stops or resumes sending new players and transfers there; players already there stay |
| `log <level>` | changes the console level until restart; the file keeps `file_level`, and NetherNet's own traces need `trace` at startup |
| `stop` | tells every player the proxy is shutting down and exits, like SIGINT or SIGTERM |

Replies show whatever the console level. When standard input is closed (systemd's default, `docker run` without `-i`)
the console is simply off. A Bifrost
started in the background of a shell ignores `SIGTTIN`, so reading the terminal can't stop it.

There is no network admin API. Anything that needs remote control should be a plugin, or a process that writes to
Bifrost's standard input.

## Routing

```toml
[routing]
join = ["lobby-1", "lobby-2"]
fallback = ["limbo"]
balance = "least_players"

[[backend]]
name = "lobby-1"
address = "10.0.0.2:19132"
max_players = 200
```

- New players only go to `join` backends, then to `fallback` backends in the order listed, once every join
  backend is down, draining or full. Without `[routing]`, the first `[[backend]]` takes new players and the others
  are fallbacks in the order listed.
- `balance` spreads players over the join backends: `round_robin` takes turns, `least_players` picks the one
  with the fewest of this proxy's players, `first` fills each in turn (useful with `max_players`).
- `max_players` counts this proxy's players on that backend, transfers on their way in included. Other proxies
  and direct joins aren't counted. 0 means no limit.
- `draining = true` starts a backend drained; `drain` and `undrain` change it while running. Draining and full
  backends refuse transfers with `BUSY`.
- A backend is skipped while health checks say it's down. A passing health check (`GET /v1/join`) only means the
  signaling endpoint answers, not that logins or gameplay work, so a backend whose dial fails is marked down until
  the next probe passes.
- A player whose dial fails is tried on the next eligible backend. After three failed dials only backends the last
  health check passed are tried.

A backend's own Transfer packet to an address or name listed in `[[backend]]` becomes a proxy transfer in managed
mode. Anywhere else, it's dropped unless `[transfer] external = true`, because the other server would receive the
player's Microsoft-signed login. Passthrough relays batches without reading them, so it can't do either.

## Microsoft's signing keys

With `[auth] mode = "verify"`, Bifrost checks the keys file once a minute and swaps the keys when it changes, so a
cron job or the Pterodactyl egg can refresh it without a restart. It also downloads the current keys every
`[auth] refresh_hours` (12 by default, 0 turns it off), and within five minutes of a login signed with a key it
doesn't know, writing them to the keys file. Logins already being checked finish with the keys they started with.
A file or download that doesn't parse leaves the loaded keys in place and logs one warning until it recovers.

## Metrics

`[server] metrics = "127.0.0.1:9100"` serves Prometheus text at `/metrics`. It has no authentication, so keep it on
loopback or a private network; Bifrost warns at startup when it listens anywhere else. One scrape is answered at a
time and each gets 2 seconds in total.

Beyond the traffic, queue and transfer counters, `bifrost_backend_up`, `bifrost_backend_players` and
`bifrost_backend_draining` describe each backend, `bifrost_login_failures_total{cause}` splits failed logins into
rejected, unverifiable, throttled and the three stage timeouts, `bifrost_backend_redirects_total{result}` counts
backend Transfer packets proxied or blocked, and the `turn_seconds`, `backend_dial_seconds` and
`transfer_seconds` histograms show worker turn time, dial time and transfer time.

## Key files

`[session] proxy_key_file` and `[nethernet] identity_file` are private keys. Bifrost creates them with mode 0600 and
warns at startup when another account could read them. Whoever holds the proxy key can log in to trusting backends
as any player.
