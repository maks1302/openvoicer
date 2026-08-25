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
    var errorMessage: String?

    let playback = PlaybackController()

    private let projectStore = ProjectStore()
    private let metadataLoader = VideoMetadataLoader()
    private let ffmpegService = FFmpegService()
    private let logger = Logger(subsystem: "com.dublab.app", category: "project")
    private var accessedProjectURL: URL?
    private var accessedVideoURL: URL?

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

    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let videoURL = urls.first(where: { $0.isFileURL }) else { return false }

        if project == nil {
            createProjectForDroppedVideo(videoURL)
        } else {
            Task { await importVideo(at: videoURL) }
        }
        return true
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
            let newProject = DubProject(name: name)
            try await projectStore.create(newProject, at: url)
            releaseScopedAccess()
            project = newProject
            projectURL = url
            if url.startAccessingSecurityScopedResource() {
                accessedProjectURL = url
            }
            playback.clear()
            return true
        } catch {
            present(error, fallback: "The project could not be created.")
            return false
        }
    }

    private func openProject(at url: URL) async {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        do {
            let loadedProject = try await projectStore.load(from: url)
            releaseScopedAccess()
            if didStartAccess {
                accessedProjectURL = url
            }
            project = loadedProject
            projectURL = url
            playback.clear()
            try await restoreSourceVideoIfPresent()
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
            project.modifiedAt = Date()
            self.project = project
            playback.load(url: playbackSource.url, duration: metadata.duration)
            save()
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            present(error, fallback: "The selected video could not be opened.")
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

enum SourceVideoError: LocalizedError {
    case fileMissing

    var errorDescription: String? {
        "The original movie file has moved or is no longer accessible."
    }
}
