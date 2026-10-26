import Foundation

/// One process-owned export admission across main window and persistent panel.
/// Reserve/commit/close run synchronously on MainActor: Quit can close admission
/// before it starts draining and cannot miss a newly admitted detached writer.
@MainActor
final class LocalStatisticsExportGate {
    static let shared = LocalStatisticsExportGate()

    private enum Active {
        case choosing(UUID)
        case writing(UUID, Task<Void, Error>)
        var id: UUID {
            switch self {
            case .choosing(let id), .writing(let id, _): return id
            }
        }
    }

    private var active: Active?
    private var closing = false
    private var quitSavePending = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var isClosingForQuit: Bool { closing }
    var isActive: Bool { active != nil }

    func reserve() -> UUID? {
        guard !closing, !quitSavePending, active == nil else { return nil }
        let id = UUID()
        active = .choosing(id)
        return id
    }

    func permitsWriting(_ id: UUID) -> Bool {
        guard !closing, !quitSavePending, let active, case .choosing(let activeID) = active else { return false }
        return activeID == id
    }

    func startWriter(_ id: UUID, write: @escaping @Sendable () throws -> Void) -> Task<Void, Error>? {
        guard permitsWriting(id) else { return nil }
        let work = Task.detached(priority: .utility) { try write() }
        active = .writing(id, work)
        return work
    }

    func finish(_ id: UUID) {
        guard active?.id == id else { return }
        active = nil
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// An accepted Quit → Save decision reserves the next document action.
    /// A modal export chooser may return later, but can no longer admit a write.
    /// An existing writer is allowed to finish before transcript Save begins.
    func beginQuitSave() -> Bool {
        quitSavePending = true
        return active != nil
    }

    func waitUntilIdle() async {
        if active == nil { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func finishQuitSave() {
        quitSavePending = false
    }

    /// A pending chooser has no admitted filesystem work. A late URL cannot
    /// commit after `closing` becomes true. An admitted writer is returned to
    /// the coordinator to await before `terminationReady` and `terminate`.
    func closeForQuit() -> Task<Void, Error>? {
        closing = true
        guard let active, case .writing(_, let work) = active else { return nil }
        return work
    }
}
