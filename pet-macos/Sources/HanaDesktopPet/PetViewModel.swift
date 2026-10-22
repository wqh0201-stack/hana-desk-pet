import Foundation
import PetCore

final class PetViewModel {
    private(set) var state: PetViewState
    private(set) var listenerStatus = "starting"
    private(set) var positionLocked: Bool
    private(set) var showNotices: Bool
    private(set) var basinOverrides: [String: PetBasinConfig]
    private var basinPreview: [String: PetBasinConfig] = [:]
    var onChange: (() -> Void)?

    let store: PetStateStore

    init(store: PetStateStore) {
        self.store = store
        self.state = store.viewState()
        self.positionLocked = UserDefaults.standard.bool(forKey: PetPreferences.positionLockKey)
        self.showNotices = PetPreferences.loadShowNotices()
        self.basinOverrides = PetPreferences.loadBasinConfigOverrides()
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

    /// Resolved geometry for a role: live debug preview, then the saved override, then the
    /// built-in per-character table.
    func basinConfig(for roleId: String) -> PetBasinConfig {
        if let preview = basinPreview[roleId] { return preview }
        if let override = basinOverrides[roleId] { return override }
        return PetBasinStack.config(for: roleId)
    }

    /// Live edit from the debug panel. Not persisted until the user presses save.
    func setBasinPreview(roleId: String, config: PetBasinConfig) {
        let clamped = config.clamped()
        guard basinPreview[roleId] != clamped else { return }
        basinPreview[roleId] = clamped
        onChange?()
    }

    func setBasinConfig(_ config: PetBasinConfig, for roleId: String) {
        let clamped = config.clamped()
        basinOverrides[roleId] = clamped
        basinPreview.removeValue(forKey: roleId)
        PetPreferences.saveBasinConfigOverride(clamped, for: roleId)
        onChange?()
    }

    func resetBasinConfig(for roleId: String) {
        let hadOverride = basinOverrides.removeValue(forKey: roleId) != nil
        let hadPreview = basinPreview.removeValue(forKey: roleId) != nil
        guard hadOverride || hadPreview else { return }
        PetPreferences.clearBasinConfigOverride(for: roleId)
        onChange?()
    }
}

enum PetPreferences {
    static let positionLockKey = "hana-desktop-pet.position-locked"
    static let showNoticesKey = "hana-desktop-pet.show-notices"
    static let basinConfigKey = "hana-desktop-pet.basin-configs"
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

    /// Per-character basin overrides, saved by the debug panel. Only the three geometry
    /// numbers are stored; nothing about the session or the artwork is written.
    static func loadBasinConfigOverrides() -> [String: PetBasinConfig] {
        guard let raw = UserDefaults.standard.dictionary(forKey: basinConfigKey) else { return [:] }
        var result: [String: PetBasinConfig] = [:]
        for (roleId, value) in raw {
            guard let entry = value as? [String: Any],
                  let width = (entry["width"] as? NSNumber)?.doubleValue,
                  let xOffset = (entry["xOffset"] as? NSNumber)?.doubleValue,
                  let yOffset = (entry["yOffset"] as? NSNumber)?.doubleValue else { continue }
            result[roleId] = PetBasinConfig(width: width, xOffset: xOffset, yOffset: yOffset).clamped()
        }
        return result
    }

    static func saveBasinConfigOverride(_ config: PetBasinConfig, for roleId: String) {
        let defaults = UserDefaults.standard
        var raw = defaults.dictionary(forKey: basinConfigKey) ?? [:]
        raw[roleId] = ["width": config.width, "xOffset": config.xOffset, "yOffset": config.yOffset]
        defaults.set(raw, forKey: basinConfigKey)
    }

    static func clearBasinConfigOverride(for roleId: String) {
        let defaults = UserDefaults.standard
        var raw = defaults.dictionary(forKey: basinConfigKey) ?? [:]
        guard raw.removeValue(forKey: roleId) != nil else { return }
        defaults.set(raw, forKey: basinConfigKey)
    }
}
