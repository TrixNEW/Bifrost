# Testing

| command | runs |
|---|---|
| `zig build test` | unit and integration tests, in-process players and backends over real NetherNet connections |
| `zig build bench-test` | benchmark accounting and cleanup |
| `zig build stress -Doptimize=ReleaseSafe` | the integration tests again, never from cache; `-Dsoak=N` repeats the churn tests |
| `zig build fuzz-test --fuzz=1M` | Linux only, native packet decoding and injection validation |
| `sh tools/tsan.sh` | Linux only, the suite under ThreadSanitizer (Zig code only, libdatachannel isn't instrumented) |
| `zig build bench -Doptimize=ReleaseFast` | throughput, latency, joins and memory, see `tests/bench/baseline.md` |

CI runs format, the suite in Debug, ReleaseSafe and ReleaseFast on Linux and Windows, and three stress passes. The
nightly job runs a 25-round soak and the benchmarks.

The players and backends in these tests are built from bedwire and nethernet-zig, the same libraries Bifrost uses.
That proves Bifrost and its own libraries agree; it doesn't prove a vanilla client or Quark does.

## Real-client checks

Nobody has run these yet. They need a Windows or mobile Bedrock 1.26.60 client signed in to Xbox, a Quark v6 build
at `a2cf1f81e` or newer, and Microsoft's keys.

1. Start Quark with `xbox-auth = true` on a private address, say `10.0.0.2:19133`, and note its log.
2. Configure Bifrost as in the [setup guide](setup.md): managed sessions, `[auth] mode = "verify"`, Quark as the
   only `[[backend]]`. Start it once and copy the logged proxy key into Quark's `trusted-proxy-keys`. Restart Quark
   and check it logs `Trusting 1 proxy key(s)`.
3. Set `[logging] level = "debug"` in Bifrost so handshake stages and dial times show.
4. In the client, add Bifrost's address and port as a server. The server list should show Bifrost's MOTD and
   Quark's player count.
5. Join. Bifrost should log `<name> joined lobby from <ip>`, and Quark should show the same name, XUID and the
   player's real IP rather than Bifrost's.
6. Walk, fight, open a chest and a form, chat, and run `/` commands, plugin ones included.
7. With a second Quark as `[[backend]] survival`, run `send <name> survival` on Bifrost's console, both into the
   same dimension and into the nether. The player should arrive without a loading-screen hang, ghost entities, a
   form or title left over, or a disconnect; Bifrost should log `moved lobby -> survival in ...`.
8. `kick <name>` and `stop` should show the reason on the client.
9. Repeat 4 and 5 from behind a NAT (a phone on mobile data) and, for Docker or Pterodactyl, with
   `advertise_addresses` set and then with `udp_mux = true`.

A failing join is easiest to read with `level = "trace"`, which adds NetherNet's signaling and ICE diagnostics:

| log | stage |
|---|---|
| nothing at all for the attempt | the client never reached signaling: wrong address, TCP port blocked |
| `Turning away a connection` | admission: full, per-address cap, no backend available |
| at trace, NetherNet answers the offer but no connection follows | ICE never found a UDP path: advertised addresses or the UDP port range |
| `Connection from ... closed before login` | the client left or broke off during Login, the reason follows |
| `Rejected a login` | Xbox verification: stale keys, clock skew, or a replayed login |
| `Can't reach <backend>` | Bifrost to backend: signaling, proxy key not trusted, or the backend's UDP ports |
| `Managed session ... failed` | protocol mismatch between the client, Bifrost and the backend |
