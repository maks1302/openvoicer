import Foundation
import Observation

@MainActor
@Observable
final class ExportController {
    enum State: Equatable {
        case idle
        case exporting
        case completed(URL)
        case failed(String)
    }

    var exportType: ExportType = .finishedMovie
    var clipRangeMode: ClipRangeMode = .currentLine
    var reviewLineMode: ReviewLineMode = .accepted
    var selectedLineIDs: Set<UUID> = []
    var customStartTime: TimeInterval = 0
    var customEndTime: TimeInterval = 30
    var contextDuration: TimeInterval = 1.5

    private(set) var state: State = .idle
    private(set) var progress = 0.0
    private(set) var message = "Ready to export"

    @ObservationIgnored private let service: any ExportService
    @ObservationIgnored private var task: Task<Void, Never>?

    init(service: any ExportService = FFmpegExportService()) {
        self.service = service
    }

    var isExporting: Bool { state == .exporting }

    func configure(for range: ClosedRange<TimeInterval>) {
        guard range.upperBound > range.lowerBound else { return }
        if customStartTime < range.lowerBound
            || customEndTime <= customStartTime
            || customEndTime > range.upperBound {
            customStartTime = range.lowerBound
            customEndTime = min(range.upperBound, range.lowerBound + 30)
        }
    }

    func start(job: ExportJob) {
        guard !isExporting else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let didAccessDestination = job.destinationURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessDestination {
                    job.destinationURL.stopAccessingSecurityScopedResource()
                }
                self.task = nil
            }

            state = .exporting
            progress = 0
            message = "Preparing export…"
            do {
                try await service.render(job: job) { [weak self] update in
                    Task { @MainActor in
                        self?.progress = update.fraction
                        self?.message = update.message
                    }
                }
                try Task.checkCancellation()
                progress = 1
                message = "Export complete"
                state = .completed(job.destinationURL)
            } catch is CancellationError {
                progress = 0
                message = "Export cancelled"
                state = .idle
            } catch {
                progress = 0
                message = error.localizedDescription
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        Task { await service.cancel() }
    }

    func resetResult() {
        guard !isExporting else { return }
        state = .idle
        progress = 0
        message = "Ready to export"
    }

    func toggleLine(_ id: UUID) {
        if selectedLineIDs.contains(id) {
            selectedLineIDs.remove(id)
        } else {
            selectedLineIDs.insert(id)
        }
    }
}
