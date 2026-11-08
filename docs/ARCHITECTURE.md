# FerryPane architecture

This file describes the **implementation in v0.1.5 Preview**, not just an aspirational design. The project began in November 2026.

## Runtime model

FerryPane is one **Flutter/Dart** peer application on Windows, Linux and Android. A device can both offer its configured local folder to trusted peers and browse another device's exported folder. One connected remote peer is supported at a time.

```text
    Windows / Linux / Android               Windows / Linux / Android
    ┌────────────────────────┐              ┌────────────────────────┐
    │ Flutter two-pane UI    │              │ Flutter two-pane UI    │
    │  ├─ Local filesystem   │              │ Local filesystem ─┐   │
    │  └─ Remote browser     │              │ Remote browser ──┘   │
    │ FerryService           │              │ FerryService           │
    │ SecurePeer             │◀────────────▶│ SecurePeer             │
    └────────────────────────┘   LAN WSS*   └────────────────────────┘
                    * WebSocket with application-layer AES-GCM
```

The actual LAN socket uses **`ws://`** with a separate mutually paired, encrypted application session; it is **not TLS WSS yet**. The original internet-hub architecture envisages WSS, but this is deferred. The handshake uses persistent X25519 identity keys, temporary X25519 keys, HKDF-SHA256 and AES-256-GCM. Peers compare a six-digit short authentication code on **both devices** when first pairing. Trust persists in the application's local preferences. This is a custom protocol that **has not been externally audited**; it is not a substitute for a standard audited protocol on hostile networks.

## Discovery and network routing

- TCP **47655**: direct WebSocket service, upgraded to encrypted application frames after handshake.
- UDP **47656**: broadcast probes/announcements. Discovery is **not mDNS** at present.
- Per-interface directed broadcasts for eligible private IPv4 networks; fallback to a limited broadcast when prefix information is missing. No public Internet host/subnet scanning.
- Windows: PowerShell `Get-NetIPAddress`; Linux: `ip -j -4 address show`; Android: Kotlin `ConnectivityManager` and `Network.bindSocket` to probe Wi-Fi/Ethernet even when a VPN is the default route, where Android policy allows it.
- Manual IP connection and cached host addresses for paired devices, because VPNs, firewalls and hotspot isolation can block discovery.

Android VPN lockdown can prevent direct physical-network sockets, and FerryPane cannot override that.

## File transfer

- The sender and receiver use a **continuous batch stream** with transfer/control JSON messages and binary data frames. Many small files share the connection rather than each needing an independent request/response.
- Data chunks are bounded to limit buffering; flow acknowledgements throttle transmission.
- Directory entries are streamed recursively; no full in-memory manifest is required.
- Paths are relative to the receiver's permitted root. Absolute paths, traversal and symbolic-link paths are rejected.
- Incoming content is written to temporary files, checked using SHA-256, then finalized. Conflicting filenames/folders get unique suffixes rather than overwriting.
- Multiple concurrent peers, transfer queue, resume, sync, remote delete/move and cancellation are **not implemented**.

Local copy paths and export roots are constrained by the operating system. For Android, All-files access does not include application-private data or all restricted directories.

## Personal-data backup and contact import

Android Kotlin code (under `tool/android/`) provides a `MethodChannel` bridge:

- **Contacts export:** read Android ContactsProvider with `READ_CONTACTS`, serialize as vCard `.vcf` in a private temporary folder, transfer to the requesting trusted desktop and remove the temporary copy.
- **SMS export:** read Android Telephony.Sms with `READ_SMS`; produce `ferrypane.sms.v1` JSON with timestamps, direction and optional contact names. On the PC, Dart generates a **self-contained HTML viewer** with embedded Base64 data, local search and `textContent` rendering to prevent SMS text becoming executable markup. No MMS, RCS or deleted messages.
- **Backup authorization:** two independent checks: saved one-time opt-in **for the exact paired peer key**, and actual Android permission. The UI reads native effective grants and shows an off/warning state if Android revoked a permission after an update. No additional dialog appears on the phone for an already-authorized export.
- **Restore contacts:** selected `.vcf` is transferred into an isolated app cache on a **working Android phone**. Kotlin parses and previews entries, and after user confirmation adds missing contacts or adds missing phone/email data to likely matches through ContactsProvider. No deletion or destructive replace. Photos and advanced vCard attributes are not restored yet. Account selection and duplicate handling may be incomplete; further device tests are required.
- **Restore SMS:** intentionally not implemented.

**Broken-screen recovery is only pre-authorized export.** The Android process must stay running; foreground service/restart support is not in the current release.

## User interface and packaging

Flutter Material 3 with two panels on wide windows and a switchable single panel on narrow phones; local and remote locations are symmetrical. RU/EN catalog is in `lib/core/localization.dart`; choice persists through SharedPreferences, system locale is the default. System dialogs use Flutter localization delegates where applicable.

GitHub Actions:
- Linux tarball + DEB, built from the Flutter Linux x64 release bundle.
- Windows portable ZIP + NSIS per-user EXE setup, built from the Flutter Windows x64 release bundle.
- Android APK, with a **permanent pinned release-signing certificate** on version tags; untagged builds produce only debug validation artifacts.

Platform folders are regenerated by `flutter create` using `tool/prepare_platforms.sh`; Kotlin, manifest and signing modifications are applied by `tool/patch_android.py`. The release key is stored privately outside the public repository.

## Security boundaries and open questions

- Paired devices can read/write files **within the selected export root**. Per-peer read-only vs write roles are not yet implemented.
- File transfer encryption is application-level; discovery broadcasts are not authenticated. A discovered device still cannot access private data until trusted.
- The application does not claim invisible Android background persistence or bypass SMS/Android filesystem restrictions.
- There is no WAN hub, internet relay or user-account backend. If introduced, it must preserve peer-to-peer verified keys and never expose plaintext to the hub.
- An independent cryptographic review, fuzz testing, extensive device matrix and performance benchmarks remain necessary before treating FerryPane as stable security infrastructure.

See [README](../README.md), [roadmap](ROADMAP.md), [phone backup](PHONE_BACKUP.md) and [signing](SIGNING.md).
