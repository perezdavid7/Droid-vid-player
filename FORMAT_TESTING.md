# Legacy Video Compatibility Checklist

**Do not test the only copy of a damaged recording.** Keep an untouched backup.

The filename extension is a container hint, **not** proof of codec support.

## Format test log

For one video in each category, record:
1. Does it open without an error?
2. Does picture decode correctly?
3. Is audio present and in sync?
4. Can the video reach the real end without freezing?
5. Can you seek, replay and repeat without glitching? (Skip seeking
   if this file is already known to have damaged timestamps.)
6. If normal seeking is broken, try Recover & Record on a COPY and
   check the recovered Gallery video, its audio and seeking.

| Container | Example extension | Tested on actual Android device? | Notes |
|---|---|---|---|
| QuickTime | MOV | No | |
| MPEG-1/2 | MPG, MPEG, M2V | No | |
| Matroska | MKV | No | |
| MPEG-4 | MP4, M4V | No | |
| AVI / DivX | AVI, DIVX | No | |
| Windows Media | WMV, ASF | No | |
| DVD / transport stream | VOB, TS, MTS, M2TS | No | |
| FLV / mobile | FLV, 3GP | No | |
| Legacy VID | VID | No | VID is not a single standardized codec |

## Recovery testing (experimental)

- [ ] Source plays normally, output plays and remains seekable
- [ ] Source won't seek but plays forward, recovered output plays normally
- [ ] Source has no audio track
- [ ] Source has damaged/absent timestamps
- [ ] Source has corrupt packets in the middle
- [ ] Cancel returns to the screen without corrupting source
- [ ] Video can be saved to Android Gallery
- [ ] APK updates over the currently signed installation

## Notes for maintainers

The FFmpegKit minimal encoder currently writes MPEG-4 Part 2 video and
AAC audio in an MP4 container. A successful FFmpeg exit is not proof
every frame was recovered. More robust audio/video recovery, gallery
playback validation, real-time frame-recording fallback, foreground
services, and Trim & Clip are outstanding tasks.
