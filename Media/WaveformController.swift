import Foundation
import Observation

@MainActor
@Observable
final class WaveformController {
    private(set) var originalSamples: [Float] = []
    private(set) var takeSamples: [Float] = []
    private(set) var isLoading = false

    @ObservationIgnored private let service = WaveformService()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func load(
        originalURL: URL?,
        segment: DubSegment?,
        takeURL: URL?,
        take: RecordingTake?,
        cacheRoot: URL?
    ) {
        loadTask?.cancel()
        originalSamples = []
        takeSamples = []

        guard let segment, let cacheRoot else {
            isLoading = false
            return
        }
        isLoading = true

        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { isLoading = false }
            do {
                async let original: [Float] = loadOriginal(
                    url: originalURL,
                    segment: segment,
                    cacheRoot: cacheRoot
                )
                async let recorded: [Float] = loadTake(
                    url: takeURL,
                    take: take,
                    cacheRoot: cacheRoot
                )
                let (originalResult, takeResult) = try await (original, recorded)
                try Task.checkCancellation()
                originalSamples = originalResult
                takeSamples = takeResult
            } catch is CancellationError {
                return
            } catch {
                originalSamples = []
                takeSamples = []
            }
        }
    }

    private func loadOriginal(url: URL?, segment: DubSegment, cacheRoot: URL) async throws -> [Float] {
        guard let url else { return [] }
        return try await service.samples(
            from: url,
            timeRange: segment.startTime..<segment.endTime,
            sampleCount: 240,
            cacheURL: cacheRoot.appending(path: "original/\(segment.id.uuidString)-240.json")
        )
    }

    private func loadTake(url: URL?, take: RecordingTake?, cacheRoot: URL) async throws -> [Float] {
        guard let url, let take else { return [] }
        return try await service.samples(
            from: url,
            timeRange: 0..<max(take.duration, 0.01),
            sampleCount: 240,
            cacheURL: cacheRoot.appending(path: "takes/\(take.id.uuidString)-240.json")
        )
    }
}
