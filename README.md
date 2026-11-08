# FerryPane

**Open-source, local-first file manager for Windows, Linux and Android.**

FerryPane connects two devices on a local network and lets you browse, select and copy files between them through a two-panel file manager. No account, public server, cloud upload or USB cable is required. PC ↔ Android, PC ↔ PC and Android ↔ Android all use the same application and encrypted transfer protocol.

**Русская документация:** [README.ru.md](docs/README.ru.md).

> **Current status: 0.1.8 Preview.** This is a functional preview, not a security-audited production release. File transfers, recovery of contacts and SMS archives should still be tested on your devices. Android foreground recovery is opt-in and requires real-device acceptance; Android may stop services under battery, VPN or manufacturer policies.

## Highlights

- **Two file panels.** Switch either panel between local and remote files, navigate with `..`, select individual files, directories or **Select all** (folders are copied recursively).
- **Works without the Internet.** Connect via ordinary Wi-Fi, Ethernet or a phone hotspot. Find peers on private IPv4 subnets, or enter an IP address manually. VPN policies and firewalls may restrict discovery.
- **Pair once.** On the receiving device explicitly open the lock icon's two-minute pairing window; then connect from the sender and compare the six-digit code on **both** devices. New peers get read-only shared-folder access; enable writing on the receiving device if needed. Trusted identities are remembered and the protocol v4 session encrypts data with transcript-bound X25519/HKDF/AES-GCM. **Both ends must run protocol v4 (0.1.7 or later).**
- **Streaming transfer with real resumption.** Many small files share one encrypted connection. Interrupted ordinary file copies retain verified prefixes in a hidden destination-side journal and can restart from the last checked offset. Already completed matching files are skipped; revised source files receive a new name instead of replacing the old copy. Full SHA-256 is verified before a file becomes visible.
- **Automatic recovery and control.** FerryPane remembers one unfinished user-initiated copy (selection, target and trusted peer), attempts bounded automatic reconnects, and can continue after the application is restarted. Current-file progress, speed and ETA are visible; Pause / Resume / Cancel operate without another pairing. On Android, an optional, visibly notified foreground service can accept previously trusted peers when the UI is closed; Android can still terminate the service.
- **Android opt-in foreground service (0.1.8).** Enable **Background access to this phone** in Settings while the phone is working. It runs a visible notification and serves only already paired peers, with existing file and personal-data permissions. Disable it from Settings; new pairing requires the interactive UI. This is a preview, not guaranteed after reboot, force-stop, Doze, VPN lockdown or vendor battery restrictions.\n- **Phone backups.** Export Android contacts to `.vcf` and SMS to both structured `.json` and a standalone, searchable, offline `.html` conversation viewer. The desktop reveals the saved file in the file manager.
- **Restore contacts in FerryPane.** Send a `.vcf` from PC to a functioning Android phone; review new/matched counts, confirm and merge using Android ContactsProvider. Existing contacts are not deleted. Some advanced vCard fields (photos and less common attributes) are not restored.
- **Russian / English UI.** Settings → Interface language: System, Русский, English. Language preference is preserved across application restarts on all three platforms.
- **Portable and installed versions.** Windows ZIP or EXE installer, Linux TAR.GZ or DEB package, Android APK.

## Downloads

Get the latest preview from [GitHub Releases](https://github.com/mirivlad/FerryPane/releases).

| Platform | Files | How to use |
|---|---|---|
| Windows x64 | `FerryPane-windows-x64-setup.exe`, `FerryPane-windows-x64.zip` | Run the per-user installer, or extract the whole ZIP and launch `ferrypane.exe` |
| Debian/Ubuntu x64 | `FerryPane-linux-amd64.deb`, `FerryPane-linux-x64.tar.gz` | Install the DEB with `sudo apt install ./FerryPane-linux-amd64.deb`, or extract TAR.GZ and run `./ferrypane` |
| Android | `FerryPane-android.apk` | Install APK on the phone/tablet and grant the required Android permissions |

The Windows EXE installer installs to the current user's `%LOCALAPPDATA%\Programs\FerryPane` and creates shortcuts and an uninstall entry. The Linux DEB installs to `/opt/ferrypane` and adds a desktop application entry.

**Android updates:** APKs since v0.1.2 use a permanent, pinned signing certificate and should install in place. Older v0.1.0/0.1.1 APKs used temporary keys and require a one-time uninstall. Updating Android can also cause the operating system to revoke sensitive permissions: **an enabled FerryPane backup toggle is not evidence that Android still permits access.** v0.1.5 checks the actual Android grant and offers to request it again. See [Android signing](docs/SIGNING.md).

## First connection

1. Launch FerryPane on both devices and connect them to the same LAN or hotspot.
2. Review the **Shared folder** and **Device name** in Settings. Remote devices can access only the configured shared folder, subject to Android filesystem limits.
3. Choose a device from the discovery menu, or use **Connect by IP**. Firewalls may require inbound TCP **47655** and UDP **47656** on private networks.
4. **For a first connection**, tap the closed-padlock icon on the **receiver** to open pairing for two minutes; then connect from the other device. Compare the six-digit codes on **both** screens. Only accept if they match. If reconnecting an existing trusted device, the pairing window is not needed.
5. Select **Local** or **Remote** independently in either panel. Browse directories, tick files/folders or choose **Select all**, then click the appropriate *Left → Right* or *Right → Left* button. **For a new peer, enable write access in the destination device's Settings** before uploading files; previously paired devices keep their original rights.

For local network discovery under VPNs such as NaiveProxy, FerryPane tries each suitable private IPv4 interface. Android VPN lockdown may still prohibit bypassing the tunnel. This is an Android/VPN policy, not an authorization FerryPane attempts to override.

### Interrupted copying and resumable folders

When a transfer is interrupted, FerryPane leaves the current incomplete file in a hidden **`.ferrypane-resume/`** directory under the *receiving* folder, and records the trusted sender's public identity, source selection and intended destination. After reconnection, already completed files are compared to their source SHA-256 and skipped. A partial file's saved prefix is SHA-256 checked independently on both sides, then only the remaining bytes are transmitted. A changed source is never appended to an unrelated partial file or used to overwrite an existing completed file.

The original copy request is stored on the requesting device for recovery after an app restart. Automatic reconnection makes a bounded number of attempts; if the device is unavailable, use **Resume** or reconnect to that device manually. **Pause** keeps partial data. **Cancel** stops the operation and discards its active partial file, but leaves previously completed files untouched. File hashing runs on the local disk before transfer; expect some checking time for very large files.

The hidden resume directory is internal state and is not offered to remote file browsers. Do not manually delete it during an active or resumable operation. Old aborted jobs can leave staged bytes until cleaned up; automatic background garbage collection is not implemented yet. Android contacts/SMS backups and contact imports remain separate, consent-protected operations and are not automatically retried as resumable file copies.

**Compatibility:** protocol v4 requires **v0.1.7 on both devices**. The update retains stored device identities and previously approved trust/permissions; no re-pairing should be necessary. Resuming a transfer originally started with v0.1.6 is not supported (that version deleted partial files on interruption).


## Phone contacts and SMS

To prepare for unattended **export** from a phone with a damaged screen:

1. While the phone still works, pair it with the trusted PC.
2. On the phone, open **Settings** while connected to the PC, enable **Contacts backup** and/or **SMS backup** for that specific computer, and grant the corresponding **Android system permissions**. Some Android versions restrict SMS access.
3. On PC, open the destination folder in a local panel and click **Back up contacts** or **Back up SMS**.
4. The operation waits for the received file to be verified, refreshes the local panel, displays its full path, and opens the file manager with the file selected (or opens the containing folder on Linux without FileManager1 support).

Backing up contacts/SMS requires *both* the trusted-peer grant and the Android OS permission. FerryPane does **not** ask for another confirmation on the phone for every backup. The app must still be running; a reliable Android foreground recovery service is **planned, not delivered**.

To **restore contacts**, use **Restore contacts** on PC and select a `.vcf` file. The working phone must confirm the preview inside FerryPane. Changes are additive; recheck contacts after import. **SMS restore is intentionally not supported**: browse the offline HTML instead. SMS export does not cover MMS, RCS or deleted messages.

**Privacy:** exported contacts and messages contain personal data. The offline HTML has embedded data, no external scripts, fonts or network dependencies; keep both HTML and JSON in a protected folder.

More details: [Phone backups and permissions](docs/PHONE_BACKUP.md).

## Known limitations

- Only one connected peer and one active copy at a time; no directory sync, multiple concurrent transfers or WAN relay. Automatic reconnect attempts are bounded; Android needs the app to remain running, and recovery cannot override OS battery restrictions.
- Android storage permissions cannot reveal other apps' private data or some restricted `Android/data` paths. Some vendors may limit `READ_SMS`.
- Android normally needs the app running; in 0.1.8 you can explicitly enable the foreground service with a persistent notification, subject to operating system constraints. FerryPane cannot silently recover data from an app killed by the OS or perform new pairing on an unusable screen.
- Native contact import currently handles common fields; it does **not** guarantee complete fidelity for vCard photos, account settings or every address-book provider. Test imports on a spare device or with a separate backup first.
- Unfinished transfers can consume disk space under `.ferrypane-resume/`; background cleanup for abandoned old jobs is not yet implemented. Source hashing uses additional disk I/O before sending.
- Windows installer and Linux DEB support x64; mobile package supports Android architectures in the release build. Code signing for Windows installers is not yet implemented, so Windows SmartScreen may show an unrecognized publisher.
- No independent security audit. Avoid relying on the preview for sensitive data over hostile networks.

## Build and develop

Requires [Flutter stable](https://docs.flutter.dev/get-started/install) with the corresponding desktop/Android toolchain. Linux additionally needs GTK3 development libraries, `libsecret-1-dev` and a running, unlocked desktop Secret Service; Android requires SDK/JDK 17.

```bash
bash tool/prepare_platforms.sh
flutter analyze
flutter test
flutter build linux --release   # on Linux
flutter build windows --release # on Windows
```

**Security upgrade in 0.1.6:** the private X25519 identity seed moves from plaintext SharedPreferences into the OS secure store (Android Keystore, Windows protected storage, Linux Secret Service) on first launch. The existing key is verified before deleting the legacy setting; your paired devices should remain paired. If the keyring cannot be opened, the application refuses to start instead of reverting to plaintext. Do not downgrade to 0.1.5 after migration: that version cannot read the new secure identity. The original plaintext might still persist in old backups/snapshots. See [Security model](docs/SECURITY.md).

The platform projects are created by Flutter on the build machine; Android-specific permissions and native code are applied by `tool/patch_android.py`. Do not publish `flutter build apk --release` with the generated debug signing key; tagged CI releases require the permanent signing secrets documented in [SIGNING.md](docs/SIGNING.md).

The CI also creates `.deb` with `tool/build_deb.sh` and a per-user NSIS Windows installer with `tool/windows/FerryPane.nsi`. Pull-request builds validate all platforms; version tags publish the five release artifacts.

## Project and contributing

- [Security model and threat boundaries](docs/SECURITY.md)
- [Architecture and current implementation](docs/ARCHITECTURE.md)
- [Roadmap and deferred features](docs/ROADMAP.md)
- [Android backups and restoration](docs/PHONE_BACKUP.md)
- [Android signing and update compatibility](docs/SIGNING.md)
- [Changelog](CHANGELOG.md)
- [Issues](https://github.com/mirivlad/FerryPane/issues)

FerryPane is licensed under the **GNU General Public License v3.0**, see [LICENSE](LICENSE). A possible future WAN relay/hub is a separate undecided service, with no assumed license or business model.

Bug reports with OS/build number, both app versions, network conditions (including VPN) and reproduction steps are welcome.
