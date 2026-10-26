import Combine

/// The scene graph needs only menu-item installation state, not every dictation
/// publication. AppCoordinator remains the single command/preference owner.
@MainActor
final class ScenePresentationState: ObservableObject {
    @Published private(set) var menuBarEnabled: Bool
    init(menuBarEnabled: Bool) { self.menuBarEnabled = menuBarEnabled }
    func setMenuBarEnabled(_ enabled: Bool) {
        guard menuBarEnabled != enabled else { return }
        menuBarEnabled = enabled
    }
}
