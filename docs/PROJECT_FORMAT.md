# OpenVoicer project format

OpenVoicer projects use the `.openvoicer` extension and are macOS packages backed by ordinary files and folders. This keeps projects inspectable, backup-friendly, and recoverable without introducing a database.

## Layout

```text
Example.openvoicer/
├── project.json
├── recordings/
│   └── <segment UUID>/
│       └── <take UUID>.wav
├── prepared-audio/
│   └── <audio track ID>/
│       ├── dialogue.wav
│       └── background.wav
├── waveform-cache/
├── separation-cache/
├── thumbnails/
└── temp/
    ├── source-playback.mov
    ├── embedded-subtitles/
    └── diagnostic logs
```

Not every directory contains files in every project.

## Durable data versus generated data

### Durable

- `project.json`
- Everything under `recordings/`
- User-authored notes and decisions represented in project metadata

These files should be backed up and must not be deleted by cache-cleaning features.

### Reproducible or cached

- `prepared-audio/`
- `waveform-cache/`
- `separation-cache/`
- `thumbnails/`
- Most files under `temp/`

These can generally be recreated from the source movie and recordings, although regeneration may require FFmpeg, the separation model, and significant processing time.

## `project.json`

The JSON document contains:

- `schemaVersion`
- project identity, name, and dates
- source-video reference and metadata
- project media scope
- subtitle-source reference
- speakers and dubbing segments
- recording-take metadata
- selected and accepted versions
- project settings
- prepared-audio asset references

Times are represented as `TimeInterval` seconds on the original source-movie timeline. A clip from `00:40:00` to `00:42:00` therefore contains segment timestamps near 2400 seconds rather than resetting them to zero. The UI can display clip-relative time without changing persisted synchronization values.

Do not hand-edit `project.json` while OpenVoicer is open. Autosave can overwrite external edits, and invalid UUID/file relationships can make recordings appear unavailable.

## Schema evolution

`schemaVersion` is monotonically increasing. The current decoder accepts missing fields from older versions and assigns safe defaults. A newer project whose schema is not understood must be rejected rather than partially overwritten.

When adding a persisted field:

1. Provide a default for older projects.
2. Preserve unknown generated files.
3. Add serialization and migration tests.
4. Increment the schema version when semantics or required structure changes.
5. Avoid migrating large media synchronously on the main actor.

Playback proxies have a separate `playbackPreparationVersion` because their compatibility can change without changing the user-authored project schema.

## Original movie reference

The original movie is not embedded in the project by default. `SourceVideoReference` stores:

- a security-scoped bookmark;
- a display name;
- a last-known path used for diagnostics;
- probed metadata;
- an optional playback-cache reference.

The bookmark allows the sandboxed app to regain access after relaunch. If the movie is moved and the bookmark cannot resolve it, OpenVoicer reports the source as missing. Export and media regeneration require the original.

An exported MP4 is different: it is a standalone rendered movie and does not depend on the `.openvoicer` package or source after export completes.

## MKV playback storage

AVFoundation does not reliably support Matroska containers, so OpenVoicer creates a MOV playback cache:

- Clip project: only the selected range is cached.
- Full-movie project: the complete movie is remuxed for playback.
- MP4/MOV project: no playback copy is normally necessary.

The MOV is a cache, not the export master. Export continues to read the original source.

## Prepared audio storage

Prepared dialogue and background stems are continuous WAV files. Lossless editing audio uses substantial space—approximately 11 MB per stereo minute for each 48 kHz 16-bit stem, and more for float PCM or multichannel assets.

The prepared asset records `timelineStart` and `timelineDuration` so stem-local samples remain aligned with source timestamps. Changing the selected source audio track or separation model may create or replace a track-specific prepared asset.

## Portability and backup

Copying a `.openvoicer` package preserves recordings and decisions, but the receiving Mac must also have access to the original movie. A future “consolidate project” feature may optionally copy source media for portable archives; that is not implemented yet.

Recommended backup policy:

- Always back up `project.json` and `recordings/`.
- Back up `prepared-audio/` if regeneration is expensive.
- Exclude waveform and temporary caches if storage is constrained.
- Keep the original movie independently backed up.

## Recovery guidance

If only a generated playback proxy is corrupt, close OpenVoicer and remove `temp/source-playback.mov`; the app regenerates it when the project is reopened. Do not remove recordings or `project.json` during troubleshooting.

Before manually changing a package, duplicate it in Finder so recovery remains possible.
