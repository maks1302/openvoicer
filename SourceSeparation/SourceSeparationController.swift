import Foundation
import Observation

@MainActor
@Observable
final class SourceSeparationController {
    enum State: Equatable {
        case checking
        case unavailable
        case ready
        case installing
        case separating
        case failed(String)
    }

    private(set) var state: State = .checking
    private(set) var progress = 0.0
    private(set) var message = "Checking local separation…"
    @ObservationIgnored private let service: any SourceSeparationService
    @ObservationIgnored private var task: Task<Void, Never>?

    init(service: any SourceSeparationService = BanditSourceSeparationService()) {
        self.service = service
        Task { await refreshAvailability() }
    }

    var isBusy: Bool { state == .installing || state == .separating }

    func prepare(
        inputURL: URL,
        outputURL: URL,
        dialogueReduction: Double,
        residualSuppression: Double,
        centerCancellationStrength: Double,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard !isBusy else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if !(await service.isRuntimeReady()) {
                    state = .installing
                    progress = 0
                    try await service.installRuntime { [weak self] update in
                        Task { @MainActor in
                            self?.progress = update.fraction
                            self?.message = update.message
                        }
                    }
                }
                try Task.checkCancellation()
                state = .separating
                progress = 0
                message = "Preparing movie audio…"
                try await service.separate(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    dialogueReduction: dialogueReduction,
                    residualSuppression: residualSuppression,
                    centerCancellationStrength: centerCancellationStrength
                ) { [weak self] update in
                    Task { @MainActor in
                        self?.progress = update.fraction
                        self?.message = update.message
                    }
                }
                state = .ready
                progress = 1
                message = "Clean background is ready"
                completion(.success(()))
            } catch is CancellationError {
                await refreshAvailability()
                completion(.failure(CancellationError()))
            } catch {
                state = .failed(error.localizedDescription)
                message = error.localizedDescription
                completion(.failure(error))
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        Task { await service.cancel() }
    }

    private func refreshAvailability() async {
        state = await service.isRuntimeReady() ? .ready : .unavailable
        progress = 0
        message = state == .ready ? "Local separation is ready" : "Local separation is not installed"
    }
}
