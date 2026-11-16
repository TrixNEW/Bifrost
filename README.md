# Bifrost

A high-performance Minecraft: Bedrock Edition proxy written in Zig, built for fast networking, low overhead, and extensibility.

Bifrost uses [NetherNet](https://github.com/Bedrock-Phanatics/nethernet-zig) and [Bedwire](https://github.com/Bedrock-Phanatics/bedwire) to handle Bedrock connections over WebRTC.

## Features

- **Xbox-verified logins** - Checks every login against Microsoft's keys and logs in to trusting backends on the player's behalf.
- **Routing** - Join pools, fallbacks, capacity limits and draining, with health checks.
- **Seamless transfers** - Switch servers without reconnecting.
- **Native plugins** - Zig, C, or C++23 with a thin header-only wrapper.
- **Operations** - Console commands, Prometheus metrics and categorized logs.

## Building

Requires Zig 0.17.0, Git, CMake, and a C/C++ toolchain. *(Depending on your usecase)*

```bash
git clone https://github.com/Bedrock-Phanatics/Bifrost.git
cd Bifrost

# Linux
sh tools/setup-native.sh

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File tools/setup-native.ps1

zig build -Doptimize=ReleaseSafe
```

## Running

```bash
./zig-out/bin/bifrost
```

Configure Bifrost in [`config/bifrost.toml`](config/bifrost.toml).

Linux x86_64 builds are on the [releases page](https://github.com/TrixNEW/Bifrost/releases). They need glibc 2.35 or newer
(Debian 12, Ubuntu 22.04). Extract the archive and start it with `./run.sh`.

For Pterodactyl hosting, use the [Bifrost egg](https://github.com/Bedrock-Phanatics/pterodactyl-eggs/blob/main/bifrost-pterodactyl-egg.json). Set `BIFROST_REF` to `main` or a release tag such as `v1.0.0`.

## Documentation

- [Setup Guide](docs/setup.md)
- [Running Bifrost](docs/operations.md)
- [Backend Support](docs/backends.md)
- [Plugin Development](docs/plugins.md)
- [Plugin API](docs/plugin-abi.md)
- [Configuration & Limits](docs/limits.md)
- [Architecture](docs/architecture.md)
- [Testing](docs/testing.md)
- [Known Issues](docs/known-issues.md)

## Development

```bash
zig build test
zig build bench -Doptimize=ReleaseFast
```
