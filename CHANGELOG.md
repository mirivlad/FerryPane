# Changelog

All versions are development previews until the project has passed the device and security acceptance criteria.

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
