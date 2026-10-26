import Combine

/// A single coherent presentation sample, not a second capture clock.
struct CapturePresentationSample: Equatable {
    var seconds: Double = 0
    var peak: Float = 0
}

/// MainActor-only presentation storage. No timer, task, capture, or inference ownership.
/// The coordinator validates session identity and phase before accepting worker progress.
@MainActor
final class CapturePresentationState: ObservableObject {
    @Published private(set) var sample = CapturePresentationSample()

    func accept(seconds: Double, peak: Float) {
        replace(with: CapturePresentationSample(seconds: seconds, peak: peak))
    }

    func reset() { replace(with: CapturePresentationSample()) }

    func clearLevel() {
        replace(with: CapturePresentationSample(seconds: sample.seconds, peak: 0))
    }

    private func replace(with next: CapturePresentationSample) {
        guard sample != next else { return }
        sample = next
    }
}
