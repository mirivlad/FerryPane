# FerryPane roadmap

**Current state: v0.1.6 Preview (November 2026).** The GitHub release artifacts are useful for LAN file transfers, but security-sensitive and Android recovery functions still need real-device validation. Items below distinguish implemented work from planned work.

## Implemented in preview releases

- [x] Shared Flutter/Dart client for Windows, Linux and Android.
- [x] Peer discovery on private IPv4 local interfaces, direct IP fallback and VPN-aware Android network probing.
- [x] First pairing with human-verifiable six-digit code, persistent trust identity and encrypted application payload.
- [x] Two-panel file manager, navigation with `..`, independent multi-selection, Select all, per-panel copy directions and Windows volume selector.
- [x] Continuous, bounded, SHA-256-verified streaming transfer of files and nested folders.
- [x] User-selected shared export directory (desktop native folder picker).
- [x] Android contacts export to vCard and SMS export to JSON + standalone offline HTML viewer (subject to Android permissions).
- [x] In-app contact import/merge on Android after explicit preview/approval (common fields only; real-device acceptance still pending).
- [x] First pairing window closed by default, with a two-minute manual authorization window, and safeguards preventing untrusted clients from displacing an active session.
- [x] OS-protected identity seed with verified migration from pre-0.1.6 plaintext preferences, preserving prior device identities.
- [x] Protocol v3 with transcript-bound HKDF/SAS, per-peer read/write permissions, local-address connection restrictions, handshake timeouts and resource limits.
- [x] Persistent Android APK signing identity for updates since v0.1.2.
- [x] Russian/English GUI with System language selection.
- [x] Windows portable ZIP and EXE installer; Linux TAR.GZ and DEB installer; Android APK.
- [x] Unit/integration CI for Linux and platform build checks; initial peer upload/download regression tests.

## Near-term priorities

1. **Device acceptance:** test Windows 10/11, Debian/Ubuntu, common Android vendors with and without VPN, Wi-Fi hotspot, mixed file trees and real permissions (including automatically revoked Android grants).
2. **Reliable Android background service:** explicit, opt-in foreground notification/service and realistic screen-off/process-restart behavior for a phone paired in advance. Do not promise recovery after shutdown, new pairing on a broken screen or override of OS security.
3. **Contact import quality:** test vCard 2.1/3.0/4.0, country codes, multiple accounts and contact properties; avoid incorrect merges and import duplicates; offer clearer dry-run details and selective import.
4. **Transfer UX:** progress per file, clear error recovery, interruption/retry, cancellation, speed indicators, and larger batch benchmark suite (large files and 10k/100k tiny files).
5. **Security engineering:** fuzz filesystem paths, protocol versioning/capabilities, independent cryptographic review and secure storage for identity keys.
6. **Localization quality:** review translations with native speakers, add translation regression checks and optionally more languages.
7. **Documentation and website:** after a tested release, publish the project page/announcement on mirv.top and a Telegram-channel post. Do not claim previews are audited or fully background-capable.

## Deferred product work

- WAN relay/hub over HTTPS/WSS: separate architectural and possibly commercial decision. Client source remains GPL.
- Directory synchronization, multi-peer sessions, drag-and-drop, delete/rename/move and comparisons.
- File previews, metadata preservation, better Android scoped-storage/SAF integration.
- Android foreground-service startup/reboot policy and managed backup jobs.
- macOS/iOS clients.
- SMS restoration: **explicitly not planned for this stage**. Export to searchable offline HTML is the desired workflow.

## Release criteria

- Automated Flutter/Dart tests and all three target builds pass.
- Tagged release publishes and verifies all **five** artifacts: Windows ZIP+EXE, Linux TAR.GZ+DEB, signed Android APK.
- Smoke test installing/updating Android without erasing paired-device identity and with the new Android system-permission status accurately reflected.
- Verify file manager reveal on Windows/Linux, dismissible notifications and RU/EN labels on both desktop and Android.
- Validate archive creation, open SMS HTML with networking disabled, and round-trip contacts on a spare Android phone.
- Clear release notes honestly distinguishing tested behavior from limitations.

See [README](../README.md) and [architecture](ARCHITECTURE.md).
