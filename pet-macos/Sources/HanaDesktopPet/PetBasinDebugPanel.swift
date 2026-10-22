import AppKit
import PetCore

/// Floating debug panel for one character's basin geometry.
///
/// Three continuous sliders (width, x offset, y offset) edit the pile live; nothing is
/// persisted until the user presses 保存, and 重置 drops the saved override so the built-in
/// `PetBasinStack.characterConfigs` row applies again. The readouts are the numbers to copy
/// into that table once a character looks right.
final class PetBasinDebugController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let roleLabel: NSTextField
    private let widthSlider = NSSlider()
    private let xSlider = NSSlider()
    private let ySlider = NSSlider()
    private let widthValue = NSTextField(labelWithString: "")
    private let xValue = NSTextField(labelWithString: "")
    private let yValue = NSTextField(labelWithString: "")

    private let resolve: (String) -> PetBasinConfig
    private let onPreview: (String, PetBasinConfig) -> Void
    private let onSave: (String, PetBasinConfig) -> Void
    private let onReset: (String) -> Void
    private let onClose: (String) -> Void

    private var roleId: String
    private var config: PetBasinConfig

    init(
        roleId: String,
        config: PetBasinConfig,
        resolve: @escaping (String) -> PetBasinConfig,
        onPreview: @escaping (String, PetBasinConfig) -> Void,
        onSave: @escaping (String, PetBasinConfig) -> Void,
        onReset: @escaping (String) -> Void,
        onClose: @escaping (String) -> Void
    ) {
        self.roleId = roleId
        self.config = config
        self.resolve = resolve
        self.onPreview = onPreview
        self.onSave = onSave
        self.onReset = onReset
        self.onClose = onClose

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 266),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "铁盆调试"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        roleLabel = NSTextField(labelWithString: "")
        roleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        roleLabel.frame = NSRect(x: 20, y: 228, width: 300, height: 18)

        super.init()

        let content = panel.contentView ?? NSView()
        content.addSubview(roleLabel)
        configure(widthSlider, min: PetBasinStack.widthMinimum, max: PetBasinStack.widthMaximum)
        configure(xSlider, min: PetBasinStack.xOffsetMinimum, max: PetBasinStack.xOffsetMaximum)
        configure(ySlider, min: PetBasinStack.yOffsetMinimum, max: PetBasinStack.yOffsetMaximum)
        addRow(title: "宽度", slider: widthSlider, value: widthValue, y: 186)
        addRow(title: "X 偏移", slider: xSlider, value: xValue, y: 130)
        addRow(title: "Y 偏移（立绘顶边向下）", slider: ySlider, value: yValue, y: 74)

        let save = NSButton(title: "保存", target: self, action: #selector(savePressed))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: 20, y: 20, width: 90, height: 28)
        content.addSubview(save)

        let reset = NSButton(title: "重置", target: self, action: #selector(resetPressed))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 120, y: 20, width: 90, height: 28)
        content.addSubview(reset)

        let hint = NSTextField(labelWithString: "拖动即时预览，保存后按角色记住")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 220, y: 24, width: 110, height: 18)
        content.addSubview(hint)

        panel.delegate = self
        apply(config)
    }

    private func configure(_ slider: NSSlider, min: Double, max: Double) {
        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.frame = NSRect(x: 20, y: 0, width: 220, height: 24)
    }

    private func addRow(title: String, slider: NSSlider, value: NSTextField, y: Double) {
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: 250, y: y - 18, width: 70, height: 18)
        slider.frame = NSRect(x: 20, y: y, width: 220, height: 24)
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: y - 18, width: 220, height: 18)
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(slider)
        panel.contentView?.addSubview(value)
    }

    /// Reloads a (possibly different) role, e.g. after the user picked another character.
    func reload(roleId: String, config: PetBasinConfig) {
        self.roleId = roleId
        apply(config)
    }

    private func apply(_ config: PetBasinConfig) {
        let clamped = config.clamped()
        self.config = clamped
        roleLabel.stringValue = "角色：\(roleId)"
        widthSlider.doubleValue = clamped.width
        xSlider.doubleValue = clamped.xOffset
        ySlider.doubleValue = clamped.yOffset
        updateReadouts()
    }

    private func updateReadouts() {
        widthValue.stringValue = String(format: "%.1f pt", config.width)
        xValue.stringValue = String(format: "%.1f pt", config.xOffset)
        yValue.stringValue = String(format: "%.1f pt", config.yOffset)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        config = PetBasinConfig(
            width: widthSlider.doubleValue,
            xOffset: xSlider.doubleValue,
            yOffset: ySlider.doubleValue
        ).clamped()
        // Keep the sliders inside the clamp so the readout never lies.
        widthSlider.doubleValue = config.width
        xSlider.doubleValue = config.xOffset
        ySlider.doubleValue = config.yOffset
        updateReadouts()
        onPreview(roleId, config)
    }

    @objc private func savePressed() {
        onSave(roleId, config)
    }

    @objc private func resetPressed() {
        onReset(roleId)
        apply(resolve(roleId))
    }

    /// Brings the panel next to the pet (above it when there is room) without covering it.
    func present(relativeTo petWindow: NSWindow?) {
        let screen = petWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        if let petFrame = petWindow?.frame {
            origin = NSPoint(x: petFrame.midX - size.width / 2, y: petFrame.maxY + 8)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose(roleId)
    }
}
