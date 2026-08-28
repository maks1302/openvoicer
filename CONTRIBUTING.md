# Contributing to OpenVoicer

Thanks for helping build a private, native dubbing tool for macOS.

OpenVoicer is still early, so focused improvements are more useful than broad rewrites. A good contribution keeps the app compiling, preserves project compatibility, and improves one understandable part of the dubbing workflow.

## Before contributing

- Read the [README](README.md) and [architecture guide](docs/ARCHITECTURE.md).
- Search existing issues before opening a duplicate.
- For a large feature or architectural change, open a discussion or issue first.
- Do not submit copyrighted movies, subtitle files, model checkpoints, or sample dialogue without redistribution rights.

## Development setup

Requirements:

- macOS 14+
- Xcode with Swift 6 support
- FFmpeg/ffprobe available from the application bundle, `/opt/homebrew/bin`, or `/usr/local/bin`

```bash
brew install ffmpeg
open openvoicer.xcodeproj
```

The optional development source-separation runtime additionally uses `uv`, Python, MLX, and separately downloaded weights. You do not need it for subtitle parsing, project-model, UI, or most export contributions.

## Making a change

1. Create a focused branch.
2. Inspect the existing implementation before introducing a new abstraction.
3. Preserve unrelated local changes.
4. Add or update tests for logic-heavy behavior.
5. Build the macOS app after meaningful changes.
6. Update documentation when behavior, storage, dependencies, or privacy changes.

Useful verification commands:

```bash
swift test --disable-sandbox
```

```bash
xcodebuild \
  -project openvoicer.xcodeproj \
  -scheme openvoicer \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Code style

- Use Swift 6 concurrency intentionally; avoid adding completion-handler APIs when async/await is practical.
- Keep UI state on the main actor and long media work off it.
- Prefer typed models and enums to string dictionaries.
- Prefer focused observable controllers to a global state container.
- Keep FFmpeg arguments inside media/export services, never in views.
- Avoid force unwraps.
- Use `Logger` rather than `print()`.
- Comment synchronization, timestamp, and process-lifecycle decisions—not obvious Swift syntax.
- Follow existing Swift naming and formatting rather than adding a formatting dependency without discussion.

## Testing priorities

Tests are especially valuable for:

- SRT/WebVTT parsing and malformed input recovery
- timestamp and source/proxy timeline conversion
- project serialization and older-schema migration
- segment transformations
- export range and filter-graph generation
- FFmpeg argument generation
- audio mix transition envelopes

For media regressions, include the smallest freely distributable reproduction possible. If that is not possible, include:

- `ffprobe -show_format -show_streams` output with private paths removed;
- the relevant OpenVoicer/FFmpeg log excerpt;
- macOS, architecture, Xcode, and FFmpeg versions;
- exact project scope and selected audio/subtitle track;
- expected and observed behavior.

## Project-format compatibility

Never silently reinterpret persisted timestamps or recording paths. If a model change affects saved data:

- provide decoding defaults;
- add a legacy fixture or migration test;
- increment `schemaVersion` when required;
- document storage impact in [PROJECT_FORMAT.md](docs/PROJECT_FORMAT.md).

Generated caches can be versioned separately, but user recordings and accepted choices must remain durable.

## Dependencies

Before adding a dependency, explain:

1. The problem it solves.
2. Why Foundation, AVFoundation, Accelerate, Core ML, or another Apple framework is insufficient.
3. Maintenance health and supported architectures.
4. License compatibility with GPL-3.0-only distribution.
5. Binary size, privacy, sandbox, and notarization implications.

Do not add analytics, account, cloud-storage, or network-service SDKs.

## Pull requests

A useful pull request includes:

- a concise description of user-visible behavior;
- the reason for the change;
- testing performed;
- screenshots or a short screen recording for UI changes;
- storage/migration notes when applicable;
- known limitations or follow-up work.

Keep refactors and behavior changes separate when practical. Review is much easier when each commit leaves the application in a working state.

## Reporting security or privacy issues

Do not publish sensitive paths, bookmarks, recordings, or media in a public issue. Until a dedicated security address exists, open a minimal issue asking maintainers for a private contact channel without including exploit details or private data.

## Community expectations

Be respectful, specific, and patient. Critique code and product decisions rather than people. Harassment, discrimination, and publication of another contributor's private information are not acceptable.
