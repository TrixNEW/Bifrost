# Architecture

How the source is laid out, which thread owns what and the path a packet takes. Limits are in
[limits.md](limits.md), the plugin contract in [plugin-abi.md](plugin-abi.md).

## Layout

| path | owns |
|---|---|
| `src/main.zig` | process start: config, logging, keys, plugins, the runtime and signals |
| `src/config/` | `Config`, plain data with defaults, and the TOML `loader` |
| `src/net/` | the NetherNet transport: `NetherNet` (dialing, tokens, native settings), `Listener` (signaling in), `Peer` (one end of a connection, with its backlog mark and drain-before-close) |
| `src/proxy/` | `Workers` (the worker set, listener dispatch, console, minute report), `Proxy` (one worker), `Link` (one player), `Scheduler`, admission, budgets, stats and the metrics endpoint |
| `src/backend/` | `Router` (which backend a player goes to), `Health` (probes, player counts, draining), `Dial` |
| `src/protocol/` | `Observer` (watches a passthrough login), `Keys` (Microsoft's signing keys, reloaded and refreshed) |
| `src/session/` | managed sessions: `Managed` holds both Bedrock sessions of one player and the packet pipeline between them, `Upstream` logs in to a backend, `ClientState` and `Gameplay` track what the client was shown, `self_id` translates the player's own ids |
| `src/transfer/` | moving a player between backends: `Transfer` drives one move, `State` is its phases and outcomes, `Handoff` the dimension changes, `Queue` the target's held packets |
| `src/content/` | pack and registry fingerprints, which decide whether two backends are compatible |
| `src/plugin/` | native plugins: `Plugins` (loading, events, settling queued work), `Host` (the C function table), `Packets` (packet hooks), `Handles` (player handles), `Work` and `Pool` (queues and task threads), `abi` and `sdk` |

## Threads

Each worker is one task, `Proxy.run`, pinned to its own executor. It owns its links: a `Link` and everything
under it (`Managed`, `Transfer`, queues, both `Peer`s) is only ever touched by that worker, so none of it is locked.

Other threads reach a worker three ways, and each ends in one wake of its event:

- the mailbox (`Proxy.adopt`, `requestTransfer`, `ask`), a small mutex-guarded inbox the worker empties every turn
- `Scheduler`, a lock-free stack that libdatachannel's threads push a link onto when it has something to read
- the plugin `Work.Queue` of that worker, which any plugin thread may post to

What workers share is atomic or has its own small lock: `Admission`, `Budget`, `Health`, `Keys` (a refcounted
snapshot), `Stats` (one writer, read by the report and metrics) and the plugin `Handles` table.

libdatachannel runs ICE, DTLS and SCTP on its own threads. They copy each message into the connection's queue and
notify; they never run proxy logic. Dials, transfer timers, health probes, the console and the metrics endpoint
are separate tasks that only post back through the three paths above.

## A packet's path

1. A native thread queues the message and notifies; the link goes on its worker's ready stack.
2. The worker's turn runs `Link.service`, which reads at most 64 messages from each side.
3. Passthrough hands the message straight to the other `Peer`. Until the Login is through, `Observer` reads the
   reliable channel to verify it.
4. Managed mode goes through `Managed.fromPlayer` or `fromBackend`. A batch nothing needs to read is relayed as
   is. Otherwise it is decompressed once and each packet passes `Batch.add`: id translation, plugin hooks, state
   tracking. If every packet came through unchanged the original frame is sent, so nothing is compressed again.

A side that falls behind stops the other from being read, see [Backpressure](limits.md#backpressure).

## Transfers

`Link.startTransfer` claims the target and creates a `Transfer`, which dials it, logs in as the player and reads
its world while the player keeps playing on the old backend. Once the target's content is known to match, the
commit swaps the backend connection and session, clears what the old backend showed, and walks the client through
the dimension change; the target's packets wait in the hold until the client is there. Any failure before the
commit rolls back and the player never notices. After it, a failure disconnects.

## Where changes go

- a config key: a `Config` field, `loader.zig`, `config/bifrost.toml` and the doc that covers it
- a counter: a `Stats` field, and a line in `Workers.writeMetrics` if operators should see it
- a host function: append to `abi.Host` (never reorder), implement in `Host.zig`, mirror in
  `include/bifrost_plugin.h` and `sdk.zig`, document in `plugin-abi.md`
- something else the client must forget on transfer: `ClientState.tracks`, `observe` and `reset`
