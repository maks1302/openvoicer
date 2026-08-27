import Foundation
import Observation

struct RecentProject: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var sourceVideoName: String?
    var lastOpenedAt: Date
    var bookmarkData: Data?
    var lastKnownPath: String
}

@MainActor
@Observable
final class RecentProjectsStore {
    private(set) var projects: [RecentProject] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "recentProjects.v1"
    @ObservationIgnored private let maximumProjectCount = 10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RecentProject].self, from: data) else { return }
        projects = Array(decoded.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(maximumProjectCount))
    }

    func recordOpened(project: DubProject, at url: URL) {
        let recent = RecentProject(
            id: project.id,
            displayName: project.name,
            sourceVideoName: project.sourceVideo?.displayName,
            lastOpenedAt: Date(),
            bookmarkData: try? SecurityScopedBookmarks.makeBookmark(for: url),
            lastKnownPath: url.path
        )

        projects.removeAll { $0.id == project.id || $0.lastKnownPath == url.path }
        projects.insert(recent, at: 0)
        projects = Array(projects.prefix(maximumProjectCount))
        persist()
    }

    func updateMetadata(for project: DubProject, at url: URL) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].displayName = project.name
        projects[index].sourceVideoName = project.sourceVideo?.displayName
        projects[index].lastKnownPath = url.path
        if projects[index].bookmarkData == nil {
            projects[index].bookmarkData = try? SecurityScopedBookmarks.makeBookmark(for: url)
        }
        persist()
    }

    func remove(_ recentProject: RecentProject) {
        projects.removeAll { $0.id == recentProject.id }
        persist()
    }

    func removeAll() {
        projects = []
        persist()
    }

    func resolveURL(for recentProject: RecentProject) -> URL {
        if let bookmarkData = recentProject.bookmarkData,
           let resolved = try? SecurityScopedBookmarks.resolve(bookmarkData) {
            return resolved.url
        }
        return URL(fileURLWithPath: recentProject.lastKnownPath)
    }

    func isAvailable(_ recentProject: RecentProject) -> Bool {
        FileManager.default.fileExists(atPath: resolveURL(for: recentProject).path)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
