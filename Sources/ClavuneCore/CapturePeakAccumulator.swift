/// Preserves the largest worker-observed peak until the next coalesced meter update.
/// One capture session owns this value on its control queue; no callback work is added.
struct CapturePeakAccumulator: Sendable {
    private var peak: Float = 0

    mutating func observe(_ value: Float) {
        guard value.isFinite else { return }
        peak = max(peak, min(abs(value), 1))
    }

    mutating func take() -> Float {
        let result = peak
        peak = 0
        return result
    }
}
