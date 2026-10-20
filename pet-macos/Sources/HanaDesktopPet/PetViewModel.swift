import Foundation
import PetCore

final class PetViewModel {
    private(set) var state: PetViewState
    private(set) var listenerStatus = "starting"
    private(set) var positionLocked: Bool
    private(set) var showNotices: Bool
    var onChange: (() -> Void)?

    let store: PetStateStore

    init(store: PetStateStore) {
        self.store = store
        self.state = store.viewState()
        self.positionLocked = UserDefaults.standard.bool(forKey: PetPreferences.positionLockKey)
        self.showNotices = PetPreferences.loadShowNotices()
    }

    func refreshFromServer() {
        let next = store.viewState()
        if next.selection != state.selection { PetPreferences.save(next.selection) }
        state = next
        onChange?()
    }

    func refresh() {
        state = store.viewState()
        onChange?()
    }

    func setListenerStatus(_ value: String) {
        listenerStatus = value
        state = store.viewState()
        onChange?()
    }

    func selectRole(_ id: String) {
        guard let selection = store.selectLocally(id) else { return }
        PetPreferences.save(selection)
        state = store.viewState()
        onChange?()
    }

    func setPositionLocked(_ locked: Bool) {
        guard positionLocked != locked else { return }
        positionLocked = locked
        UserDefaults.standard.set(locked, forKey: PetPreferences.positionLockKey)
        onChange?()
    }

    func setShowNotices(_ enabled: Bool) {
        guard showNotices != enabled else { return }
        showNotices = enabled
        PetPreferences.saveShowNotices(enabled)
        onChange?()
    }
}

enum PetPreferences {
    static let positionLockKey = "hana-desktop-pet.position-locked"
    static let showNoticesKey = "hana-desktop-pet.show-notices"
    private static let idKey = "hana-desktop-pet.selected-character"
    private static let revisionKey = "hana-desktop-pet.selection-revision"
    private static let updatedAtKey = "hana-desktop-pet.selection-updated-at"

    static func loadSelection() -> PetSelection {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: idKey) ?? "claude"
        guard PetRole.builtIns.contains(where: { $0.id == id }) else { return PetSelection() }
        let revisionNumber = defaults.object(forKey: revisionKey) as? NSNumber
        let updatedAtNumber = defaults.object(forKey: updatedAtKey) as? NSNumber
        return PetSelection(
            characterId: id,
            revision: max(0, revisionNumber?.int64Value ?? 0),
            updatedAt: max(0, updatedAtNumber?.int64Value ?? 0)
        )
    }

    static func save(_ selection: PetSelection) {
        let defaults = UserDefaults.standard
        defaults.set(selection.characterId, forKey: idKey)
        defaults.set(selection.revision, forKey: revisionKey)
        defaults.set(selection.updatedAt, forKey: updatedAtKey)
    }

    /// Bubbles are on by default; only an explicit stored `false` turns them off.
    static func loadShowNotices() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showNoticesKey) != nil else { return true }
        return defaults.bool(forKey: showNoticesKey)
    }

    static func saveShowNotices(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: showNoticesKey)
    }
}
