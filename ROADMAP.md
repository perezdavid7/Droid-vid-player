# Development roadmap

## Milestone A — first installable Android build
- [ ] GitHub Actions resolves Flutter dependencies and builds an APK
- [ ] Install on a real Android device
- [ ] Open MP4, MPEG/MPG, MKV, MOV, AVI test samples
- [ ] Play/pause, seek, speed adjustment and previous/next playlist controls
- [ ] Confirm app identity/signing across upgrades

## Milestone B — playback & picture controls
- [ ] Full Android document-tree (SAF) folders and USB access
- [ ] Portrait/landscape/rotation; zoom, fit, fill
- [ ] Brightness, contrast, saturation, gamma and temperature controls
- [ ] Clean video-only PNG capture without UI; validate source crop/rotation

## Milestone C — export and editing
- [ ] Save compressed copies in selectable resolutions and quality
- [ ] Trim with in/out markers
- [ ] Multiple independently exported clips, plus optionally joined output
- [ ] Progress, cancellation, disk space checks, error messages

## Milestone D — recovery
- [ ] Tolerant sequential demux / remux / decode fallback
- [ ] Record decoded output while playing strictly forward, no seeking
- [ ] Background/unattended processing on mobile with lifecycle controls
- [ ] Handle timestamp discontinuities, black frames, and damaged intervals
- [ ] Recover audio and produce seekable new file; keep originals untouched
- [ ] Recovery logs, partial-output retention and later clip editing

## Milestone E — Windows
- [ ] Windows runner, native dependencies, folder access, export path
- [ ] Desktop builds and packaged distribution

## Known risks
- Prototype dependencies/API compatibility not yet validated on CI.
- Android scoped storage / file picker may require native integration.
- Native FFmpeg binaries differ between Android and Windows and licensing may apply.
- Reverse shuttle currently uses repeated seeking and should be disabled for seek-sensitive damaged inputs.
- Severe corruption may not yield playable frames or recoverable audio.
