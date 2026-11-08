# Security model (FerryPane 0.2.1)

FerryPane is a LAN-first **peer-to-peer file manager**. This document describes the security mechanisms actually implemented and their limitations. **The cryptographic protocol and key-handling code have not undergone an independent external security audit.** Do not treat this document as a formal guarantee against MITM or local compromise.

## Security properties

- First-time peers compare the **same six-digit short authentication string (SAS) on both screens**. Confirm only if they match. The numeric string is not a password and does not provide unlimited MITM resistance. Repeated attempts are rate-limited, but a targeted attacker could still interfere with or block the connection.
- Each device has a long-lived X25519 identity key; session handshakes add fresh ephemeral X25519 secrets and nonces. HKDF-SHA256 creates separate sending/receiving AES-256-GCM keys. The version-5 HKDF transcript includes both hello messages, including peer identities, ephemeral keys, names and protocol version, ordered by connection role. Subsequent command and file frames are encrypted/authenticated. Packet counters reject replays/reordering.
- LAN discovery broadcasts a per-process random session token, not the configured name or permanent public identity. IP addresses and traffic metadata remain visible, and an active handshake participant can see the public identity before pairing. File names, contents, contacts and SMS are encrypted *after* the handshake; direct control over an endpoint, a stolen private identity key, and denial of service are separate threats.
- The application accepts TCP only on a private IPv4/loopback source address; manual destinations must also resolve to private/loopback addresses. **Private address ranges alone do not prove that two devices are on the same physical LAN**: a VPN or overlay can route those addresses remotely. Use a trusted LAN and firewall.
- New incoming pairing is **closed by default**. The receiving device owner must explicitly open a **two-minute pairing window** with the lock icon. An outgoing manually initiated connection is treated as that local user's pairing intent. A previously trusted device can reconnect without reopening the window.
- WebSocket requests carrying a browser `Origin` header are refused with HTTP 403; the native Dart client does not send this header. This is defense in depth against webpages occupying the pairing slot, not a replacement for authentication.
- Once one peer is connected, another inbound connection gets HTTP 409 and **cannot evict the live authenticated session**. A single pending handshake is allowed; attempts are throttled to 6 per minute per source address. Invalid/oversized hellos and encrypted packets are rejected and initial exchanges time out. This primarily reduces nuisance/DoS, but cannot guarantee availability against a network attacker.
- New pairs receive explicit read-only grants. Missing read/write settings deny. Destructive commands (delete, rename, move, replace) require a separate per-peer opt-in, off by default even for existing trusted peers. The receiving device logs remote modifications in private bounded app preferences. Deletion is permanent; keep backups. No confirmation is needed for each action after a grant. Android contacts and SMS permissions remain separate opt-ins.
- Transfers enforce relative paths with no `..`, block symbolic-link path components, limit path size, packet size, per-file and per-transfer declared sizes, and verify SHA-256 before committing. A receiver-side **five-minute inactivity watchdog** aborts stalled transfers and removes the active temporary .part file. On Windows, unsafe/reserved device aliases are refused; this restriction is not applied to Linux/Android filenames. **Race-free filesystem containment against a malicious local process is not yet guaranteed**, because pure Dart file-open operations do not provide portable `openat`-style descriptor confinement. This deserves a later native audit.

## Protected identity keys and upgrade migration

### New installations

The original 32-byte X25519 identity seed is **not saved in plaintext SharedPreferences**. The application uses the platform secure store provided by `flutter_secure_storage`:

- **Windows:** Windows platform-protected application storage; available under the signed-in Windows user context (not a defence against malware executing as that user).
- **Android:** Android Keystore-backed encrypted app storage; app-data cloud backup is disabled to avoid restoring ciphertext without matching device keys. Some Android installations/ROMs may impose additional restrictions.
- **Linux:** Secret Service with an unlocked desktop keyring is preferred. Without it, users may explicitly select password-encrypted identity file storage (PBKDF2-HMAC-SHA256 240,000 rounds, AES-256-GCM). The password is not saved and the file is protected with mode 0600 inside a 0700 directory. Corrupt or missing keys and wrong passwords fail closed. A locked existing keyring is not bypassed; no plaintext fallback.

### Upgrading from 0.1.5

1. Before launching the network listener, FerryPane reads the OS secret store.
2. If no secured identity exists, it reads the legacy `ferrypane.identity.seed` SharedPreferences value, validates that it is exactly 32 bytes, writes it into OS secure storage, reads it back, and confirms it matches.
3. **Only after successful readback** does the program remove the legacy preference. Your original identity stays the same, so existing trusted peers and permissions are preserved. An interruption can safely retry.
4. Conflicting or inaccessible identities fail closed. On a fresh Linux system without Secret Service, users can explicitly select password-encrypted file storage, but existing inaccessible trusted identity keys are never silently recreated or replaced.
5. A password prompt may be displayed by the Linux desktop keyring when it is locked.

**Residual risk:** removing a preference is not cryptographic secure erasure. Historical copies can survive in filesystem journals, snapshots or backups. An attacker who already has an old key copy may impersonate the affected device; in this case revoke the old peer and generate a new identity through a deliberate recovery procedure (not by silently removing the key).

**Availability risk:** if the platform keyring is destroyed or the app is reinstalled, secure identities may be unrecoverable. The app deliberately does not fall back to plaintext. On Android, permissions/keys can behave differently after OS upgrades, factory resets or device migrations.

### Not the same key as APK signing

The private X25519 device identity **never leaves local protected storage as a network message**. It is distinct from FerryPane's Android APK signing certificate and from peer public identity keys. The Android release key is used only to sign packages so updates install without conflict.

## What attackers can and cannot do

| Adversary | Expected result | Limitation |
|---|---|---|
| Passive local sniffer | Sees discovery and packet metadata, cannot ordinarily read established session plaintext | No third-party cryptographic audit |
| Unknown active LAN device | Cannot read/write without explicit pairing on both devices | Can send requests, impersonate discovery names and attempt DoS |
| Unknown device while an existing transfer is active | Rejected without replacing that transfer | Heavy network flooding can still degrade availability |
| MITM during first pairing | Transcript/SAS mismatch should alert users who actually compare both codes | Six-digit SAS has limited brute-force strength; no unlimited attempts |
| Impersonator without the trusted private key | Cannot derive the authenticated session keys | If the device/key is compromised, identity authentication is lost |
| Malware already running as the logged-in user | Can potentially access files, keyring APIs or application memory | OS secure storage is not a defence against a fully compromised endpoint |
| Trusted peer | Can read permitted folder; new peers cannot write until separately allowed | Legacy trust retained existing read/write; owner must review |

## Sensitive backups

Contacts (.vcf), SMS (.json and self-contained .html) and files copied to the PC are saved **without at-rest encryption** unless your destination filesystem provides it. The SMS viewer does not fetch remote resources, but an HTML file contains readable personal data for anyone who can access it.

Android needs `READ_CONTACTS` and/or `READ_SMS` for extraction. The phone must already be paired and the specific peer must have been granted the corresponding backup right. No remote request silently grants Android OS permission. Backup/export is not permitted just because the attacker knows the phone's IP address or device name.

## Release checksums and authenticity

Since Preview.2 the release contains `SHA256SUMS` for five platform packages, generated and verified in GitHub Actions. Compare checksums of downloaded files to detect accidental corruption. A checksum file hosted beside the binaries **does not prove publisher authenticity** if an attacker can replace the whole release. Independent detached signatures or GitHub build provenance still need to be implemented and verified.

## Protocol robustness and limits

- Directory response IDs and transfer/error IDs are checked against **the current operation**. Stale replies cannot alter a newer listing or abort another transfer. Unknown command types are ignored rather than disconnecting an otherwise valid peer.
- Exporting contacts/SMS from Android reserves a transfer slot before querying Android's content provider, preventing simultaneous exports from corrupting stream state.
- Incoming and outgoing encrypted frame/chunk size checks are retained at both ends. Regular transfers still use 64 KiB chunks.
- A single incoming pairing prompt can occupy the pending slot until the user approves/rejects it or its timeout expires. This limited availability trade-off avoids spamming users with concurrent pairing dialogs; it is not a bypass of pairing authorization.
- Ephemeral X25519 contributions provide forward-secrecy properties for recorded traffic **under usual ephemeral-secret erasure assumptions**; the project has not undergone an independent cryptographic audit.

## Remaining work before a security-stable release

- Independent protocol/crypto review, fuzzing, re-authentication testing and packet traces on real Windows/Android/Linux installations.
- Descriptor-based native filesystem operations to eliminate symlink time-of-check/time-of-use races, and explicit disk space/transfer quotas configurable by the owner.
- Foreground Android service (explicit opt-in), with honest screen-off and battery behaviour.
- Better peer trust management UI for reviewing/revoking individual keys (currently the UI offers all-at-once revocation and settings for connected peer).
- Safer recovery/migration/export of keys if users intentionally replace devices, and Windows/Linux keyring behavior test matrix.
- Optional network-interface allowlists to distinguish true local networks from private-address VPNs.

For security issues use a private contact mechanism rather than publishing active exploit details in a public issue, when possible. See [README](../README.md), [architecture](ARCHITECTURE.md), and [roadmap](ROADMAP.md).
