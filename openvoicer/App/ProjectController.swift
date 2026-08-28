import AppKit
import AVFoundation
import Observation
import OSLog
import UniformTypeIdentifiers

@MainActor
@Observable
final class ProjectController {
    private static let playbackPreparationVersion = 2
    private static let liveMixTransitionDuration: TimeInterval = 0.12
    enum MainPlaybackMode: String, CaseIterable, Identifiable {
        case original
        case dubbed

        var id: Self { self }
        var title: String { self == .original ? "Original" : "Dubbed" }
    }

    private(set) var project: DubProject?
    private(set) var projectURL: URL?
    private(set) var isLoadingVideo = false
    private(set) var isLoadingSubtitles = false
    private(set) var embeddedSubtitleTracks: [EmbeddedSubtitleTrack] = []
    private(set) var selectedSegmentID: UUID?
    private(set) var isPreparingMovieAudio = false
    private(set) var audioPreparationProgress = 0.0
    private(set) var audioPreparationMessage = "Movie audio is not prepared"
    private(set) var isInspectingNewMovie = false
    private(set) var isCreatingProjectFromDraft = false
    var newProjectDraft: NewProjectDraft?
    private(set) var auditioningNewProjectTrackID: String?
    private(set) var isPreparingNewProjectPreview = false
    @ObservationIgnored let newProjectPreviewPlayer = AVPlayer()
    var segmentPreviewMode: SegmentMixTreatment = .duckedMix
    var mainPlaybackMode: MainPlaybackMode = .original {
        didSet {
            guard mainPlaybackMode != oldValue else { return }
            stopContinuousDubOverlay()
            continuousDubPreviewActive = playback.isPlaying && mainPlaybackMode == .dubbed
            if continuousDubPreviewActive {
                synchronizeContinuousDubPreview(at: playback.currentTime)
            }
        }
    }
    var errorMessage: String?

    let playback = PlaybackController()
    let recording = RecordingController()
    let waveforms = WaveformController()
    let sourceSeparation = SourceSeparationController()
    let recentProjects = RecentProjectsStore()
    let exportController = ExportController()

    private let projectStore = ProjectStore()
    private let metadataLoader = VideoMetadataLoader()
    private let ffmpegService = FFmpegService()
    private let subtitleParser = SubtitleParserService()
    private let logger = Logger(subsystem: "com.openvoicer.app", category: "project")
    private var accessedProjectURL: URL?
    private var accessedVideoURL: URL?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var automaticStopTask: Task<Void, Never>?
    @ObservationIgnored private var finishingRecordingTask: Task<Void, Never>?
    @ObservationIgnored private var recordingVideoPlaybackActive = false
    @ObservationIgnored private var pendingTake: PendingRecordingTake?
    @ObservationIgnored private var audioPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var continuousDubPreviewActive = false
    @ObservationIgnored private var activeDubbedSegmentID: UUID?
    @ObservationIgnored private var playbackVolumeRampTask: Task<Void, Never>?
    @ObservationIgnored private var pendingNewVideoURL: URL?
    @ObservationIgnored private var newProjectAuditionPlayer: AVPlayer?
    @ObservationIgnored private var newProjectAuditionURL: URL?
    @ObservationIgnored private var newProjectPreviewURL: URL?
    @ObservationIgnored private var newProjectPreviewStopTask: Task<Void, Never>?
    @ObservationIgnored private var newProjectPreviewTask: Task<Void, Never>?

    init() {
        playback.onPlaybackStopped = { [weak self] in
            self?.finishSegmentPreview()
        }
        playback.onTimeUpdated = { [weak self] time in
            self?.synchronizeContinuousDubPreview(at: time)
        }
    }

    func showNewProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Movie for Your Dub"
        panel.prompt = "Choose Movie"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginNewProjectSetup(with: url)
    }

    func dismissNewProjectAssistant() {
        newProjectPreviewStopTask?.cancel()
        newProjectPreviewTask?.cancel()
        newProjectPreviewStopTask = nil
        newProjectPreviewTask = nil
        newProjectPreviewPlayer.pause()
        newProjectPreviewPlayer.replaceCurrentItem(with: nil)
        if let newProjectPreviewURL {
            try? FileManager.default.removeItem(at: newProjectPreviewURL)
        }
        newProjectPreviewURL = nil
        isPreparingNewProjectPreview = false
        newProjectAuditionPlayer?.pause()
        newProjectAuditionPlayer = nil
        auditioningNewProjectTrackID = nil
        if let newProjectAuditionURL {
            try? FileManager.default.removeItem(at: newProjectAuditionURL)
        }
        newProjectAuditionURL = nil
        if let pendingNewVideoURL {
            if accessedVideoURL == nil,
               project?.sourceVideo?.lastKnownPath == pendingNewVideoURL.path {
                // Transfer the wizard's security-scoped access to the open
                // project when a nested startAccessing call was unnecessary.
                accessedVideoURL = pendingNewVideoURL
            } else {
                pendingNewVideoURL.stopAccessingSecurityScopedResource()
            }
        }
        pendingNewVideoURL = nil
        newProjectDraft = nil
        isCreatingProjectFromDraft = false
    }

    func createProjectFromDraft() {
        guard let draft = newProjectDraft, draft.canCreate else { return }
        newProjectPreviewTask?.cancel()
        newProjectPreviewStopTask?.cancel()
        newProjectPreviewPlayer.pause()
        newProjectAuditionPlayer?.pause()
        let panel = NSSavePanel()
        panel.title = draft.scopeMode == .clip ? "Save Clip Project" : "Save OpenVoicer Project"
        panel.prompt = "Create"
        panel.allowedContentTypes = [.openVoicerProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = draft.sourceURL.deletingPathExtension().lastPathComponent + ".openvoicer"
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let packageURL = selectedURL.pathExtension.lowercased() == "openvoicer"
            ? selectedURL
            : selectedURL.appendingPathExtension("openvoicer")
        let name = packageURL.deletingPathExtension().lastPathComponent
        isCreatingProjectFromDraft = true

        Task { [weak self] in
            guard let self else { return }
            guard await createProject(named: name, at: packageURL),
                  await importVideo(at: draft.sourceURL) else {
                isCreatingProjectFromDraft = false
                return
            }
            guard var project else { return }
            project.mediaScope = draft.mediaScope
            project.settings.selectedAudioTrackID = draft.selectedAudioTrackID
            project.settings.audioPreparationPreference = draft.audioPreparationPreference
            project.settings.dialogueCleaningPreset = draft.dialogueCleaningPreset
            self.project = project
            if let index = project.sourceVideo?.metadata.audioTracks.firstIndex(where: {
                $0.id == draft.selectedAudioTrackID
            }) {
                try? await playback.selectAudioTrack(at: index)
            }
            let range = project.mediaScope.resolvedRange(sourceDuration: playback.duration)
            playback.seek(to: range.lowerBound)
            save()
            if let streamIndex = draft.selectedEmbeddedSubtitleStreamIndex,
               let track = draft.embeddedSubtitleTracks.first(where: { $0.streamIndex == streamIndex }) {
                await extractAndImportEmbeddedTrack(track)
            }
            isCreatingProjectFromDraft = false
            dismissNewProjectAssistant()
            if draft.prepareBackgroundAfterCreation, draft.effectiveStrategy != nil {
                _ = prepareMovieAudio()
            }
        }
    }

    func auditionNewProjectAudioTrack(_ trackID: String) {
        guard let draft = newProjectDraft,
              let trackIndex = draft.metadata.audioTracks.firstIndex(where: { $0.id == trackID }) else { return }
        if auditioningNewProjectTrackID == trackID {
            newProjectAuditionPlayer?.pause()
            newProjectAuditionPlayer = nil
            auditioningNewProjectTrackID = nil
            return
        }
        newProjectAuditionPlayer?.pause()
        auditioningNewProjectTrackID = trackID
        let start = draft.scopeMode == .clip
            ? draft.normalizedClipStart
            : min(max(draft.metadata.duration * 0.1, 30), max(draft.metadata.duration - 8, 0))
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "OpenVoicer-Audition-\(UUID().uuidString).wav")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ffmpegService.extractAudioSegment(
                    from: draft.sourceURL,
                    startTime: start,
                    duration: min(8, draft.metadata.duration - start),
                    audioTrackIndex: trackIndex,
                    destination: destination
                )
                guard auditioningNewProjectTrackID == trackID else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                if let newProjectAuditionURL {
                    try? FileManager.default.removeItem(at: newProjectAuditionURL)
                }
                newProjectAuditionURL = destination
                let player = AVPlayer(url: destination)
                newProjectAuditionPlayer = player
                player.play()
            } catch {
                auditioningNewProjectTrackID = nil
                present(error, fallback: "This audio track could not be auditioned.")
            }
        }
    }

    func previewNewProjectSelection(startingAt requestedStart: TimeInterval? = nil) {
        guard let draft = newProjectDraft,
              let trackIndex = draft.metadata.audioTracks.firstIndex(where: {
                  $0.id == draft.selectedAudioTrackID
              }) else { return }
        newProjectAuditionPlayer?.pause()
        auditioningNewProjectTrackID = nil
        newProjectPreviewStopTask?.cancel()
        newProjectPreviewTask?.cancel()
        let defaultStart = draft.scopeMode == .clip
            ? draft.normalizedClipStart
            : min(max(draft.metadata.duration * 0.1, 30), max(draft.metadata.duration - 12, 0))
        let start = min(max(requestedStart ?? defaultStart, 0), max(draft.metadata.duration - 0.1, 0))
        let duration = min(12, max(draft.metadata.duration - start, 0.1))
        isPreparingNewProjectPreview = true

        newProjectPreviewTask = Task { [weak self] in
            guard let self else { return }
            var transientPreviewURL: URL?
            do {
                let targetTime: TimeInterval
                if draft.sourceURL.pathExtension.lowercased() == "mkv" {
                    let destination = FileManager.default.temporaryDirectory
                        .appending(path: "OpenVoicer-SetupPreview-\(UUID().uuidString).mp4")
                    transientPreviewURL = destination
                    try await ffmpegService.createSetupPreview(
                        source: draft.sourceURL,
                        startTime: start,
                        duration: duration,
                        audioTrackIndex: trackIndex,
                        destination: destination
                    )
                    try Task.checkCancellation()
                    if let newProjectPreviewURL {
                        try? FileManager.default.removeItem(at: newProjectPreviewURL)
                    }
                    newProjectPreviewURL = destination
                    transientPreviewURL = nil
                    newProjectPreviewPlayer.replaceCurrentItem(with: AVPlayerItem(url: destination))
                    targetTime = 0
                } else {
                    if newProjectPreviewPlayer.currentItem?.asset as? AVURLAsset == nil {
                        newProjectPreviewPlayer.replaceCurrentItem(with: AVPlayerItem(url: draft.sourceURL))
                    }
                    if let item = newProjectPreviewPlayer.currentItem,
                       let group = try await item.asset.loadMediaSelectionGroup(for: .audible),
                       group.options.indices.contains(trackIndex) {
                        item.select(group.options[trackIndex], in: group)
                    }
                    targetTime = start
                }
                isPreparingNewProjectPreview = false
                await newProjectPreviewPlayer.seek(
                    to: CMTime(seconds: targetTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                newProjectPreviewPlayer.play()
                newProjectPreviewTask = nil
                newProjectPreviewStopTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard !Task.isCancelled else { return }
                    self?.newProjectPreviewPlayer.pause()
                }
            } catch is CancellationError {
                if let transientPreviewURL { try? FileManager.default.removeItem(at: transientPreviewURL) }
                isPreparingNewProjectPreview = false
                newProjectPreviewTask = nil
            } catch {
                if let transientPreviewURL { try? FileManager.default.removeItem(at: transientPreviewURL) }
                isPreparingNewProjectPreview = false
                newProjectPreviewTask = nil
                present(error, fallback: "The selected movie range could not be previewed.")
            }
        }
    }

    func showOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open OpenVoicer Project"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.openVoicerProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(at: url) }
    }

    func openProjectURL(_ url: URL) {
        guard url.pathExtension.lowercased() == "openvoicer" else { return }
        Task { await openProject(at: url) }
    }

    func openRecentProject(_ recentProject: RecentProject) {
        let url = recentProjects.resolveURL(for: recentProject)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "This project has moved or is no longer available."
            return
        }
        Task { await openProject(at: url) }
    }

    func showVideoImportPanel() {
        guard project != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Source Video"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importVideo(at: url) }
    }

    func showExportPanel() {
        guard let project, let projectURL, let sourceURL = playback.sourceURL else {
            errorMessage = ExportError.sourceUnavailable.localizedDescription
            return
        }

        do {
            let scope = try makeExportScope(project: project)
            let lines = try makeExportLineAssets(project: project, projectURL: projectURL, scope: scope)

            let panel = NSSavePanel()
            panel.title = "Export Dubbed Video"
            panel.prompt = "Export"
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = exportFileName(projectName: project.name)
            guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
            let destination = selectedURL.pathExtension.lowercased() == "mp4"
                ? selectedURL
                : selectedURL.appendingPathExtension("mp4")
            let trackIndex = selectedAudioTrack.flatMap { track in
                project.sourceVideo?.metadata.audioTracks.firstIndex(of: track)
            } ?? 0
            let logURL = projectURL.appending(path: "temp/export.log")
            let preparedURLs = preparedMovieAudioURLs()
            let job = ExportJob(
                sourceURL: sourceURL,
                destinationURL: destination,
                logURL: logURL,
                sourceDuration: playback.duration,
                audioTrackIndex: trackIndex,
                scope: scope,
                lines: lines,
                duckedOriginalVolume: project.settings.duckedOriginalVolume,
                preparedDialogueURL: preparedURLs?.dialogue,
                preparedBackgroundURL: preparedURLs?.background,
                preparedBackgroundGain: project.settings.cleanBackgroundVolume,
                preparedAudioTimelineStart: preparedURLs?.timelineStart ?? 0
            )
            exportController.start(job: job)
        } catch {
            present(error, fallback: "The export settings are invalid.")
        }
    }

    func showSubtitleImportPanel() {
        guard project?.sourceVideo != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Subtitles"
        panel.prompt = "Import"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt") ?? .plainText,
            UTType(filenameExtension: "vtt") ?? .plainText
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importSubtitleFile(at: url) }
    }

    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let droppedURL = urls.first(where: { $0.isFileURL }) else { return false }

        if ["srt", "vtt"].contains(droppedURL.pathExtension.lowercased()), project?.sourceVideo != nil {
            Task { await importSubtitleFile(at: droppedURL) }
            return true
        }

        if project == nil {
            beginNewProjectSetup(with: droppedURL)
        } else {
            Task { await importVideo(at: droppedURL) }
        }
        return true
    }

    var selectedSegment: DubSegment? {
        guard let selectedSegmentID else { return nil }
        return project?.segments.first { $0.id == selectedSegmentID }
    }

    var selectedTake: RecordingTake? {
        guard let segment = selectedSegment, let takeID = segment.selectedTakeID else { return nil }
        return segment.takes.first { $0.id == takeID }
    }

    var projectPlaybackRange: ClosedRange<TimeInterval> {
        project?.mediaScope.resolvedRange(sourceDuration: playback.duration)
            ?? (0...max(playback.duration, 0))
    }

    var projectDuration: TimeInterval {
        let range = projectPlaybackRange
        return max(0, range.upperBound - range.lowerBound)
    }

    func projectDisplayTime(_ sourceTime: TimeInterval) -> TimeInterval {
        max(0, sourceTime - projectPlaybackRange.lowerBound)
    }

    var selectedAudioTrack: AudioTrackMetadata? {
        guard let tracks = project?.sourceVideo?.metadata.audioTracks else { return nil }
        let selectedID = project?.settings.selectedAudioTrackID
        return tracks.first(where: { $0.id == selectedID }) ?? tracks.first
    }

    var musicAndEffectsCandidate: AudioTrackMetadata? {
        guard let selectedAudioTrack else { return nil }
        return project?.sourceVideo?.metadata.audioTracks.first {
            $0.id != selectedAudioTrack.id && $0.isLikelyMusicAndEffects
        }
    }

    var recommendedAudioPreparationStrategy: AudioPreparationStrategy {
        if musicAndEffectsCandidate != nil { return .embeddedMusicAndEffects }
        if (selectedAudioTrack?.channelCount ?? 2) >= 6 { return .surroundAssisted }
        return .cinematicSeparation
    }

    var selectedAudioPreparationStrategy: AudioPreparationStrategy? {
        switch project?.settings.audioPreparationPreference ?? .automatic {
        case .automatic:
            recommendedAudioPreparationStrategy
        case .embeddedMusicAndEffects:
            musicAndEffectsCandidate == nil ? nil : .embeddedMusicAndEffects
        case .surroundAssisted:
            (selectedAudioTrack?.channelCount ?? 0) >= 6 ? .surroundAssisted : nil
        case .cinematicSeparation:
            .cinematicSeparation
        case .duckingOnly:
            nil
        }
    }

    func supportsAudioPreparationPreference(_ preference: AudioPreparationPreference) -> Bool {
        switch preference {
        case .automatic, .cinematicSeparation, .duckingOnly:
            true
        case .embeddedMusicAndEffects:
            musicAndEffectsCandidate != nil
        case .surroundAssisted:
            (selectedAudioTrack?.channelCount ?? 0) >= 6
        }
    }

    var preparedAudioAsset: PreparedAudioAsset? {
        guard let selectedAudioTrack,
              let projectURL,
              let strategy = selectedAudioPreparationStrategy else { return nil }
        let expectedModelID = preparedAudioModelID(strategy: strategy)
        return project?.preparedAudioAssets.first { asset in
            guard asset.sourceAudioTrackID == selectedAudioTrack.id,
                  asset.strategy == strategy,
                  asset.modelID == expectedModelID else { return false }
            let dialogueURL = projectURL.appending(path: "prepared-audio").appending(path: asset.dialogueFileName)
            let backgroundURL = projectURL.appending(path: "prepared-audio").appending(path: asset.backgroundFileName)
            return FileManager.default.fileExists(atPath: dialogueURL.path)
                && FileManager.default.fileExists(atPath: backgroundURL.path)
        }
    }

    func selectSegment(_ id: UUID?) {
        guard !recording.isActive else { return }
        selectedSegmentID = id
        refreshWaveforms()
        guard let segment = selectedSegment else { return }
        if let acceptedVersion = effectiveAcceptedVersion(for: segment) {
            segmentPreviewMode = acceptedVersion.treatment
        }
        playback.pause()
        playback.seek(to: segment.startTime)
    }

    func selectPreviousSegment() {
        moveSelection(by: -1)
    }

    func selectNextSegment() {
        moveSelection(by: 1)
    }

    func playSelectedSegment() {
        continuousDubPreviewActive = false
        previewSelectedSegment(mode: .original)
    }

    func playSelectedSegmentWithContext() {
        guard let segment = selectedSegment, let settings = project?.settings else { return }
        continuousDubPreviewActive = false
        playback.play(
            from: max(projectPlaybackRange.lowerBound, segment.startTime - settings.preRollDuration),
            to: min(projectPlaybackRange.upperBound, segment.endTime + settings.postRollDuration)
        )
    }

    func seekWithinSelectedSegment(to fraction: Double) {
        guard let segment = selectedSegment, !recording.isActive else { return }
        let clamped = min(max(fraction, 0), 1)
        playback.seek(to: segment.startTime + segment.duration * clamped)
    }

    func previewSelectedSegment(mode: SegmentMixTreatment? = nil) {
        guard let segment = selectedSegment, let project else { return }
        continuousDubPreviewActive = false
        let mode = mode ?? segmentPreviewMode
        segmentPreviewMode = mode
        recording.stopTakePlayback()

        if mode != .original, selectedTake == nil {
            errorMessage = "Record or select a take before previewing the dubbed voice."
            return
        }
        if mode == .cleanDub, !hasCleanBackgroundForSelectedTrack(segment) {
            errorMessage = "Prepare this movie’s background using the selected source audio track before previewing the clean dub."
            return
        }

        playback.play(from: segment.startTime, to: segment.endTime) { [weak self] in
            guard let self else { return }
            switch mode {
            case .original:
                playback.player.volume = project.settings.originalVolume
            case .takeOnly:
                playback.player.volume = 0
            case .duckedMix:
                playback.player.volume = project.settings.duckedOriginalVolume
            case .cleanDub:
                playback.player.volume = 0
            }

            guard mode != .original, let take = selectedTake,
                  let url = recordingURL(for: take) else { return }
            do {
                if mode == .cleanDub,
                   let background = cleanBackgroundPlaybackAsset(for: segment) {
                    try recording.playSeparatedPreview(
                        takeID: take.id,
                        takeURL: url,
                        takeGain: take.gain,
                        backgroundURL: background.url,
                        backgroundOffset: background.offset,
                        backgroundGain: project.settings.cleanBackgroundVolume
                    )
                } else {
                    try recording.playTake(
                        id: take.id,
                        at: url,
                        gain: take.gain,
                        timelineDuration: segment.duration
                    )
                }
            } catch {
                present(error, fallback: "The selected recording could not be played.")
            }
        }
    }

    @discardableResult
    func prepareCleanBackground() -> Bool {
        prepareMovieAudio()
    }

    @discardableResult
    func prepareMovieAudio() -> Bool {
        guard !isPreparingMovieAudio,
              let projectURL,
              let sourceURL = accessedVideoURL ?? playback.sourceURL,
              let selectedAudioTrack,
              let strategy = selectedAudioPreparationStrategy,
              let audioTrackIndex = project?.sourceVideo?.metadata.audioTracks.firstIndex(of: selectedAudioTrack) else {
            if project?.settings.audioPreparationPreference == .duckingOnly {
                errorMessage = "This project is configured to use original-audio ducking without source separation."
            } else if project != nil {
                errorMessage = "The selected preparation method is not available for this audio track. Choose Automatic or Cinematic AI in Audio settings."
            }
            return false
        }
        playback.pause()
        recording.stopTakePlayback()
        isPreparingMovieAudio = true
        audioPreparationProgress = 0.02
        audioPreparationMessage = "Inspecting the selected audio track…"

        let meCandidate = musicAndEffectsCandidate
        let sourceDuration = project?.sourceVideo?.metadata.duration ?? playback.duration
        let projectRange = project?.mediaScope.resolvedRange(sourceDuration: sourceDuration)
            ?? (0...max(sourceDuration, 0))
        let preparationHandle: TimeInterval = project?.mediaScope.mode == .clip ? 3 : 0
        let preparationStart = max(0, projectRange.lowerBound - preparationHandle)
        let preparationEnd = min(sourceDuration, projectRange.upperBound + preparationHandle)
        let preparationDuration = max(0, preparationEnd - preparationStart)
        let cleaningPreset = project?.settings.dialogueCleaningPreset ?? .balanced
        let workingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "OpenVoicer-MovieAudio-\(UUID().uuidString)", directoryHint: .isDirectory)
        let originalMixURL = workingDirectory.appending(path: "original-mix.wav")
        let dialogueURL = workingDirectory.appending(path: "dialogue.wav")
        let backgroundURL = workingDirectory.appending(path: "background.wav")

        audioPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                audioPreparationProgress = 0.06
                audioPreparationMessage = "Extracting the selected movie mix…"
                try await ffmpegService.extractAudioTrack(
                    from: sourceURL,
                    audioTrackIndex: audioTrackIndex,
                    mode: .stereoMix,
                    startTime: preparationStart,
                    duration: preparationDuration,
                    destination: originalMixURL
                )
                try Task.checkCancellation()

                switch strategy {
                case .embeddedMusicAndEffects:
                    guard let meCandidate,
                          let tracks = project?.sourceVideo?.metadata.audioTracks,
                          let meIndex = tracks.firstIndex(of: meCandidate) else {
                        throw AudioPreparationError.musicAndEffectsUnavailable
                    }
                    audioPreparationProgress = 0.38
                    audioPreparationMessage = "Extracting the embedded M&E track…"
                    try await ffmpegService.extractAudioTrack(
                        from: sourceURL,
                        audioTrackIndex: meIndex,
                        mode: .stereoMix,
                        startTime: preparationStart,
                        duration: preparationDuration,
                        destination: backgroundURL
                    )
                    try Task.checkCancellation()
                    audioPreparationProgress = 0.72
                    audioPreparationMessage = "Aligning the dialogue guide with M&E…"
                    try await ffmpegService.createDialogueDifference(
                        originalURL: originalMixURL,
                        backgroundURL: backgroundURL,
                        destination: dialogueURL
                    )
                    try finalizePreparedMovieAudio(
                        dialogueURL: dialogueURL,
                        backgroundURL: backgroundURL,
                        sourceTrack: selectedAudioTrack,
                        backgroundTrack: meCandidate,
                        strategy: strategy,
                        projectURL: projectURL,
                        timelineStart: preparationStart,
                        timelineDuration: preparationDuration
                    )
                    finishMovieAudioPreparation(workingDirectory: workingDirectory)

                case .surroundAssisted, .cinematicSeparation:
                    try Task.checkCancellation()
                    audioPreparationProgress = 0.22
                    audioPreparationMessage = strategy == .surroundAssisted
                        ? "Separating the complete surround movie mix…"
                        : "Separating continuous dialogue, music, and effects…"
                    sourceSeparation.prepare(
                        inputURL: originalMixURL,
                        outputURL: backgroundURL,
                        dialogueOutputURL: dialogueURL,
                        dialogueInputURL: nil,
                        cleaningPreset: cleaningPreset
                    ) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success:
                            do {
                                try finalizePreparedMovieAudio(
                                    dialogueURL: dialogueURL,
                                    backgroundURL: backgroundURL,
                                    sourceTrack: selectedAudioTrack,
                                    backgroundTrack: nil,
                                    strategy: strategy,
                                    projectURL: projectURL,
                                    timelineStart: preparationStart,
                                    timelineDuration: preparationDuration
                                )
                                finishMovieAudioPreparation(workingDirectory: workingDirectory)
                            } catch {
                                failMovieAudioPreparation(
                                    error,
                                    workingDirectory: workingDirectory,
                                    fallback: "The prepared movie stems could not be saved."
                                )
                            }
                        case .failure(let error):
                            failMovieAudioPreparation(
                                error,
                                workingDirectory: workingDirectory,
                                fallback: "Dialogue separation failed."
                            )
                        }
                    }
                }
            } catch {
                failMovieAudioPreparation(
                    error,
                    workingDirectory: workingDirectory,
                    fallback: "The movie audio could not be prepared."
                )
            }
        }
        return true
    }

    func toggleMainPlayback() {
        guard !recording.isActive else { return }
        if playback.isPlaying {
            playback.pause()
            continuousDubPreviewActive = false
        } else {
            recording.stopTakePlayback()
            continuousDubPreviewActive = mainPlaybackMode == .dubbed
            let range = projectPlaybackRange
            if project?.mediaScope.mode == .clip {
                let start = range.contains(playback.currentTime)
                    && playback.currentTime < range.upperBound - 0.05
                    ? playback.currentTime
                    : range.lowerBound
                playback.play(from: start, to: range.upperBound) { [weak self] in
                    guard let self, continuousDubPreviewActive else { return }
                    synchronizeContinuousDubPreview(at: start)
                }
            } else {
                playback.togglePlayback()
                if continuousDubPreviewActive {
                    synchronizeContinuousDubPreview(at: playback.currentTime)
                }
            }
        }
    }

    func seekMainPlayback(to time: TimeInterval) {
        stopContinuousDubOverlay()
        let range = projectPlaybackRange
        let clampedTime = min(max(time, range.lowerBound), range.upperBound)
        playback.seek(to: clampedTime)
        continuousDubPreviewActive = playback.isPlaying && mainPlaybackMode == .dubbed
        if continuousDubPreviewActive {
            synchronizeContinuousDubPreview(at: clampedTime)
        }
    }

    func skipMainPlayback(by seconds: TimeInterval) {
        seekMainPlayback(to: playback.currentTime + seconds)
    }

    func cancelSourceSeparation() {
        audioPreparationTask?.cancel()
        audioPreparationTask = nil
        sourceSeparation.cancel()
        isPreparingMovieAudio = false
        audioPreparationProgress = 0
        audioPreparationMessage = "Movie audio preparation cancelled"
    }

    func updateDuckedOriginalVolume(_ volume: Float) {
        guard var project else { return }
        project.settings.duckedOriginalVolume = min(max(volume, 0), 1)
        self.project = project
        save()
    }

    func updateCleanBackgroundVolume(_ volume: Float) {
        guard var project else { return }
        project.settings.cleanBackgroundVolume = min(max(volume, 0), 1)
        self.project = project
        save()
    }

    func updateAudioPreparationPreference(_ preference: AudioPreparationPreference) {
        guard var project else { return }
        stopContinuousDubOverlay()
        project.settings.audioPreparationPreference = preference
        self.project = project
        save()
    }

    func updateDialogueCleaningPreset(_ preset: DialogueCleaningPreset) {
        guard var project,
              project.settings.dialogueCleaningPreset != preset else { return }
        stopContinuousDubOverlay()
        project.settings.dialogueCleaningPreset = preset
        self.project = project
        save()
    }

    func updateSelectedAudioTrack(_ trackID: String) {
        guard var project,
              let tracks = project.sourceVideo?.metadata.audioTracks,
              let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        guard project.settings.selectedAudioTrackID != trackID else { return }

        playback.pause()
        recording.stopTakePlayback()
        project.settings.selectedAudioTrackID = trackID
        self.project = project
        save()
        refreshWaveforms()

        Task { [weak self] in
            do {
                try await self?.playback.selectAudioTrack(at: trackIndex)
            } catch {
                self?.present(error, fallback: "The selected audio track could not be played.")
            }
        }
    }

    func hasCleanBackgroundForSelectedTrack(_: DubSegment) -> Bool {
        preparedAudioAsset != nil
    }

    func toggleRecording() {
        switch recording.state {
        case .idle:
            beginRecordingCurrentSegment()
        case .countdown:
            cancelRecording()
        case .recording:
            finishCurrentRecording()
        case .finishing:
            break
        }
    }

    func playTake(_ takeID: UUID) {
        if recording.playingTakeID == takeID {
            recording.stopTakePlayback()
            return
        }
        guard let segment = selectedSegment,
              let take = segment.takes.first(where: { $0.id == takeID }),
              let url = recordingURL(for: take) else { return }
        do {
            playback.pause()
            try recording.playTake(
                id: take.id,
                at: url,
                gain: take.gain,
                timelineDuration: segment.duration
            )
        } catch {
            present(error, fallback: "The selected recording could not be played.")
        }
    }

    func selectTake(_ takeID: UUID) {
        updateSelectedSegment { segment in
            guard segment.takes.contains(where: { $0.id == takeID }) else { return }
            segment.selectedTakeID = takeID
            segment.acceptedVersion = nil
            segment.status = .recorded
        }
        refreshWaveforms()
    }

    var canAcceptSelectedVersion: Bool {
        guard let segment = selectedSegment,
              !recording.isActive else { return false }
        if segmentPreviewMode.requiresTake, segment.selectedTakeID == nil { return false }
        if segmentPreviewMode == .cleanDub {
            return hasCleanBackgroundForSelectedTrack(segment)
        }
        return true
    }

    func effectiveAcceptedVersion(for segment: DubSegment) -> AcceptedSegmentVersion? {
        guard segment.status == .accepted else { return nil }
        if let acceptedVersion = segment.acceptedVersion {
            return acceptedVersion
        }
        guard let takeID = segment.selectedTakeID else { return nil }
        return AcceptedSegmentVersion(
            takeID: takeID,
            treatment: hasCleanBackgroundForSelectedTrack(segment) ? .cleanDub : .duckedMix
        )
    }

    func acceptSelectedVersionAndAdvance() {
        guard canAcceptSelectedVersion else { return }
        let treatment = segmentPreviewMode
        let takeID = treatment.requiresTake ? selectedSegment?.selectedTakeID : nil
        updateSelectedSegment { segment in
            segment.acceptedVersion = AcceptedSegmentVersion(
                takeID: takeID,
                treatment: treatment
            )
            segment.status = .accepted
            for index in segment.takes.indices {
                segment.takes[index].isFavorite = takeID != nil && segment.takes[index].id == takeID
            }
        }
        selectNextSegment()
    }

    func deleteSelectedTake() {
        guard let projectURL,
              let segment = selectedSegment,
              let takeID = segment.selectedTakeID,
              let take = segment.takes.first(where: { $0.id == takeID }) else { return }

        recording.stopTakePlayback()
        let sourceURL = projectURL.appending(path: "recordings").appending(path: take.fileName)
        let recoveryURL = projectURL
            .appending(path: "temp/deleted-takes", directoryHint: .isDirectory)
            .appending(path: "\(take.id.uuidString).wav")
        do {
            try FileManager.default.createDirectory(
                at: recoveryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try FileManager.default.moveItem(at: sourceURL, to: recoveryURL)
            }
            updateSelectedSegment { segment in
                segment.takes.removeAll { $0.id == takeID }
                segment.selectedTakeID = segment.takes.last?.id
                segment.acceptedVersion = nil
                segment.status = segment.takes.isEmpty ? .pending : .recorded
            }
            refreshWaveforms()
        } catch {
            present(error, fallback: "The recording could not be deleted.")
        }
    }

    func updateSelectedInputDevice(_ id: String?) {
        guard var project else { return }
        project.settings.selectedInputDeviceID = id
        self.project = project
        save()
    }

    func updateRecordingCountdown(_ seconds: Int) {
        guard var project else { return }
        project.settings.recordingCountdownSeconds = min(max(seconds, 0), 3)
        self.project = project
        save()
    }

    func updatePlaySourceAudioWhileRecording(_ enabled: Bool) {
        guard var project else { return }
        project.settings.playSourceAudioWhileRecording = enabled
        self.project = project
        save()
    }

    func importEmbeddedSubtitleTrack(_ track: EmbeddedSubtitleTrack) {
        Task { await extractAndImportEmbeddedTrack(track) }
    }

    func save() {
        guard var project, let projectURL else { return }
        project.modifiedAt = Date()
        self.project = project
        recentProjects.updateMetadata(for: project, at: projectURL)

        Task {
            do {
                try await projectStore.save(project, at: projectURL)
            } catch {
                present(error, fallback: "The project could not be saved.")
            }
        }
    }

    private func makeExportScope(project: DubProject) throws -> ExportRenderScope {
        let duration = playback.duration
        switch exportController.exportType {
        case .finishedMovie:
            if project.mediaScope.mode == .clip {
                let range = project.mediaScope.resolvedRange(sourceDuration: duration)
                return .continuous(ExportTimeRange(start: range.lowerBound, end: range.upperBound))
            }
            return .finishedMovie

        case .continuousClip:
            let range: ExportTimeRange
            switch exportController.clipRangeMode {
            case .currentLine:
                guard let segment = selectedSegment else { throw ExportError.noCurrentLine }
                range = rangeWithContext(
                    start: segment.startTime,
                    end: segment.endTime,
                    duration: duration
                )
            case .selectedLines:
                let selected = project.segments.filter { exportController.selectedLineIDs.contains($0.id) }
                guard let start = selected.map(\.startTime).min(),
                      let end = selected.map(\.endTime).max() else {
                    throw ExportError.noSelectedLines
                }
                range = rangeWithContext(start: start, end: end, duration: duration)
            case .custom:
                range = ExportTimeRange(
                    start: exportController.customStartTime,
                    end: exportController.customEndTime
                )
            }
            let bounds = project.mediaScope.resolvedRange(sourceDuration: duration)
            guard range.start >= bounds.lowerBound,
                  range.end <= bounds.upperBound,
                  range.duration > 0 else {
                throw ExportError.invalidTimeRange
            }
            return .continuous(range)

        case .reviewReel:
            let candidates: [DubSegment]
            switch exportController.reviewLineMode {
            case .accepted:
                candidates = project.segments.filter {
                    $0.status == .accepted && effectiveAcceptedVersion(for: $0) != nil
                }
            case .selected:
                guard !exportController.selectedLineIDs.isEmpty else {
                    throw ExportError.noSelectedLines
                }
                candidates = project.segments.filter {
                    exportController.selectedLineIDs.contains($0.id)
                        && $0.status == .accepted
                        && effectiveAcceptedVersion(for: $0) != nil
                }
            }
            guard !candidates.isEmpty else { throw ExportError.noAcceptedLines }
            let ranges = candidates
                .sorted { $0.startTime < $1.startTime }
                .map {
                    rangeWithContext(start: $0.startTime, end: $0.endTime, duration: duration)
                }
            return .reviewReel(mergeOverlappingRanges(ranges))
        }
    }

    private func rangeWithContext(
        start: TimeInterval,
        end: TimeInterval,
        duration: TimeInterval
    ) -> ExportTimeRange {
        let bounds = project?.mediaScope.resolvedRange(sourceDuration: duration)
            ?? (0...max(duration, 0))
        return ExportTimeRange(
            start: max(bounds.lowerBound, start - exportController.contextDuration),
            end: min(bounds.upperBound, end + exportController.contextDuration)
        )
    }

    private func mergeOverlappingRanges(_ ranges: [ExportTimeRange]) -> [ExportTimeRange] {
        var merged: [ExportTimeRange] = []
        for range in ranges where range.duration > 0 {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func makeExportLineAssets(
        project: DubProject,
        projectURL: URL,
        scope: ExportRenderScope
    ) throws -> [ExportLineAsset] {
        let ranges: [ExportTimeRange]
        switch scope {
        case .finishedMovie:
            ranges = [ExportTimeRange(start: 0, end: playback.duration)]
        case .continuous(let range):
            ranges = [range]
        case .reviewReel(let reelRanges):
            ranges = reelRanges
        }

        return try project.segments.compactMap { segment in
            guard segment.status == .accepted,
                  ranges.contains(where: { segment.endTime > $0.start && segment.startTime < $0.end }),
                  let acceptedVersion = effectiveAcceptedVersion(for: segment) else { return nil }

            if acceptedVersion.treatment == .original { return nil }

            guard let acceptedTakeID = acceptedVersion.takeID,
                  let take = segment.takes.first(where: { $0.id == acceptedTakeID }) else { return nil }

            let takeURL = projectURL.appending(path: "recordings").appending(path: take.fileName)
            guard FileManager.default.fileExists(atPath: takeURL.path) else { return nil }

            if acceptedVersion.treatment == .cleanDub,
               preparedAudioAsset == nil {
                throw ExportError.cleanBackgroundUnavailable
            }

            let exportTreatment: ExportMixTreatment = switch acceptedVersion.treatment {
            case .duckedMix: .duckedMix
            case .cleanDub: .cleanDub
            case .takeOnly: .takeOnly
            case .original: preconditionFailure("Original lines do not require an export asset")
            }

            return ExportLineAsset(
                segmentID: segment.id,
                startTime: segment.startTime,
                endTime: segment.endTime,
                takeURL: takeURL,
                takeDuration: take.duration,
                takeGain: take.gain,
                backgroundURL: nil,
                backgroundPreRoll: 0,
                backgroundGain: project.settings.cleanBackgroundVolume,
                treatment: exportTreatment
            )
        }
    }

    private func exportFileName(projectName: String) -> String {
        let suffix: String
        switch exportController.exportType {
        case .finishedMovie: suffix = "Dubbed"
        case .continuousClip: suffix = "Clip"
        case .reviewReel: suffix = "Review Reel"
        }
        return "\(projectName) – \(suffix).mp4"
    }

    private func beginNewProjectSetup(with videoURL: URL) {
        guard !isInspectingNewMovie else { return }
        dismissNewProjectAssistant()
        isInspectingNewMovie = true
        let didStartAccess = videoURL.startAccessingSecurityScopedResource()
        if didStartAccess { pendingNewVideoURL = videoURL }

        Task { [weak self] in
            guard let self else { return }
            do {
                var metadata: VideoMetadata
                do {
                    metadata = try await metadataLoader.load(from: videoURL)
                } catch {
                    metadata = try await ffmpegService.mediaMetadata(in: videoURL)
                }
                if let tracks = try? await ffmpegService.audioTracks(in: videoURL), !tracks.isEmpty {
                    metadata.audioTracks = tracks
                }
                guard !metadata.audioTracks.isEmpty else {
                    throw NewProjectSetupError.noAudioTracks
                }
                let subtitles = (try? await ffmpegService.embeddedSubtitleTracks(in: videoURL)) ?? []
                newProjectDraft = NewProjectDraft(
                    sourceURL: videoURL,
                    metadata: metadata,
                    embeddedSubtitleTracks: subtitles
                )
                isInspectingNewMovie = false
            } catch {
                isInspectingNewMovie = false
                dismissNewProjectAssistant()
                present(error, fallback: "The selected movie could not be inspected.")
            }
        }
    }

    @discardableResult
    private func createProject(named name: String, at url: URL) async -> Bool {
        do {
            cancelRecording()
            let newProject = DubProject(name: name)
            try await projectStore.create(newProject, at: url)
            releaseScopedAccess()
            project = newProject
            projectURL = url
            if url.startAccessingSecurityScopedResource() {
                accessedProjectURL = url
            }
            playback.clear()
            selectedSegmentID = nil
            refreshWaveforms()
            embeddedSubtitleTracks = []
            recentProjects.recordOpened(project: newProject, at: url)
            return true
        } catch {
            present(error, fallback: "The project could not be created.")
            return false
        }
    }

    private func openProject(at url: URL) async {
        cancelRecording()
        let didStartAccess = url.startAccessingSecurityScopedResource()
        do {
            let loadedProject = try await projectStore.load(from: url)
            releaseScopedAccess()
            if didStartAccess {
                accessedProjectURL = url
            }
            project = loadedProject
            projectURL = url
            selectedSegmentID = nil
            playback.clear()
            try await restoreSourceVideoIfPresent()
            await refreshEmbeddedSubtitleTracks()
            if let firstSegment = project?.segments.first {
                selectSegment(firstSegment.id)
            } else if project?.mediaScope.mode == .clip {
                playback.seek(to: projectPlaybackRange.lowerBound)
            }
            recentProjects.recordOpened(project: loadedProject, at: url)
            logger.info("Opened project \(loadedProject.name, privacy: .public)")
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            present(error, fallback: "The selected OpenVoicer project could not be opened.")
        }
    }

    @discardableResult
    private func importVideo(at url: URL) async -> Bool {
        guard var project, let projectURL else { return false }
        isLoadingVideo = true
        defer { isLoadingVideo = false }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        do {
            cancelRecording()
            playback.clear()
            let playbackSource = try await preparePlaybackSource(for: url, in: projectURL)
            var metadata = try await metadataLoader.load(from: playbackSource.url)
            if let probedTracks = try? await ffmpegService.audioTracks(in: url),
               !probedTracks.isEmpty {
                metadata.audioTracks = probedTracks
            }
            let bookmark = try SecurityScopedBookmarks.makeBookmark(for: url)

            releaseVideoAccess()
            if didStartAccess {
                accessedVideoURL = url
            }

            project.sourceVideo = SourceVideoReference(
                displayName: url.lastPathComponent,
                bookmarkData: bookmark,
                lastKnownPath: url.path,
                metadata: metadata,
                playbackFileName: playbackSource.relativeFileName,
                playbackPreparationVersion: playbackSource.relativeFileName == nil
                    ? nil
                    : Self.playbackPreparationVersion
            )
            project.subtitleSource = nil
            project.segments = []
            project.settings.selectedAudioTrackID = metadata.audioTracks.first?.id
            project.modifiedAt = Date()
            self.project = project
            playback.load(url: playbackSource.url, duration: metadata.duration)
            if !metadata.audioTracks.isEmpty {
                try await playback.selectAudioTrack(at: 0)
            }
            selectSegment(nil)
            save()
            await refreshEmbeddedSubtitleTracks(sourceURL: url)
            return true
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            present(error, fallback: "The selected video could not be opened.")
            return false
        }
    }

    private func importSubtitleFile(at url: URL) async {
        guard var project else { return }
        isLoadingSubtitles = true
        defer { isLoadingSubtitles = false }
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let result = try subtitleParser.parse(fileURL: url)
            let bookmark = try? SecurityScopedBookmarks.makeBookmark(for: url)
            project.subtitleSource = SubtitleSource(
                kind: .externalFile,
                displayName: url.lastPathComponent,
                languageCode: nil,
                streamIndex: nil,
                bookmarkData: bookmark,
                lastKnownPath: url.path
            )
            project.segments = makeSegments(from: result.cues)
            project.modifiedAt = Date()
            self.project = project
            selectSegment(project.segments.first?.id)
            save()

            if result.skippedCueCount > 0 {
                logger.warning("Skipped \(result.skippedCueCount) malformed subtitle cues")
            }
        } catch {
            present(error, fallback: "The subtitle file could not be imported.")
        }
    }

    private func extractAndImportEmbeddedTrack(_ track: EmbeddedSubtitleTrack) async {
        guard var project, let projectURL, let sourceURL = accessedVideoURL else { return }
        isLoadingSubtitles = true
        defer { isLoadingSubtitles = false }

        do {
            let relativePath = "temp/embedded-subtitles/stream-\(track.streamIndex).srt"
            let destination = projectURL.appending(path: relativePath)
            try await ffmpegService.extractSubtitleTrack(track, from: sourceURL, destination: destination)
            let result = try subtitleParser.parse(fileURL: destination)
            project.subtitleSource = SubtitleSource(
                kind: .embeddedTrack,
                displayName: track.displayName,
                languageCode: track.languageCode,
                streamIndex: track.streamIndex,
                bookmarkData: nil,
                lastKnownPath: nil
            )
            project.segments = makeSegments(from: result.cues)
            project.modifiedAt = Date()
            self.project = project
            selectSegment(project.segments.first?.id)
            save()
        } catch {
            present(error, fallback: "The embedded subtitles could not be imported.")
        }
    }

    private func refreshEmbeddedSubtitleTracks(sourceURL: URL? = nil) async {
        guard let sourceURL = sourceURL ?? accessedVideoURL else {
            embeddedSubtitleTracks = []
            return
        }
        do {
            embeddedSubtitleTracks = try await ffmpegService.embeddedSubtitleTracks(in: sourceURL)
        } catch {
            embeddedSubtitleTracks = []
            logger.notice("Embedded subtitle discovery unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeSegments(from cues: [SubtitleCue]) -> [DubSegment] {
        let sourceDuration = project?.sourceVideo?.metadata.duration ?? playback.duration
        let range = project?.mediaScope.resolvedRange(sourceDuration: sourceDuration)
            ?? (0...max(sourceDuration, 0))
        return cues.filter {
            $0.endTime > range.lowerBound && $0.startTime < range.upperBound
        }.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }.map {
            DubSegment(
                startTime: max($0.startTime, range.lowerBound),
                endTime: min($0.endTime, range.upperBound),
                text: $0.text
            )
        }
    }

    private func moveSelection(by offset: Int) {
        guard let segments = project?.segments, !segments.isEmpty else { return }
        let currentIndex = selectedSegmentID.flatMap { id in segments.firstIndex { $0.id == id } }
        let proposedIndex = (currentIndex ?? (offset > 0 ? -1 : segments.count)) + offset
        let targetIndex = min(max(proposedIndex, 0), segments.count - 1)
        selectSegment(segments[targetIndex].id)
    }

    private func beginRecordingCurrentSegment() {
        guard let segment = selectedSegment, let project, let projectURL else { return }
        playback.pause()
        playback.seek(to: segment.startTime)
        playback.player.volume = project.settings.playSourceAudioWhileRecording
            ? project.settings.originalVolume
            : 0
        recordingVideoPlaybackActive = true
        recording.stopTakePlayback()

        let takeID = UUID()
        let relativeFileName = "\(segment.id.uuidString)/\(takeID.uuidString).wav"
        let destination = projectURL.appending(path: "recordings").appending(path: relativeFileName)
        pendingTake = PendingRecordingTake(
            id: takeID,
            segmentID: segment.id,
            relativeFileName: relativeFileName
        )

        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recording.begin(
                    destinationURL: destination,
                    deviceID: project.settings.selectedInputDeviceID,
                    countdownSeconds: project.settings.recordingCountdownSeconds,
                    timelineDuration: segment.duration
                )
                guard !Task.isCancelled else {
                    recording.cancel()
                    stopRecordingVideoPlayback()
                    return
                }
                // Start the muted picture only after microphone capture is live.
                // This gives the performer lip movement without recording the
                // source dialogue through speakers.
                let recordingPlaybackVolume: Float = project.settings.playSourceAudioWhileRecording
                    ? project.settings.originalVolume
                    : 0
                playback.play(
                    from: segment.startTime,
                    to: segment.endTime,
                    playbackVolume: recordingPlaybackVolume
                )
                scheduleAutomaticStop(after: max(segment.duration + 0.75, 2))
            } catch is CancellationError {
                recording.cancel()
                stopRecordingVideoPlayback()
            } catch {
                pendingTake = nil
                stopRecordingVideoPlayback()
                present(error, fallback: "The microphone recording could not be started.")
            }
        }
    }

    private func scheduleAutomaticStop(after seconds: TimeInterval) {
        automaticStopTask?.cancel()
        automaticStopTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.finishCurrentRecording()
            } catch { }
        }
    }

    private func finishCurrentRecording() {
        guard recording.state == .recording,
              finishingRecordingTask == nil,
              let pendingTake else { return }
        automaticStopTask?.cancel()
        automaticStopTask = nil
        stopRecordingVideoPlayback()

        finishingRecordingTask = Task { [weak self] in
            guard let self else { return }
            defer { finishingRecordingTask = nil }
            do {
                let result = try await recording.stop()
                addRecordingTake(pendingTake, duration: result.duration)
                self.pendingTake = nil
            } catch {
                self.pendingTake = nil
                present(error, fallback: "The recording could not be saved.")
            }
        }
    }

    private func cancelRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        automaticStopTask?.cancel()
        automaticStopTask = nil
        finishingRecordingTask?.cancel()
        finishingRecordingTask = nil
        recording.cancel()
        stopRecordingVideoPlayback()
        pendingTake = nil
    }

    private func stopRecordingVideoPlayback() {
        guard recordingVideoPlaybackActive else { return }
        recordingVideoPlaybackActive = false
        playback.pause()
        playback.player.volume = project?.settings.originalVolume ?? 1
    }

    private func addRecordingTake(_ pending: PendingRecordingTake, duration: TimeInterval) {
        guard var project,
              let segmentIndex = project.segments.firstIndex(where: { $0.id == pending.segmentID }) else { return }
        let take = RecordingTake(
            id: pending.id,
            fileName: pending.relativeFileName,
            createdAt: Date(),
            duration: duration,
            gain: project.settings.recordingGain,
            isFavorite: false
        )
        project.segments[segmentIndex].takes.append(take)
        project.segments[segmentIndex].selectedTakeID = take.id
        project.segments[segmentIndex].acceptedVersion = nil
        project.segments[segmentIndex].status = .recorded
        project.modifiedAt = Date()
        self.project = project
        refreshWaveforms()
        save()
    }

    private func updateSelectedSegment(_ mutation: (inout DubSegment) -> Void) {
        guard var project,
              let selectedSegmentID,
              let index = project.segments.firstIndex(where: { $0.id == selectedSegmentID }) else { return }
        mutation(&project.segments[index])
        project.modifiedAt = Date()
        self.project = project
        save()
    }

    private func updateSegment(_ id: UUID, mutation: (inout DubSegment) -> Void) {
        guard var project,
              let index = project.segments.firstIndex(where: { $0.id == id }) else { return }
        mutation(&project.segments[index])
        project.modifiedAt = Date()
        self.project = project
        save()
    }

    private func recordingURL(for take: RecordingTake) -> URL? {
        projectURL?.appending(path: "recordings").appending(path: take.fileName)
    }

    private func preparedAudioURL(fileName: String) -> URL? {
        projectURL?.appending(path: "prepared-audio").appending(path: fileName)
    }

    private func preparedMovieAudioURLs() -> (
        dialogue: URL,
        background: URL,
        timelineStart: TimeInterval
    )? {
        guard let asset = preparedAudioAsset,
              let dialogue = preparedAudioURL(fileName: asset.dialogueFileName),
              let background = preparedAudioURL(fileName: asset.backgroundFileName) else { return nil }
        return (dialogue, background, asset.timelineStart)
    }

    private func cleanBackgroundPlaybackAsset(
        for segment: DubSegment
    ) -> (url: URL, offset: TimeInterval)? {
        if let urls = preparedMovieAudioURLs() {
            return (urls.background, max(0, segment.startTime - urls.timelineStart))
        }
        return nil
    }

    private func finalizePreparedMovieAudio(
        dialogueURL: URL,
        backgroundURL: URL,
        sourceTrack: AudioTrackMetadata,
        backgroundTrack: AudioTrackMetadata?,
        strategy: AudioPreparationStrategy,
        projectURL: URL,
        timelineStart: TimeInterval,
        timelineDuration: TimeInterval
    ) throws {
        let relativeDirectory = sourceTrack.id
        let relativeDialogue = "\(relativeDirectory)/dialogue.wav"
        let relativeBackground = "\(relativeDirectory)/background.wav"
        let destinationDirectory = projectURL
            .appending(path: "prepared-audio", directoryHint: .isDirectory)
            .appending(path: relativeDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try replaceGeneratedFile(
            at: destinationDirectory.appending(path: "dialogue.wav"),
            with: dialogueURL
        )
        try replaceGeneratedFile(
            at: destinationDirectory.appending(path: "background.wav"),
            with: backgroundURL
        )

        guard var project else { return }
        project.preparedAudioAssets.removeAll { $0.sourceAudioTrackID == sourceTrack.id }
        project.preparedAudioAssets.append(
            PreparedAudioAsset(
                sourceAudioTrackID: sourceTrack.id,
                backgroundSourceTrackID: backgroundTrack?.id,
                strategy: strategy,
                dialogueFileName: relativeDialogue,
                backgroundFileName: relativeBackground,
                modelID: preparedAudioModelID(strategy: strategy),
                timelineStart: timelineStart,
                timelineDuration: timelineDuration
            )
        )
        project.modifiedAt = Date()
        self.project = project
        segmentPreviewMode = .cleanDub
        save()
    }

    private func replaceGeneratedFile(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    private func preparedAudioModelID(strategy: AudioPreparationStrategy) -> String {
        let preset = project?.settings.dialogueCleaningPreset ?? .balanced
        return switch strategy {
        case .embeddedMusicAndEffects: "embedded-me-difference-v1"
        case .surroundAssisted:
            "\(BanditSourceSeparationService.modelID)-surround-fullmix-\(preset.rawValue)-continuous-v2"
        case .cinematicSeparation:
            "\(BanditSourceSeparationService.modelID)-fullmix-\(preset.rawValue)-continuous-v2"
        }
    }

    private func finishMovieAudioPreparation(workingDirectory: URL) {
        try? FileManager.default.removeItem(at: workingDirectory)
        audioPreparationTask = nil
        isPreparingMovieAudio = false
        audioPreparationProgress = 1
        audioPreparationMessage = "Continuous movie background is ready"
    }

    private func failMovieAudioPreparation(
        _ error: Error,
        workingDirectory: URL,
        fallback: String
    ) {
        try? FileManager.default.removeItem(at: workingDirectory)
        audioPreparationTask = nil
        isPreparingMovieAudio = false
        if error is CancellationError {
            audioPreparationProgress = 0
            audioPreparationMessage = "Movie audio preparation cancelled"
        } else {
            audioPreparationMessage = error.localizedDescription
            present(error, fallback: fallback)
        }
    }

    private func refreshWaveforms() {
        let segment = selectedSegment
        let take = selectedTake
        waveforms.load(
            originalURL: playback.sourceURL,
            audioTrackIndex: selectedAudioTrack.flatMap { track in
                project?.sourceVideo?.metadata.audioTracks.firstIndex(of: track)
            } ?? 0,
            audioTrackID: selectedAudioTrack?.id,
            segment: segment,
            takeURL: take.flatMap(recordingURL(for:)),
            take: take,
            cacheRoot: projectURL?.appending(path: "waveform-cache", directoryHint: .isDirectory)
        )
    }

    private func finishSegmentPreview() {
        stopContinuousDubOverlay()
    }

    private func synchronizeContinuousDubPreview(at time: TimeInterval) {
        guard continuousDubPreviewActive,
              playback.isPlaying,
              !recording.isActive,
              let project else { return }

        let preparedURLs = preparedMovieAudioURLs()
        if let preparedURLs {
            playbackVolumeRampTask?.cancel()
            playback.player.volume = 0
            if recording.isPreparedMoviePlaying {
                recording.synchronizePreparedMoviePlayback(to: max(0, time - preparedURLs.timelineStart))
            } else {
                recording.startPreparedMoviePlayback(
                    dialogueURL: preparedURLs.dialogue,
                    backgroundURL: preparedURLs.background,
                    at: max(0, time - preparedURLs.timelineStart),
                    dialogueGain: 1,
                    backgroundGain: project.settings.cleanBackgroundVolume
                )
            }
        }

        let segment = project.segments.first {
            time >= $0.startTime
                && time < $0.endTime
                && effectiveAcceptedVersion(for: $0) != nil
        }
        guard segment?.id != activeDubbedSegmentID else { return }

        recording.transitionOutTakePlayback(
            backgroundDuration: Self.liveMixTransitionDuration
        )
        activeDubbedSegmentID = nil
        guard let segment,
              let version = effectiveAcceptedVersion(for: segment) else {
            if preparedURLs != nil {
                recording.setPreparedMovieVolumes(
                    dialogue: 1,
                    background: project.settings.cleanBackgroundVolume,
                    fadeDuration: Self.liveMixTransitionDuration
                )
            } else {
                rampPlaybackVolume(
                    to: project.settings.originalVolume,
                    duration: Self.liveMixTransitionDuration
                )
            }
            return
        }
        activeDubbedSegmentID = segment.id

        if version.treatment == .original {
            if preparedURLs != nil {
                recording.setPreparedMovieVolumes(
                    dialogue: 1,
                    background: project.settings.cleanBackgroundVolume,
                    fadeDuration: Self.liveMixTransitionDuration
                )
            } else {
                rampPlaybackVolume(
                    to: project.settings.originalVolume,
                    duration: Self.liveMixTransitionDuration
                )
            }
            return
        }

        guard let takeID = version.takeID,
              let take = segment.takes.first(where: { $0.id == takeID }),
              let takeURL = recordingURL(for: take) else { return }
        let offset = min(max(time - segment.startTime, 0), segment.duration)

        do {
            switch version.treatment {
            case .original:
                break
            case .duckedMix:
                if preparedURLs != nil {
                    recording.setPreparedMovieVolumes(
                        dialogue: project.settings.duckedOriginalVolume,
                        background: project.settings.cleanBackgroundVolume,
                        fadeDuration: Self.liveMixTransitionDuration
                    )
                } else {
                    rampPlaybackVolume(
                        to: project.settings.duckedOriginalVolume,
                        duration: Self.liveMixTransitionDuration
                    )
                }
                if offset < take.duration - 0.01 {
                    try recording.playTake(
                        id: take.id,
                        at: takeURL,
                        gain: take.gain,
                        timelineDuration: segment.duration,
                        startOffset: offset,
                        fadeInDuration: 0.015
                    )
                }
            case .takeOnly:
                if preparedURLs != nil {
                    recording.setPreparedMovieVolumes(
                        dialogue: 0,
                        background: 0,
                        fadeDuration: Self.liveMixTransitionDuration
                    )
                } else {
                    rampPlaybackVolume(to: 0, duration: Self.liveMixTransitionDuration)
                }
                if offset < take.duration - 0.01 {
                    try recording.playTake(
                        id: take.id,
                        at: takeURL,
                        gain: take.gain,
                        timelineDuration: segment.duration,
                        startOffset: offset,
                        fadeInDuration: 0.015
                    )
                }
            case .cleanDub:
                if preparedURLs != nil {
                    recording.setPreparedMovieVolumes(
                        dialogue: 0,
                        background: project.settings.cleanBackgroundVolume,
                        fadeDuration: Self.liveMixTransitionDuration
                    )
                    if offset < take.duration - 0.01 {
                        try recording.playTake(
                            id: take.id,
                            at: takeURL,
                            gain: take.gain,
                            timelineDuration: segment.duration,
                            startOffset: offset,
                            fadeInDuration: 0.015
                        )
                    }
                } else {
                    // A legacy project can contain accepted clean-dub choices
                    // backed by per-line stems. Never stitch those chunks again;
                    // use the safe ducked fallback until the movie is prepared.
                    rampPlaybackVolume(
                        to: project.settings.duckedOriginalVolume,
                        duration: Self.liveMixTransitionDuration
                    )
                    if offset < take.duration - 0.01 {
                        try recording.playTake(
                            id: take.id,
                            at: takeURL,
                            gain: take.gain,
                            timelineDuration: segment.duration,
                            startOffset: offset,
                            fadeInDuration: 0.015
                        )
                    }
                }
            }
        } catch {
            stopContinuousDubOverlay()
            present(error, fallback: "The accepted version could not be previewed.")
        }
    }

    private func stopContinuousDubOverlay() {
        playbackVolumeRampTask?.cancel()
        playbackVolumeRampTask = nil
        recording.stopTakePlayback()
        recording.stopPreparedMoviePlayback()
        playback.player.volume = project?.settings.originalVolume ?? 1
        activeDubbedSegmentID = nil
    }

    private func rampPlaybackVolume(to target: Float, duration: TimeInterval) {
        playbackVolumeRampTask?.cancel()
        let clampedTarget = min(max(target, 0), 1)
        let start = playback.player.volume
        guard duration > 0, abs(start - clampedTarget) > 0.001 else {
            playback.player.volume = clampedTarget
            playbackVolumeRampTask = nil
            return
        }

        playbackVolumeRampTask = Task { [weak self] in
            let stepCount = 8
            for step in 1...stepCount {
                guard !Task.isCancelled, let self else { return }
                try? await Task.sleep(for: .seconds(duration / Double(stepCount)))
                guard !Task.isCancelled else { return }
                let progress = Float(step) / Float(stepCount)
                playback.player.volume = start + (clampedTarget - start) * progress
            }
            self?.playbackVolumeRampTask = nil
        }
    }

    private func restoreSourceVideoIfPresent() async throws {
        guard var project, let source = project.sourceVideo, let projectURL else { return }
        let resolved = try SecurityScopedBookmarks.resolve(source.bookmarkData)
        let didStartAccess = resolved.url.startAccessingSecurityScopedResource()

        guard FileManager.default.fileExists(atPath: resolved.url.path) else {
            if didStartAccess { resolved.url.stopAccessingSecurityScopedResource() }
            throw SourceVideoError.fileMissing
        }

        if didStartAccess {
            accessedVideoURL = resolved.url
        }
        let playbackURL: URL
        if let playbackFileName = source.playbackFileName,
           source.playbackPreparationVersion == Self.playbackPreparationVersion {
            let cachedURL = projectURL.appending(path: playbackFileName)
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                playbackURL = cachedURL
            } else {
                let prepared = try await preparePlaybackSource(for: resolved.url, in: projectURL)
                playbackURL = prepared.url
                project.sourceVideo?.playbackFileName = prepared.relativeFileName
                project.sourceVideo?.playbackPreparationVersion = prepared.relativeFileName == nil
                    ? nil
                    : Self.playbackPreparationVersion
                self.project = project
                save()
            }
        } else {
            let prepared = try await preparePlaybackSource(for: resolved.url, in: projectURL)
            playbackURL = prepared.url
            if let relativeFileName = prepared.relativeFileName {
                project.sourceVideo?.playbackFileName = relativeFileName
                project.sourceVideo?.playbackPreparationVersion = Self.playbackPreparationVersion
                self.project = project
                save()
            }
        }
        if let probedTracks = try? await ffmpegService.audioTracks(in: resolved.url),
           !probedTracks.isEmpty {
            project.sourceVideo?.metadata.audioTracks = probedTracks
        }
        playback.load(url: playbackURL, duration: source.metadata.duration)
        let tracks = project.sourceVideo?.metadata.audioTracks ?? source.metadata.audioTracks
        if !tracks.isEmpty {
            let selectedID = project.settings.selectedAudioTrackID
            let selectedIndex = tracks.firstIndex { $0.id == selectedID } ?? 0
            project.settings.selectedAudioTrackID = tracks[selectedIndex].id
            self.project = project
            try await playback.selectAudioTrack(at: selectedIndex)
            save()
        }

        if resolved.isStale {
            project.sourceVideo?.bookmarkData = try SecurityScopedBookmarks.makeBookmark(for: resolved.url)
            self.project = project
            save()
        }
    }

    private func preparePlaybackSource(for sourceURL: URL, in projectURL: URL) async throws -> PlaybackSource {
        guard sourceURL.pathExtension.lowercased() == "mkv" else {
            return PlaybackSource(url: sourceURL, relativeFileName: nil)
        }

        let relativeFileName = "temp/source-playback.mov"
        let destination = projectURL.appending(path: relativeFileName)
        try await ffmpegService.createPlaybackCopy(source: sourceURL, destination: destination)
        return PlaybackSource(url: destination, relativeFileName: relativeFileName)
    }

    private func releaseVideoAccess() {
        accessedVideoURL?.stopAccessingSecurityScopedResource()
        accessedVideoURL = nil
    }

    private func releaseScopedAccess() {
        releaseVideoAccess()
        accessedProjectURL?.stopAccessingSecurityScopedResource()
        accessedProjectURL = nil
    }

    private func present(_ error: Error, fallback: String) {
        logger.error("\(error.localizedDescription, privacy: .public)")
        errorMessage = (error as? LocalizedError)?.errorDescription ?? fallback
    }
}

private struct PlaybackSource {
    let url: URL
    let relativeFileName: String?
}

private struct PendingRecordingTake {
    let id: UUID
    let segmentID: UUID
    let relativeFileName: String
}

enum SourceVideoError: LocalizedError {
    case fileMissing

    var errorDescription: String? {
        "The original movie file has moved or is no longer accessible."
    }
}

enum NewProjectSetupError: LocalizedError {
    case noAudioTracks

    var errorDescription: String? {
        switch self {
        case .noAudioTracks:
            "The selected movie does not contain an audio track that can be prepared for dubbing."
        }
    }
}

enum AudioPreparationError: LocalizedError {
    case musicAndEffectsUnavailable

    var errorDescription: String? {
        switch self {
        case .musicAndEffectsUnavailable:
            "The detected Music & Effects track is no longer available. Choose another source track or use AI preparation."
        }
    }
}
