# FerryPane Android APK signing and updates

## Why older previews failed to update

The original `0.1.0` / `0.1.1` GitHub Actions builds used Flutter's default **runner-specific debug signing key** for release APKs. Android treats two packages signed with different keys as different app identities even when their package name is the same, so it correctly rejects in-place installation.

**Starting at `0.1.2`: the permanent signing identity is fixed and pinned.** New Android releases MUST use the same signing certificate. CI will refuse to publish an APK without this certificate.

Public certificate SHA-256 fingerprint:

```
20:BD:47:49:48:5E:7C:1A:5C:0E:F0:72:07:7E:27:7F:EA:BD:23:89:E3:11:61:B6:75:B4:FD:DB:74:07:43:9D
```

### Where the private key lives

A permanent PKCS12 signing keystore must be kept in a **private owner-controlled location**, for example:

```
$HOME/.local/share/ferrypane/signing/ferrypane-release.p12
$HOME/.local/share/ferrypane/signing/store-password
```

Directory mode `0700`; both files `0600`. **Neither file belongs in the public GitHub repository.** Make a secure offline backup of *both* files. Losing this private key means future Android versions cannot update packages installed with that key. Keep an offline backup of the keystore and password for all future updates.

### One-time GitHub Actions setup

Only someone with repository admin access can set the necessary GitHub Actions secrets. GitHub's repository page: **Settings → Secrets and variables → Actions → New repository secret**.

Create exactly these two:

- `FERRYPANE_ANDROID_KEYSTORE_B64`: base64 of the complete PKCS12 file, **one line**.
- `FERRYPANE_ANDROID_STORE_PASSWORD`: the complete content of the password file, without an extra newline.

Obtain both values on the machine hosting the offline private key, and enter them into the repository's **Actions secrets** interface (never paste them into an issue or chat):

```bash
base64 -w0 $HOME/.local/share/ferrypane/signing/ferrypane-release.p12
cat $HOME/.local/share/ferrypane/signing/store-password
```

The `tool/prepare_signing.sh` build step decodes the secret in the ephemeral runner and verifies the certificate fingerprint **before** building. After signing, CI verifies the APK's signature with `apksigner` and the same pinned fingerprint.

- Pull requests and untagged main builds compile a **debug APK for verification only**. They do not publish an installable release APK.
- Version-tagged release builds require the signing secrets and fail closed when they are absent.
- GitHub Releases only publishes the signed APK if all the platform jobs succeeded.

### First migration from old previews

The signing key of previously released APKs is unrelated to the new permanent key. Therefore the **first transition from 0.1.0 / 0.1.1 will require uninstalling the old Android APK** and installing the first permanent-signed APK. This discards local app preferences and pairing keys, so re-pair devices afterwards.

From one permanent-signed version to the next, installing the APK **over the previous version** should preserve app data and pairing, provided the application ID stays `top.mirv.ferrypane`, the signing key remains the same, and Android `versionCode` increases.

Use `apksigner verify --print-certs` to check which certificate signed a particular APK. If an installed APK has an unfamiliar certificate, DO NOT overwrite the pinned signing identity to match it without an explicit, documented migration plan.
