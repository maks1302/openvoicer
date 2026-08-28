# OpenVoicer

**A native, local-first macOS studio for creating fan dubs one line at a time.**

OpenVoicer turns a movie and its subtitles into a focused dubbing workflow:

> Listen → Record → Audition → Accept → Next

Drop in a movie, choose an embedded or external subtitle track, record replacement dialogue, compare multiple takes, preview the result against the picture, and export a standalone MP4—all on your Mac.

OpenVoicer is built with Swift 6, SwiftUI, AVFoundation, and FFmpeg. There are no accounts, no cloud backend, no analytics SDKs, and no requirement to upload personal media.

> [!IMPORTANT]
> OpenVoicer is under active development. The source builds and the core workflow is usable, but release packaging, signing, notarization, and a bundled FFmpeg/source-separation runtime are not finished yet. Developers currently provide these tools locally.

## Why OpenVoicer?

Traditional video editors can create a dub, but they are not optimized for repeating the same small action hundreds of times. OpenVoicer is designed specifically around dialogue segments and fast keyboard-driven recording.

- Native macOS interface—not Electron and not a web wrapper
- Local processing and local project storage
- Subtitle-driven segment generation
- Multiple non-destructive takes per line
- Per-line decisions about which take and mix treatment to use
- Continuous preview of accepted lines
- Optional local dialogue separation to retain more music and effects
- Export of full movies, continuous clips, or review reels
- Project packages that can evolve through a versioned JSON schema

## Current feature set

### Projects and media

- Create, open, autosave, and reopen `.openvoicer` project packages
- Recent projects on the welcome screen
- Drag-and-drop and native file pickers
- Security-scoped bookmarks for persistent access to source media
- Full-movie or selected-clip projects
- Source metadata including duration, resolution, codec, audio tracks, and channel count
- Audio-track selection for multilingual and multichannel movies
- Compact MKV playback proxies for clip projects

### Subtitles and dubbing segments

- SRT and WebVTT parsing
- Embedded text-subtitle discovery and extraction through FFmpeg
- Multiline dialogue and common formatting-tag cleanup
- One subtitle event per dubbing segment
- Segment filtering and progress tracking
- Accurate segment playback with automatic stopping
- Pre-roll and post-roll context

### Recording

- Microphone permission handling and input-device selection
- WAV/PCM recording with multiple takes per line
- Configurable countdown displayed over the video
- Silent lip-sync video during recording by default
- Optional source audio during recording for headphone users
- Live input level and clipping feedback
- Original and recorded waveforms with a synchronized playhead
- Retry, delete, favorite, select, and accept workflows

### Preview and mix decisions

Each accepted line stores both the chosen take and its treatment:

- **Original** — leave the original line unchanged
- **Ducked Mix** — lower the original mix and add the selected take
- **Clean Dub** — use the prepared background stem and add the selected take
- **Take Only** — play only the selected recording for the line

The main player can switch between the original movie and a continuous preview of accepted decisions.

### Dialogue preparation

OpenVoicer inspects the selected audio track and recommends a preparation strategy:

1. Use a detected M&E (music and effects) track when one is available.
2. Recognize useful surround sources for future/assisted processing.
3. Otherwise use the optional Bandit v2 local separation model.
4. Fall back to original-audio ducking when separation is unavailable or unwanted.

Dialogue separation is inherently imperfect. Film mixes contain overlapping speech, music, ambience, reverb, crowds, and effects. OpenVoicer keeps the original source untouched and makes separation optional rather than presenting it as lossless dialogue removal.

### Export

- Standalone MP4 output
- Finished movie or selected project clip
- Current-line, selected-line, or custom-time continuous clips
- Review reels containing accepted or selected lines
- Original-video stream copy where practical
- Render progress and cancellation
- Short crossfades around accepted lines
- Original source for unfinished or explicitly original lines

## Requirements

- macOS 14 Sonoma or newer
- Xcode with Swift 6 support
- Apple Silicon recommended
- FFmpeg and ffprobe for MKV playback, embedded subtitles, media inspection, and export

Intel builds may work, but Apple Silicon is the current development and testing target. The optional Bandit implementation uses MLX and therefore targets Apple Silicon.

## Building from source

### 1. Clone the repository

Clone the repository using the URL from GitHub's **Code** menu, then enter the checkout:

```bash
cd openvoicer
```

The repository, source directory, and Xcode scheme use the lowercase `openvoicer` name; the macOS product is displayed as **OpenVoicer**.

### 2. Install development media tools

Homebrew is acceptable for development:

```bash
brew install ffmpeg
```

OpenVoicer searches for FFmpeg in the application bundle, `/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin`.

Optional local dialogue separation currently also requires:

```bash
brew install uv python
```

The first separation setup downloads a pinned `bandit-infer` revision, its Python/MLX dependencies, and the Bandit v2 checkpoint into OpenVoicer's Application Support directory. See [Third-party notices](THIRD_PARTY_NOTICES.md).

### 3. Open and run

```bash
open openvoicer.xcodeproj
```

Select the **openvoicer** scheme and run the macOS app. Xcode signing is the easiest way to test microphone access and sandboxed file permissions locally.

For a command-line compile check:

```bash
xcodebuild \
  -project openvoicer.xcodeproj \
  -scheme openvoicer \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### 4. Run tests

```bash
swift test --disable-sandbox
```

The test suite covers subtitle parsing, project migration and serialization, audio-preparation models, and FFmpeg export command generation.

## Using OpenVoicer

### Create a project

1. Choose **New Project** or drop a movie on the welcome screen.
2. Select the dialogue audio track. Audition tracks if the container contains multiple languages.
3. Choose **Full Movie** or **Selected Clip**.
4. For a clip, enter precise In and Out timecodes or use the native one-second steppers.
5. Select an embedded subtitle track if one is available.
6. Review the recommended dialogue-preparation method and create the project.

MP4 and MOV sources normally stay entirely outside the project. MKV files require an AVFoundation-compatible playback copy. Clip projects cache only the selected range; full-movie MKV projects currently cache a complete stream-copy remux.

### Record a line

1. Select a subtitle line in the left sidebar.
2. Use **Original** or context playback to hear the source performance.
3. Press **R** or use the recording inspector.
4. Follow the countdown, then perform while the video plays.
5. Audition the new take alone, with ducking, or against a prepared clean background.
6. Choose the take and result treatment, then accept and advance.

By default the video is silent while recording to prevent speaker leakage. Enable **Play source audio while recording** in Microphone settings only when using headphones.

### Export

Open the Export inspector and choose:

- **Finished Movie** for the entire project scope
- **Continuous Clip** for one uninterrupted time range
- **Review Reel** to concatenate selected or accepted dialogue regions

The exported MP4 is standalone. It does not link back to the `.openvoicer` project or original movie after rendering.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play or pause the main player |
| `P` | Play the original selected segment |
| `R` | Start or stop recording |
| `T` | Record another take |
| `Return` | Accept the previewed result and move next |
| `←` | Previous segment |
| `→` | Next segment |
| `⌘N` | New project |
| `⌘O` | Open project |
| `⌘S` | Save project metadata |

## Project files and storage

A project is a Finder package with a readable, versioned layout:

```text
My Dub.openvoicer/
├── project.json
├── recordings/
├── prepared-audio/
├── waveform-cache/
├── separation-cache/
├── thumbnails/
└── temp/
```

The source movie is referenced through a security-scoped bookmark and is not copied by default. Prepared WAV stems can still be large because editing audio is intentionally kept lossless. See [Project format](docs/PROJECT_FORMAT.md) for lifecycle and portability details.

## Architecture

OpenVoicer uses focused controllers and services instead of one global view model:

- SwiftUI views for the workspace and inspectors
- Domain models independent of UI
- `PlaybackController` for AVPlayer and source/proxy timeline translation
- Recording and audio-device services for microphone work
- Subtitle parsers as Swift Package targets
- Actor-based project persistence and FFmpeg execution
- Replaceable source-separation and export boundaries

See [Architecture](docs/ARCHITECTURE.md) for module responsibilities and data flow.

## Privacy

The core application does not upload movies, subtitles, recordings, or project metadata.

- No account
- No analytics or advertising SDKs
- No telemetry by default
- No cloud backend
- Security-scoped access only to files the user selects

Network access is currently used only when the user explicitly installs the optional development separation runtime and model. A distributable release should bundle reviewed dependencies or clearly ask before any download.

## Known limitations

- FFmpeg is not bundled yet; development builds expect a local installation.
- The optional Bandit runtime is development-oriented and not yet suitable for a polished signed release.
- Dialogue separation can leave voice residue or remove parts of overlapping music and effects.
- A true M&E track remains preferable to AI separation.
- Full-movie MKV projects require a large playback cache; MKV clip projects use only a compact range proxy.
- Image-based subtitle formats such as PGS are detected but not converted into editable dialogue.
- Automatic transcription, diarization, and source separation into distinct music/SFX/ambience stems are roadmap features.

## Roadmap

- Editing tools for creating, splitting, merging, and retiming segments
- Improved undo/redo coverage and keyboard customization
- Bundled, signed FFmpeg distribution
- Native Apple Silicon dialogue separation without a Python runtime
- Center-channel and multichannel-assisted dialogue extraction
- Local Whisper transcription for movies without subtitles
- Speaker diarization and speaker workflows
- Better project cleanup and cache-management controls
- Signed and notarized GitHub releases

## Contributing

Contributions, focused bug reports, and reproducible media edge cases are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

Media bugs are often container-, codec-, or track-specific. Never upload copyrighted source media to an issue. Prefer FFprobe metadata, relevant logs, and a small freely licensed reproduction file.

## License

OpenVoicer is licensed under the [GNU General Public License v3.0](LICENSE) (`GPL-3.0-only`). Third-party components and model weights retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgements

OpenVoicer builds on Apple's AVFoundation and SwiftUI, FFmpeg, MLX, and the open source source-separation research ecosystem. The project exists because local creative tools should be understandable, modifiable, and usable without surrendering personal media to a cloud service.
