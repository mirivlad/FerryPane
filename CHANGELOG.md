# Changelog

From 0.2.0 releases are published without Preview branding. No independent security audit or broad real-device acceptance is implied.

## 0.2.1 — security hardening

- Missing read/write permissions now deny; fresh pairings explicitly get read-only.
- Remote delete, rename, move and replace require a separate destructive grant,
  off by default. Receiver logs started, rejected, completed and failed file operations.
- Linux without Secret Service may explicitly choose password-encrypted file
  identity storage (PBKDF2-SHA256 and AES-256-GCM). Locked existing identities
  never silently downgrade or regenerate.
- UDP discovery advertises short-lived random tokens, not the persistent
  identity or configured device name. Windows listener binds exclusively.
- Removed unused Android Kotlin copies; updated architecture and security docs.
- No independent audit or broad Android foreground acceptance is claimed.

## 0.2.0 — full dual-panel file manager

- Both local and remote panels support creating folders, renaming, confirmed recursive deletion, same-device copy and move, plus cut/copy/paste.
- Handle name conflicts with explicit skip/keep both/replace policies. Stage and SHA-256-verify copies before committing; no implicit overwrite.
- Sort by name, size, modification date or file type, inspect basic properties and search nested folders with bounded traversal.
- Encrypted protocol v5 adds permission-checked file operation and search RPCs. Remote filesystem changes require per-peer write access. Older clients are intentionally incompatible; update both endpoints.
- Cross-device moves use complete transfer receipts and SHA-256 tree comparisons before conditional source deletion. Existing destination names and changed sources are rejected; interrupted transfers retain their originals.
- Normal non-prerelease tag and installer/APK artifacts; Android device-specific background limitations still apply.

## 0.1.8 Preview — opt-in Android foreground recovery

- Added an explicit Android foreground connected-device service with visible ongoing notification and enable/disable control in Settings.
- Only identities paired before entering background can connect. Existing per-peer read/write rights and separate contacts/SMS export permissions remain mandatory; new pairing and contact imports still require interactive UI.
- Headless Android Flutter engine and registered native Android plugin handle LAN, contacts/SMS access when the UI is not visible.
- App and worker hand off the TCP listener without opening two competing servers, with peer grant refresh and regression tests.
- No auto-start after reboot, forced termination recovery guarantee, VPN lockdown bypass, or unattended new pairing. Real-device acceptance across Android manufacturers is still pending.

## 0.1.7 Preview — resumable LAN file copying

- Per-file encrypted resume protocol v4 with verified source SHA-256 and separately verified retained-prefix checksums. Only missing bytes are transmitted; source revisions never corrupt existing files.
- Durable receiving-side journals and staged partial files scoped to receiving folder, selected source paths and trusted device identity. Repeated folder transfers reuse matching completed files without creating directory or file duplicates.
- One user-initiated unfinished copy is saved to local preferences across application restarts. Bounded automatic reconnection, explicit pause/resume/cancel and current-file progress, throughput and ETA.
- Keep resumable data on unexpected disconnect; only completed files are published after full checksum verification. Hidden state is excluded from remote file listing/copy operations.
- Ordinary personal Android contact/SMS backup/import remains separately permissioned and is not automatically replayed.
- Requires **both devices to run protocol v4** (0.1.7); prior pairing identity and access rights are unchanged. Disk journal cleanup for abandoned jobs and dedicated Android foreground persistence remain future work.

## 0.1.6 Preview.2 — protocol stability hotfix

- Correlate directory listings and transfer errors by request/transfer ID; stale responses cannot cancel or replace the next operation.
- Close a real concurrency race in Android contacts/SMS backup preparation: reserve the transfer slot before asynchronous export.
- Explicit sender/receiver encrypted-frame and chunk limits without changing existing 64 KiB streaming chunks.
- Ignore unknown command types safely instead of aborting unrelated transfers; report correlated failures to the user.
- Receiver transfer inactivity watchdog: abort and remove the current .part file after **five minutes without progress**, without limiting total copy duration.
- Reject unsafe Windows device filenames only on Windows receivers; preserve normal Linux/Android filenames.
- Refuse browser-origin WebSocket requests without changing native LAN clients; add regression tests.
- Release binaries now include SHA256SUMS verified by CI. Checksums alone are **not signatures** and do not establish publisher authenticity.
- Protocol remains v3, identity keys and existing pairings are unchanged. No added confirmation dialogs.

## 0.1.6 Preview

- Migrated existing device identity seeds into OS-protected storage (Windows protected storage, Android Keystore, Linux Secret Service), with verified readback and fail-closed recovery of legacy identity/trust.
- First pairing is now closed by default; the receiver must open a visible two-minute pairing window. Added explicit disconnect control.
- New pending connections no longer displace active sessions. Added local-address restrictions, per-source connection throttling, handshake timeouts and frame-size limits.
- Protocol v3 includes ordered handshake transcripts in session key derivation; identity trust is saved only after encrypted ready confirmation. Both sides must upgrade; paired device identities are retained.
- Newly paired peers have read-only access by default; the owner can separately grant read/write, while previously trusted peers preserve their old permissions.
- Hardened transfer paths, entry count and declared size limits; disabled Android automatic app-data cloud backup for Keystore consistency.
- Added migration/session-isolation tests and published a security threat model in `docs/SECURITY.md`.
- This is not a third-party security audit; Linux requires an available, unlocked Secret Service keyring.

## 0.1.5 Preview

- **Permissions:** Android settings show actual platform-granted contacts/SMS access instead of treating stored FerryPane grants as proof that the OS permission is still active. Revoked permissions can be requested again; settings provide an explicit refresh.
- **Backup usability:** after a verified contacts or SMS backup, reveal the saved file in Windows Explorer or Linux's file manager (fallback: containing folder).
- **Notifications:** bottom toasts and connection status have shorter display periods and can be dismissed with a click/tap.
- **Localization:** Russian/English GUI on Windows, Linux and Android, with automatic language selection and persisted override; offline SMS viewer translated as well.
- **Installers:** Debian/Ubuntu `.deb` and NSIS Windows `.exe` setup alongside the existing portable ZIP/TAR.GZ and signed Android APK. CI checks that the installers actually install their expected files.
- **Docs:** rewritten English README and Russian README, actual architecture, roadmap, permission guidance and release limitations.

## 0.1.4 Preview

- Fixed personal-data backup completion reporting: wait for successful transfer, display saved file locations and refresh desktop folder view.
- Standalone offline SMS HTML conversation viewer with search, plus JSON archive.
- Basic in-app Android contact import/merge after preview and explicit confirmation.
- Select all entries in either file panel, excluding parent `..`.

## 0.1.3 Preview

- Distinct file-copy buttons showing source pane and selection counts.
- Windows drive chooser and native desktop shared-folder chooser.
- Pre-authorized Android contacts and SMS export permissions for a previously paired PC.
- Permanently signed APK update chain continued.

## 0.1.2 Preview

- Per-interface private-LAN discovery, including Android network-bound probes under VPNs where the system permits.
- Introduced stable Android APK release certificate and signature checks in GitHub Actions.

## 0.1.1 Preview

- Discovery and reconnect improvements, device names, parent `..` entry and transfer-session stability fixes.

## 0.1.0 Preview

- Initial local-first Flutter file manager for Windows, Linux and Android, direct encrypted connection and recursive streaming transfers.
