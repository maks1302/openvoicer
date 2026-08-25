import AppKit
import Observation
import OSLog
import UniformTypeIdentifiers

@MainActor
@Observable
final class ProjectController {
    private(set) var project: DubProject?
    private(set) var projectURL: URL?
    private(set) var isLoadingVideo = false
    private(set) var isLoadingSubtitles = false
    private(set) var embeddedSubtitleTracks: [EmbeddedSubtitleTrack] = []
    private(set) var selectedSegmentID: UUID?
    var errorMessage: String?

    let playback = PlaybackController()
    let recording = RecordingController()

    private let projectStore = ProjectStore()
    private let metadataLoader = VideoMetadataLoader()
    private let ffmpegService = FFmpegService()
    private let subtitleParser = SubtitleParserService()
    private let logger = Logger(subsystem: "com.dublab.app", category: "project")
    private var accessedProjectURL: URL?
    private var accessedVideoURL: URL?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var automaticStopTask: Task<Void, Never>?
    @ObservationIgnored private var finishingRecordingTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTake: PendingRecordingTake?

    func showNewProjectPanel() {
        let panel = NSSavePanel()
        panel.title = "Create DubLab Project"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled.dublab"
        panel.allowedContentTypes = [.dubLabProject]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let packageURL = selectedURL.pathExtension.lowercased() == "dublab"
            ? selectedURL
            : selectedURL.appendingPathExtension("dublab")
        let name = packageURL.deletingPathExtension().lastPathComponent

        Task {
            await createProject(named: name, at: packageURL)
        }
    }

    func showOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open DubLab Project"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.dubLabProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(at: url) }
    }

    func openProjectURL(_ url: URL) {
        guard url.pathExtension.lowercased() == "dublab" else { return }
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
            createProjectForDroppedVideo(droppedURL)
        } else {
            Task { await importVideo(at: droppedURL) }
        }
        return true
    }

    var selectedSegment: DubSegment? {
        guard let selectedSegmentID else { return nil }
        return project?.segments.first { $0.id == selectedSegmentID }
    }

    func selectSegment(_ id: UUID?) {
        guard !recording.isActive else { return }
        selectedSegmentID = id
        guard let segment = selectedSegment else { return }
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
        guard let segment = selectedSegment else { return }
        playback.play(from: segment.startTime, to: segment.endTime)
    }

    func playSelectedSegmentWithContext() {
        guard let segment = selectedSegment, let settings = project?.settings else { return }
        playback.play(
            from: max(0, segment.startTime - settings.preRollDuration),
            to: min(playback.duration, segment.endTime + settings.postRollDuration)
        )
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
            try recording.playTake(id: take.id, at: url, gain: take.gain)
        } catch {
            present(error, fallback: "The selected recording could not be played.")
        }
    }

    func selectTake(_ takeID: UUID) {
        updateSelectedSegment { segment in
            guard segment.takes.contains(where: { $0.id == takeID }) else { return }
            segment.selectedTakeID = takeID
            segment.status = .recorded
        }
    }

    func acceptSelectedTakeAndAdvance() {
        guard let takeID = selectedSegment?.selectedTakeID else { return }
        updateSelectedSegment { segment in
            segment.selectedTakeID = takeID
            segment.status = .accepted
            for index in segment.takes.indices {
                segment.takes[index].isFavorite = segment.takes[index].id == takeID
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
                segment.status = segment.takes.isEmpty ? .pending : .recorded
            }
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

    func importEmbeddedSubtitleTrack(_ track: EmbeddedSubtitleTrack) {
        Task { await extractAndImportEmbeddedTrack(track) }
    }

    func save() {
        guard var project, let projectURL else { return }
        project.modifiedAt = Date()
        self.project = project

        Task {
            do {
                try await projectStore.save(project, at: projectURL)
            } catch {
                present(error, fallback: "The project could not be saved.")
            }
        }
    }

    private func createProjectForDroppedVideo(_ videoURL: URL) {
        let panel = NSSavePanel()
        panel.title = "Save New DubLab Project"
        panel.prompt = "Create"
        panel.allowedContentTypes = [.dubLabProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".dublab"

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let packageURL = selectedURL.pathExtension.lowercased() == "dublab"
            ? selectedURL
            : selectedURL.appendingPathExtension("dublab")
        let name = packageURL.deletingPathExtension().lastPathComponent

        Task {
            guard await createProject(named: name, at: packageURL) else { return }
            await importVideo(at: videoURL)
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
            embeddedSubtitleTracks = []
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
            }
            logger.info("Opened project \(loadedProject.name, privacy: .public)")
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            present(error, fallback: "The selected DubLab project could not be opened.")
        }
    }

    private func importVideo(at url: URL) async {
        guard var project, let projectURL else { return }
        isLoadingVideo = true
        defer { isLoadingVideo = false }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        do {
            cancelRecording()
            playback.clear()
            let playbackSource = try await preparePlaybackSource(for: url, in: projectURL)
            let metadata = try await metadataLoader.load(from: playbackSource.url)
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
                playbackFileName: playbackSource.relativeFileName
            )
            project.subtitleSource = nil
            project.segments = []
            project.modifiedAt = Date()
            self.project = project
            playback.load(url: playbackSource.url, duration: metadata.duration)
            save()
            await refreshEmbeddedSubtitleTracks(sourceURL: url)
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            present(error, fallback: "The selected video could not be opened.")
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
            selectedSegmentID = project.segments.first?.id
            if let first = project.segments.first { playback.seek(to: first.startTime) }
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
            selectedSegmentID = project.segments.first?.id
            if let first = project.segments.first { playback.seek(to: first.startTime) }
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
        cues.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }.map {
            DubSegment(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
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
                    countdownSeconds: project.settings.recordingCountdownSeconds
                )
                guard !Task.isCancelled else {
                    recording.cancel()
                    return
                }
                scheduleAutomaticStop(after: max(segment.duration + 1.5, 2))
            } catch is CancellationError {
                recording.cancel()
            } catch {
                pendingTake = nil
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
        pendingTake = nil
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
        project.segments[segmentIndex].status = .recorded
        project.modifiedAt = Date()
        self.project = project
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

    private func recordingURL(for take: RecordingTake) -> URL? {
        projectURL?.appending(path: "recordings").appending(path: take.fileName)
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
        if let playbackFileName = source.playbackFileName {
            let cachedURL = projectURL.appending(path: playbackFileName)
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                playbackURL = cachedURL
            } else {
                let prepared = try await preparePlaybackSource(for: resolved.url, in: projectURL)
                playbackURL = prepared.url
                project.sourceVideo?.playbackFileName = prepared.relativeFileName
                self.project = project
                save()
            }
        } else {
            let prepared = try await preparePlaybackSource(for: resolved.url, in: projectURL)
            playbackURL = prepared.url
            if let relativeFileName = prepared.relativeFileName {
                project.sourceVideo?.playbackFileName = relativeFileName
                self.project = project
                save()
            }
        }
        playback.load(url: playbackURL, duration: source.metadata.duration)

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
