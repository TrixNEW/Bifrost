# Bifrost

A high-performance Minecraft: Bedrock Edition proxy written in Zig, built for fast networking, low overhead, and extensibility.

Bifrost uses [NetherNet](https://github.com/Bedrock-Phanatics/nethernet-zig) and [Bedwire](https://github.com/Bedrock-Phanatics/bedwire) to handle Bedrock connections over WebRTC.

## Features

- **High Performance** - Event-driven networking with minimal overhead.
- **Multi-Backend** - Connect players across multiple servers.
- **Seamless Transfers** - Switch servers without reconnecting.
- **Session Modes** - Passthrough and managed sessions.
- **Native Plugins** - Extend Bifrost using Zig, C, or C++.
- **Packet Handling** - Intercept, modify, and filter packets.
- **Configurable** - TOML-based configuration.

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

For Pterodactyl hosting, use the [Bifrost egg](https://github.com/Bedrock-Phanatics/pterodactyl-eggs/blob/main/bifrost-pterodactyl-egg.json).

## Documentation

- [Setup Guide](docs/setup.md)
- [Backend Support](docs/backends.md)
- [Plugin Development](docs/plugins.md)
- [Plugin API](docs/plugin-abi.md)
- [Configuration & Limits](docs/limits.md)
- [Known Issues](docs/known-issues.md)

## Development

```bash
zig build test
zig build bench -Doptimize=ReleaseFast
```
