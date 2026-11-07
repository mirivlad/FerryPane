# FerryPane

**FerryPane** — open-source file manager for direct encrypted file transfers between **Windows, Linux and Android** on one local network, without accounts, cloud or cables.

One Flutter/Dart peer application runs on every supported OS. Every installation can send, receive and browse files on another. Desktop displays **two file panels**; phones switch between two panels; tablets display both when the window is wide enough.

> **Status:** 0.1.1 preview / LAN bugfix release candidate. Real-device interoperability and security review remain necessary before treating it as a stable security-sensitive product.

## What works

- Browse folders on the current device and a connected peer.
- Send or receive files and whole nested folders using the **Copy** arrow buttons.
- Two Windows PCs, Windows↔Linux, Linux↔Linux, Android↔PC, and Android↔Android use the same application and wire protocol.
- Automatically discover other devices by symmetric LAN UDP probes and announcements, with manual IP connection as fallback. A refresh button forces a new scan.
- First-time peer pairing with an identical **6-digit verification code shown on both devices**; approve only if it matches.
- X25519 key exchange + session-bound ephemeral keys, HKDF-SHA256 and AES-256-GCM encrypted application packets.
- Stream batches of many tiny files over one persistent WebSocket; 64 KiB frames and bounded flow control. Each file is SHA-256 verified before finalization; interrupted files remain uncommitted.
- Incoming name conflicts are resolved by adding a numeric suffix; repeat folder transfers create a separate folder (existing files are not overwritten).
- Export root configurable in the settings; remote peers cannot navigate outside it, and symbolic links are never followed.
- No Internet required; peer can work over an Android Wi-Fi hotspot.
- Windows/Linux/Android packages built by GitHub Actions.

## Basic usage

1. Install/open FerryPane on both devices, connected to the same Wi-Fi, Ethernet LAN or Android hotspot.
2. On Android, permit **All files access** in Android's settings when prompted. Android's OS restrictions on other apps' private data remain in force.
3. On each device, review the **shared folder** in Settings. On desktop it defaults to Downloads (or home if unavailable); on Android it defaults to shared internal storage.
4. On one device, choose the other in the **Wi-Fi discovery** menu or click **Connect by IP**. If auto-discovery is blocked by the network, type the IP shown in Settings on the destination device.
5. On both devices confirm the **same** six-digit pairing code. Reject if codes differ.
6. Choose **Local** or **Remote** in either panel. Open a folder by tapping/clicking it, select one or more **files or folders** using the checkboxes, then click the arrow toward the destination panel.

The first entry in every folder is `..` (parent folder), disabled at the root. Device names are detected from Windows/Linux hostnames or Android model and can be edited in sharing settings.

The remote panel shows the root *exported* by the other device, not unrestricted access to its entire filesystem.

### Platform limitations in the preview

- Android file access is bounded by OS restrictions; **Android/data** and private app data cannot be exposed simply by granting all-files access.
- On Android, **keep the app in the foreground during transfers** for now. A persistent foreground-service implementation is not included yet.
- Linux and Windows firewalls may need inbound TCP **47655** and discovery UDP **47656** (local network only).
- The desktop archives are **portable**, not installers. Windows zip: extract and run `ferrypane.exe`; Linux tar.gz: extract the whole directory and execute `./ferrypane` (GTK runtime libraries required).
- Android APK is side-loaded; uninstalling/reinstalling without preserving app data resets pairing keys.
- Only one connected peer and one active transfer per application are supported in this preview.
- **No hub, synchronization, directory deletion, remote rename or resumable interrupted transfer yet.** Incomplete copies are rejected; retry starts the affected copy anew.
- Automatic discovery uses **UDP broadcast**, not mDNS yet; use manual IP if blocked. On Windows, allow inbound TCP **47655** and UDP **47656** for the application on a **Private** network. Your own device is intentionally excluded from its discovery results.
- Authentication keys currently live in the application's private preferences; hardware-backed keystore integration is future work.
- All devices must be updated together for protocol v2; preview.1 clients cannot connect to this version.
- The session security mechanism is new and has not undergone an independent cryptographic audit; do not treat the preview as suitable for hostile networks or high-risk secrets.

## Build from source

Install Flutter stable, a supported platform toolchain, and for Android the Android SDK/JDK 17.

```bash
bash tool/prepare_platforms.sh
flutter run -d linux      # or: -d windows / <Android device ID>
flutter build linux --release
flutter build windows --release
flutter build apk --release
```

Platform folders are generated locally by `flutter create`; `tool/patch_android.py` applies Android LAN and storage permission entries. They are intentionally not committed to Git.

GitHub Actions builds Windows, Linux, and APK artifacts on every PR/push. A `v*` tag also publishes a release with the three packages.

## Project layout

- `lib/core/files.dart`: safe file and path handling.
- `lib/core/secure_peer.dart`: handshake, trust, authenticated encryption.
- `lib/core/service.dart`: local WebSocket server, discovery, peer operations.
- `lib/core/transfer.dart`: streamed directory/file transfer and checksums.
- `lib/main.dart`: adaptive two-pane file manager.
- `docs/`: architecture and roadmap.
- `test/`: filesystem path-security tests.

## Licensing

FerryPane client application is licensed under **GNU GPL version 3 or later**; see [LICENSE](LICENSE). A possible future internet relay/hub is a **separate, undecided project**, and its license/business model is not determined by the client-app license. A public protocol can be implemented by independent software.

Contributions, testing reports and bug fixes are welcome.
