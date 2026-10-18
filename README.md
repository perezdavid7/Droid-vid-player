# Droid Vid Player

A privacy-first, offline-capable video player for **Android phones** and **Windows PCs**, developed in Flutter.

**Project status: early development / untested prototype.** No production-ready APK has been released.

## What we're building

- Broad local video playback: MPG/MPEG, MKV, MOV, MP4, AVI, WMV, WebM, TS, VOB and more (actual support depends on codecs).
- File/folder playlists, automatic next-video playback, play/pause, previous/next, adjustable playback speed and forward/backward jumps.
- Portrait/landscape video rotation, fit/fill, zoom and picture controls (brightness, contrast, saturation, gamma, temperature).
- **Clean still-image capture** from decoded video frames — no app borders or controls.
- Export compressed copies with resolution/quality presets; originals never overwritten.
- **Trim & Clip**: mark in/out points, make multiple selections and export as separate clips or one joined video.
- **Recover & Record**: sequentially play seek-sensitive/damaged videos without user intervention, capture decodable video/audio into a new seekable file, then cut recovered sections into clips. No guarantee of recovering missing data.

## Release strategy

1. Android playable foundation (build and test a downloadable APK).
2. Folder/USB support, navigation, reliable screenshot capture and display adjustments.
3. Trim & Clip for normal files; export settings.
4. Sequential recovery and unattended record-what-plays fallback, recovery logs and gap handling.
5. Windows builds (same Flutter source), polish, performance and packaging.

See [ROADMAP.md](ROADMAP.md) for acceptance criteria and outstanding work.

## Android APK building

GitHub Actions workflow: **Build Android APK** in the Actions tab. It runs on source changes and can be triggered manually. After a **successful** run, download the `Droid-Vid-Player-Android-APK` artifact, unzip it, and install the APK on your Android device. These are development builds; GitHub artifact downloads are not the same as an app store release.

The job generates the Android host scaffold with `flutter create --platforms=android .` until checked-in native host files are stabilized. Build numbers increment automatically with `GITHUB_RUN_NUMBER`.

### Stable Android updates: one-time private signing setup

Current debug-signed development APKs made on different runners may **not** install over one another because their signing certificates differ. To resolve this, configure a permanent private JKS keystore once using these **GitHub Actions repository secrets**:

- `ANDROID_KEYSTORE_BASE64`: base64-encoded private JKS file
- `ANDROID_KEYSTORE_PASSWORD`: JKS password (also used as the key password)
- `ANDROID_KEY_ALIAS`: the alias for the key in the JKS file

Configure these in **Settings → Secrets and variables → Actions**, not in source control. When all three are present, CI uses `scripts/configure_android_signing.py` and creates a consistently signed **release** APK. When absent, CI explicitly falls back to a disposable debug APK with a warning.

**Never commit the signing keystore or password to a public repository.** Keep an offline backup: if the keystore is lost, future in-place updates may not be possible. The transition from old debug builds to the first permanently signed APK usually requires **one last uninstall and reinstall** (back up any app data first). All subsequent signed builds can install over each other if the application ID remains unchanged and version codes increase.

## Development notes

- Source files are kept in GitHub rather than a monolithic ZIP. GitHub Actions can validate/build without a developer's laptop.
- The app is intended to run offline; media stays local unless the user explicitly exports/shares.
- Damaged file recovery is inherently best effort. Preserve source files and keep all recovery outputs distinct.
- Bundled FFmpeg distributions containing GPL libraries may carry GPL redistribution obligations. Evaluate licenses before public distribution.
- Do not claim a feature works just because its button exists: compile, run on real devices, and validate output integrity.

## Development source archive

The earlier **V0.1 source preview ZIP** is a separate experimental prototype and has not been established as a tested release. The GitHub project is being made incrementally buildable, starting with a simpler playback baseline.
