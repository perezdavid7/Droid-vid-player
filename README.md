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

## Experimental Recover & Record (Android)

The player now has a **Recover & Record** action on the current video (magic-wand icon).
This first implementation uses the minimal FFmpegKit native decoder to read source
data **forward only** and write a separate MP4 with MPEG-4 video and AAC audio.
Unlike screen recording, it does not include any video controls or window borders.

- Start from the selected video; keep the app in the foreground. The screen stays
  awake while FFmpeg processes. Reliable background/unattended service recovery
  is not yet available.
- The original file is never overwritten. Working output first goes to a unique
  private app-storage `.partial.mp4` path and is renamed to `.mp4` only if the
  process succeeds. Failed/cancelled partials may not be playable.
- The app attempts to copy successful results to Android Gallery under
  **Droid Vid Player**. If Gallery export fails, the recovered app-private
  version is retained and the user can retry.
- FFmpeg logs are saved privately and the most relevant end of the log is shown
  in an expandable diagnostic panel. Progress shows *processed output time* and
  frame count rather than an unreliable source duration percentage.
- This is an **experimental transcoding fallback**, not yet the originally
  envisioned literal real-time record-every-decoded-frame/audio fallback.
  Some broken inputs cannot be decoded or probed and may fail outright.
- Trim & Clip and robust processing after locking/backgrounding the phone are
  separate unfinished milestones.

### Legacy format testing

The file picker recognizes MOV, MPG/MPEG, MKV, MP4/M4V, AVI/DIVX, WMV/ASF,
VOB, TS/MTS/M2TS, FLV, 3GP and `.vid`. Recognition of an extension **does not**
guarantee the embedded video/audio codec can be decoded. The `.vid` extension
is not a single standard codec. Test actual files (picture, sound, seeking,
repeat, and Recover & Record separately). The player now shows decoder error
messages to help diagnose unsupported or damaged files.

FFmpegKit's minimal LGPL components have separate distribution obligations;
review dependency licences before distributing outside personal testing.

### New experimental repair options and precise seeking

- **Quick Repair — original quality** tries stream-copy remuxing into MP4. It does
  not re-encode video or audio, so introduces no additional compression loss.
  Incompatible codecs/containers and severely damaged timestamps may still fail
  or result in an output with incorrect timing; inspect the result carefully.
- **Deep Recovery — high quality** uses MPEG-4 Part 2 quality level 2 (previously
  level 5) and 192 kb/s AAC (previously 160 kb/s). This may use more space and
  still involves lossy re-encoding. Always compare important originals.
- At normal zoom, a horizontal video gesture now uses **shuttle playback**:
  the toolbars hide and the video itself plays forward or backward at a variable
  rate until the thumb is lifted. A compact direction/time indicator remains.
  The app attempts to restore the prior speed, audio volume, and play/pause state
  when the gesture ends. At higher zoom, one-finger panning still takes priority.
- Native backward playback is experimental, codec-sensitive, and may be slow or
  unsupported with damaged/legacy videos. The regular timeline slider remains
  available. This is not a guarantee of smooth reverse on every input.
- All these changes need a successful GitHub Actions build and real-device
  testing. No guarantee of perfect quality or frame-accurate seeking.

## Development notes

- Source files are kept in GitHub rather than a monolithic ZIP. GitHub Actions can validate/build without a developer's laptop.
- The app is intended to run offline; media stays local unless the user explicitly exports/shares.
- Damaged file recovery is inherently best effort. Preserve source files and keep all recovery outputs distinct.
- Bundled FFmpeg distributions containing GPL libraries may carry GPL redistribution obligations. Evaluate licenses before public distribution.
- Do not claim a feature works just because its button exists: compile, run on real devices, and validate output integrity.

## Development source archive

The earlier **V0.1 source preview ZIP** is a separate experimental prototype and has not been established as a tested release. The GitHub project is being made incrementally buildable, starting with a simpler playback baseline.
