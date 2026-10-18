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

The job generates the Android host scaffold with `flutter create --platforms=android .` until checked-in native host files are stabilized. Future releases will use a stable applicationId and managed signing key to preserve upgrade compatibility.

## Development notes

- Source files are kept in GitHub rather than a monolithic ZIP. GitHub Actions can validate/build without a developer's laptop.
- The app is intended to run offline; media stays local unless the user explicitly exports/shares.
- Damaged file recovery is inherently best effort. Preserve source files and keep all recovery outputs distinct.
- Bundled FFmpeg distributions containing GPL libraries may carry GPL redistribution obligations. Evaluate licenses before public distribution.
- Do not claim a feature works just because its button exists: compile, run on real devices, and validate output integrity.

## Development source archive

The earlier **V0.1 source preview ZIP** is a separate experimental prototype and has not been established as a tested release. The GitHub project is being made incrementally buildable, starting with a simpler playback baseline.
