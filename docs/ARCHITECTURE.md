# FerryPane architecture — LAN-first, symmetric peers

Status: initial architecture proposal (2026-11-07). No implementation yet.

## 1. Central abstraction: Peer

FerryPane is not a desktop client plus an Android server. Every installation is a **Peer** with the same conceptual capabilities:

- **Browse** local and remote file trees.
- **Serve** the subset of local files authorized for remote access.
- **Initiate** copy, download, upload, and eventually file-management operations.
- **Receive** and process requests from a paired peer.
- **Send** and receive data streams.

The peer role is **per operation**. For example, a phone can browse a desktop and ask it to send a directory; the same phone may concurrently serve another phone's directory listing. No special code path for PC↔phone, PC↔PC, or phone↔phone should exist in the protocol.

## 2. Platform-neutral architecture

```text
    Windows peer                 Linux peer                 Android peer
  +----------------+          +----------------+         +------------------+
  | Flutter UI     |          | Flutter UI     |         | Flutter UI       |
  | Desktop FS     |          | Desktop FS     |         | Android FS       |
  | adapter        |          | adapter        |         | adapter          |
  +-------+--------+          +-------+--------+         +---------+--------+
          |                           |                            |
          +------ same wire protocol, identity, permissions ------+
                   LAN peer discovery + direct secure session
```

Initial implementation stacks:
- All platforms: Flutter/Dart, using a shared protocol implementation and platform-adapted filesystem access and UI.
- Android: Flutter UI with Android storage permissions; later add a native foreground service for background transfers.
- One shared wire implementation for all platforms, plus cross-platform integration tests.

The desktop can show any pair of sources in its two panes, not only local-versus-phone. Android shows local and connected devices in a location selector; on phones it uses a single pane and explicit target selection, while tablets can use two panes.

## 3. Connection and identity

- Direct LAN connections only in the initial release.
- UDP LAN broadcast advertises discoverability and a local endpoint (mDNS may be added later). Manual IP/hostname entry is essential for multicast-blocked Wi-Fi networks and hotspots.
- Devices possess persistent identity keypairs.
- First pairing requires an interactive confirmation with a QR code or comparison code that authentically binds the peer identity keys. The peer identity is pinned for subsequent sessions.
- Use maintained libraries and well-reviewed cryptographic handshakes; do not invent cipher suites or homemade key exchange.
- Transport: WebSockets with X25519 mutual-authentication pairing and AES-256-GCM for application frames; the session is end-to-end encrypted so a future *optional* byte-forwarding relay will not need plaintext access.
- Protocol versioning and feature negotiation are mandatory before file operations.

The future hub is expressly **not** part of this milestone: no NAT traversal, account system, service dependency, or commercial-license assumption. In a later relay mode, both peers may make outgoing HTTPS/WSS connections to port 443; the hub can forward opaque encrypted frames. The application/session identity must remain independently verified so a compromised hub cannot silently substitute a peer key.

## 4. File operations and wire model

A connection separates small request/response/control messages from bulk transfer frames. Suggested v1 operation families:

| Family | Examples |
|---|---|
| Session | hello, negotiated_capabilities, pairing, keepalive |
| Filesystem | list_directory, stat, get_volumes, mkdir |
| Transfers | start_transfer, manifest_entry, file_begin, chunk, file_end, transfer_result |
| Task control | progress, cancel, resume, error |
| Future mutating ops | rename, move, delete (explicit authorization and UI confirmation) |

Each operation has a request/transfer ID, protocol version, capability constraints, and structured errors.

### Path and permissions

Remote access is scoped to **named export roots**, each with a stable opaque ID and an allowed set of capabilities. File paths inside a root are relative and normalized; never accept absolute paths, `..` escapes, or traversal through symlinks outside the root. Permission checks occur server-side on **every** operation, not just when listing.

Desktop exposes nothing by default: a user approves locations and grants read-only or read-write access per paired peer. On Android, access is limited by OS storage permissions and user-exported roots; requests never bypass Android sandboxing. Android's all-files permission does **not** provide universal access to other apps' private data or restricted Android/data paths.

On Android, UI access and remote service access are separate capabilities. Deleting/replacing files is disabled until explicitly authorized. The UI must show which devices are connected and what they may access; pairing can be revoked.

### Efficient and safe transfers

- A single batch transfer session streams many file metadata records and file bytes; no per-file network request is required for tiny files.
- Directory manifests may be produced incrementally (avoid generating huge manifest files or loading all entries into memory).
- Payloads are length-framed binary chunks with backpressure and bounded buffering.
- Files are written to temporary `.part` files in the destination and committed on successful verification, when filesystem support permits.
- File sizes, last-modified times, and integrity information accompany the manifest. Checksums can be computed incrementally; resume verifies previously received data rather than blindly trusting offsets.
- Defined conflict policies: ask, skip, rename, overwrite; never silently overwrite or delete.
- Clear per-file errors for vanished files, read-denied paths, full destinations, etc.; continue other eligible files where possible.
- Transfer can be cancelled; restarting should not leave a silently corrupted final file.
- Baseline benchmarks must include 1 large file and tens of thousands of tiny files. Compare against SFTP without assuming a numeric speedup.

Do not promise full metadata or permission preservation across different filesystems. Support only portable metadata where it makes sense.

## 5. Android service lifecycle

The Android build has **both** a remote file service and a local/remote file manager. Service activation is user-visible and may run as a foreground service during active transfer, with notifications and cancellation. It must respect current Android foreground-service restrictions; it must not promise an indefinitely running silent daemon.

Android 17 apps targeting API 37+ need to handle local-network access permission. Broad external-storage access, when used, is a separate special permission with restricted access to Android app-private directories; the normal file manager should handle denied permissions gracefully.

Android-to-Android transfer must work over an existing WLAN or an Android hotspot, without Internet and without introducing a separate mobile-to-mobile protocol.

## 6. Future-proofing without premature hub implementation

The boundary between UI, device file operations, encrypted message protocol, and connection establishment is intentional:

- Filesystem operations don't know whether the peer is a phone or desktop.
- The transfer manager doesn't know whether the peer was discovered by mDNS or entered manually.
- The future hub could forward already-encrypted protocol frames without accessing files or trusted keys.
- The hub's implementation, source availability, charging model, and legal license remain a separate future decision.

## 7. Provisional repository structure

```text
/
  lib/                 # Shared Flutter UI, peer, protocol, filesystem and transfers
  tool/                # Platform generation and manifest permissions
  test/                # Protocol, transfer, security and end-to-end tests
  docs/
    ARCHITECTURE.md
    ROADMAP.md
```

Implementation can refine module boundaries without changing these product principles.

## 8. Security and performance acceptance

- No unpaired device may read or modify a file, even if it knows an IP and port.
- A paired peer sees only explicitly exported roots and authorized actions.
- Identity binding must survive reconnection and detect an unexpected key change.
- A malicious filename/path cannot escape the authorized root or write beyond a destination root.
- Truncated/interrupted transfers must never masquerade as completed files.
- A large directory tree must not exhaust RAM by requiring a full in-memory manifest.
- A phone can browse/copy from another phone directly in a local network.
- Unit/integration tests verify matching wire messages across Kotlin/.NET implementations.
