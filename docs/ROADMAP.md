# FerryPane development roadmap

Status: proposed execution plan. The **first usable release** means that all LAN device pairings can transfer files; intermediate milestones are for incremental testing, not promises of release readiness.

## Milestone 0 — foundation

- Create open-source licensing decision for *client applications* and a separate statement that a hypothetical relay is out of scope.
- Set up the Flutter/Dart codebase, platform toolchains, unit-test projects, and GitHub Actions for Linux/Windows and Android APK builds.
- Define protocol v1 frames, version/capability negotiation, schema and cross-language test vectors.
- Define identity, mutual verification, pairing/revocation, exported-root permissions, and reliable error handling.
- Implement a headless protocol/transfer test harness before polishing UIs.

**Acceptance:** Both language implementations parse shared conformance fixtures; CI can build their initial skeletons.

## Milestone 1 — desktop ↔ desktop vertical slice

- Shared Flutter/Dart peer engine, local-filesystem adapter, LAN listener and connector.
- mDNS announcement/discovery + manual IP fallback.
- Pair two peers and connect with authenticated, encrypted sessions.
- Implement root listing, directory listing and stat.
- Implement one-file download/upload, then recursive directory transfers using a streaming batch.
- Show queue, progress, cancel, conflicts, and per-file failures.
- Flutter desktop two-pane UI; either pane can point to local or remote storage.

**Acceptance:** Win↔Win, Linux↔Linux, Win↔Linux work locally for files and nested trees; no cloud required.

## Milestone 2 — desktop ↔ Android

- Android Flutter peer core using the same protocol implementation as desktop.
- Android storage adapter supporting only user/OS-authorized files and directories.
- Permission-onboarding and service lifecycle for active transfers.
- First Android UI: available devices, pair/revoke, local files and exported roots, connection/transfer status.
- Browse remote Android folders from Avalonia and copy recursively in both directions.
- Test with device providing a Wi-Fi hotspot (no router, no Internet).

**Acceptance:** Windows↔Android and Linux↔Android copying whole folder trees works without per-file selection or manual server configuration.

## Milestone 3 — Android ↔ Android and first complete mobile file manager

- Android UI: browse local and remote files, breadcrumbs, sorting, search where supported, multiselect and select-all.
- Touch workflow to choose files **or entire folders** and then select destination ("Copy to…", local or remote).
- Android peer can initiate and receive transfers; no desktop is required.
- Tablet adaptive two-pane UI; phone single-pane navigation.
- System share integration may be added, but the primary interaction must be in the file manager.
- Validate screen-off behavior, user-visible transfer notifications, and current Android foreground service restrictions.

**Acceptance:** Two Android phones (or phone and tablet) can each initiate browse/copy/send/receive in LAN/hotspot mode; both directions work.

## Milestone 4 — quality bar for 0.1.0

- Repeatable benchmark: 2 GB file; 10k tiny files; 100k tiny files; mixed directories.
- Reliability matrix: unplug Wi-Fi, process restart, full disk, file deleted during transfer, denied permission, conflicting names, Unicode/path-edge cases.
- Cancellation, restart recovery, resume and integrity verification.
- Security tests for traversal, symlink escapes, authentication failures and permission boundaries.
- User-ready builds: Windows package, Linux distributable, Android APK via GitHub Releases.
- Russian/English localization for primary interactions, onboarding documentation and screenshots.
- Release only after the above supported LAN pairings are verified.

## Deferred, not forgotten

- Remote relay/hub over HTTPS/WSS 443 (possible independent commercial offering; no commitment on implementation or license).
- Multi-hop remote-to-remote copies when the controller is a third peer (may require explicit relay through the controller unless separately designed).
- Android↔iOS, macOS, headless NAS mode, synchronization, backup policies.
- Thumbnails, previews, advanced filters and file comparisons.

## Implementation priorities

1. Correct protocol and filesystem safety.
2. Prove desktop↔desktop with real bytes.
3. Prove desktop↔Android using exactly the same wire contract.
4. Deliver fully capable Android UI and Android↔Android.
5. Polish, performance test and ship.

An intermediate branch passing unit tests does **not** count as a completed deliverable or a working mobile release.
