# Droid Vid Editor — Build 1

This is the separate, experimental **Droid Vid Editor** application developed on the `droid-vid-editor` branch of Droid Vid Player. The existing `main` branch and original player APK are unaffected.

## First-build capabilities

- Import local videos as separate private app-owned copies; user originals are never changed.
- Video preview, mark in/out, split clips, change order, and remove timeline entries.
- 90-degree rotation, static zoom and pan, and project output ratios of 16:9, 9:16, and 1:1.
- Automatic non-destructive JSON draft in private app storage, restored at startup.
- Experimental 720p/30fps MPEG-4/AAC MP4 export, joining all timeline clips and trying to copy verified output to Android Gallery.
- Per-clip audio presence detection and generated silence for silent input.
- Export cancellation and errors shown in UI.

## Limitations

This is a first experimental build, not a production-ready editor. It has not yet passed a real-device test. Static pan/zoom preview is approximate and the final crop is performed during export. Importing large files duplicates storage. Input compatibility depends on codecs. Export may be slow, and unusual source timestamps/audio can fail. Gallery export is best effort; the verified file remains in private editor storage.

Animated keyframes, face adjustments, makeup, body reshaping, tracked blemish/tattoo removal, and moving-object inpainting are **planned, not implemented**. No video leaves the phone.

## Technical approach

Dart/Flutter provides the editor UI and autosaved edit decisions. VideoPlayer handles preview. The existing FFmpegKit minimal package produces normalized encoded clip files, then joins them. We will test on Galaxy S24 Ultra, stabilize the timeline/export pipeline, then prototype on-device face/body tracking and user-selected masks before making claims about AI removal quality.

## Build

GitHub Actions workflow: **Build Droid Vid Editor APK** (branch `droid-vid-editor`). Download artifact `Droid-Vid-Editor-Android-APK`. This APK uses a distinct package name generated from `com.perezdavid.droid_vid_editor`, so it is intended to install alongside Droid Vid Player. Stable upgrades require consistent signing secrets as documented in the original player README.
