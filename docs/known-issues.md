# Known issues

What's open as of 2.0.0-rc.16. Details live in the linked docs.

## Not yet verified

- **No real client has joined through Bifrost.** Every test uses in-process players and backends built on bedwire
  and nethernet-zig. Neither a vanilla Bedrock client joining Bifrost nor a full Bifrost-to-Quark session has
  been run. The Quark login path was checked by verifying a bedwire-built login with Quark's own code. See
  [Real-client checks](testing.md#real-client-checks) for the procedure.
- **Bifrost speaks Minecraft 1.26.60 (protocol 2225) only.** Packet codecs come from protocol-zig, which
  follows one stable protocol at a time. A client on another version gets a PlayStatus saying which side is
  outdated, and raw packets from plugins have to use the 1.26.60 layouts.
- **No AddressSanitizer run of the native libraries.** The full suite passes on Windows and Linux in Debug,
  ReleaseSafe and ReleaseFast, and under ThreadSanitizer on Linux (`tools/tsan.sh`), which only instruments the
  Zig code. Building libdatachannel with ASan (`NETHERNET_SANITIZER_FLAGS`) and preloading the runtime into the
  Zig tests doesn't work: ASan aborts every test that ends a Zig thread, failing to unmap the stack Zig gave it.
- **`udp_mux` hasn't been tried with vanilla clients** (`config/bifrost.toml`), though the Pterodactyl egg turns it on.
- **Other backends:** gophertunnel servers and vanilla BDS have no way to trust a proxy, and neither was tested.
  See [Backend support](backends.md).
- **Clearing a client on transfer** sends ClientboundCloseForm, title clear and reset, and a camera shake stop on
  top of what was already reset. Whether every client build handles each of them the same way hasn't been checked.
- **Transfers count dimension acks.** A change to another dimension the old backend sent but the client hadn't
  acknowledged yet is expected to be acknowledged before the handoff's own; that matches bedwire's client and the
  protocol, but a client that skipped such an ack would stall the switch until `phase_timeout_ms`.

## Limits of the design

- **Passthrough doesn't forward the player's IP**, so backends see Bifrost's address. Managed mode does. See
  [Setup](setup.md#other-modes).
- **Passthrough can't police a backend's Transfer packets.** It relays batches without reading them, so a backend
  can still send its players to any address there. Managed mode turns Transfers to listed backends into proxy
  transfers and drops the rest.
- **A leaked proxy key lets anyone join trusting backends as any player.** Managed logins don't carry the
  player's own Xbox token, so a backend can't double-check the XUID with Microsoft.
- **NetherNet is slower than the old RakNet transport.**

  | | NetherNet | RakNet |
  | --- | --- | --- |
  | 512 B round trips (one player) | 2,712/s | 5,076/s |
  | joins | 140 to 170/s | 1,149/s |

  Each player also costs about 320 KiB of resident memory. libdatachannel sends inline, one UDP datagram and one
  DTLS record per message on the calling worker, and that is where a worker's CPU goes: stack samples of a busy
  worker found it in the kernel's `sendto`, usrsctp or mbedTLS every time and never in Bifrost's own code. One
  worker carries about 500 players at 20 messages a second each. A second worker helps; past that a loopback
  benchmark stops gaining, with every thread in the proxy at half a core or less, and a larger
  `[nethernet] threads` pool doesn't change that reliably. See `tests/bench/baseline.md`.
- **Transfers rebuild only part of the target's StartGame.** Its time, difficulty, commands flag, game rules and
  weather are sent as their own packets; other world settings in it (world spawn, default game mode, experiments)
  only reach the client if the target sends them again. Volume entities and NPC dialogue the old backend opened
  aren't tracked, so they aren't cleared.
- **A backend that kicks or drops a player before a transfer commits** is no longer fatal: its Disconnect is held
  back and the player waits on the target, but what they send in that gap is dropped. If the transfer then fails,
  the held kick reaches them, or "Lost connection to the server" when the backend just closed.
- **Signaling checks a token's P-384 signature before Microsoft's RSA one**, with no rate limit of its own, so a
  stream of garbage offers costs CPU on the workers before it's refused. The per-address connection and handshake
  caps bound it, the cost hasn't been measured.
- **IPv6 per-address limits group by /64**, so a host with a routed /48 gets many separate buckets. Only matters
  when `bind` is IPv6.
- **Large plugin packet injections on Linux** pay glibc trim and refault costs, about 10 µs per 16 KiB. That was
  measured on 1.2.1, before the NetherNet switch.
