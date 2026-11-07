# FerryPane

**FerryPane** is a planned open-source, cross-platform file manager for browsing and transferring files between devices on the same local network.

The first release targets **Windows, Linux, and Android**. Every device is a peer: it can browse remote files, expose explicitly permitted folders, send data, and receive data. There are no permanent "PC client" and "phone server" roles.

## Supported connection pairs (target for the first usable LAN release)

- Windows ↔ Windows
- Windows ↔ Linux
- Linux ↔ Linux
- Windows ↔ Android
- Linux ↔ Android
- Android ↔ Android

Transfers must work without Internet or accounts, including when one Android device provides a Wi-Fi hotspot.

## Product principles

- **File manager first.** Browse remote directories as naturally as local ones; copy folders recursively without tapping every file.
- **Native-feeling interfaces.** Two-pane desktop file manager; touch-friendly Android UI with local/remote locations and a two-pane tablet layout.
- **Same protocol on every platform.** A peer can initiate a transfer or respond to one.
- **Efficient small-file transfers.** Use a streaming batch format rather than an independent network round-trip for every file.
- **Secure by default.** Explicit pairing and verification, device identities, encrypted channels, per-peer filesystem permissions, and safe handling of destructive operations.
- **Reliable transfers.** Progress, cancel, error reporting, resume, and integrity checks.
- **Local-first.** Discover peers with mDNS where possible, with manual address entry as a fallback.
- **Future hub is optional.** Any Internet relay/server, business model, and licensing will be decided separately; no cloud dependency is part of the LAN release.

## Proposed stack

| Layer | Technology |
|---|---|
| Windows / Linux UI | C# / .NET + Avalonia |
| Android UI and platform integration | Kotlin + Jetpack Compose |
| Local transport | TLS-protected binary WebSocket streams |
| Service discovery | mDNS; manual IP fallback |
| Protocol | Versioned, language-neutral message and streaming specifications |

The protocol and security mechanisms are defined independent of platform. Cryptographic primitives will use maintained, audited libraries; no custom cryptography.

## Project status

Initial architecture and milestones are being documented. **No runnable application has been released yet.**

- [Architecture](docs/ARCHITECTURE.md)
- [Development roadmap](docs/ROADMAP.md)

## Licensing

The end-user applications are intended to be open source. The precise license will be recorded before source-code distribution. A possible future relay service is **out of scope** and is not automatically covered by client-app licensing decisions.
