import AppKit
import PetBridge
import PetCore

final class FloatingPetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetAppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPetPanel?
    private var server: LocalHTTPServer?
    private var model: PetViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = PetStateStore(selection: PetPreferences.loadSelection())
        let viewModel = PetViewModel(store: store)
        model = viewModel

        let artworkCatalog = Bundle.main.resourceURL.flatMap { resourceURL in
            try? PetArtworkCatalog(directoryURL: resourceURL.appendingPathComponent("CrossPet", isDirectory: true))
        }
        let characterLayout = PetCharacterLayout(maximumAspectRatio: artworkCatalog?.maximumAspectRatio ?? 0.75)
        let contentSize = NSSize(width: characterLayout.windowSize.width, height: characterLayout.windowSize.height)
        let panel = FloatingPetPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Hana Desk Pet"
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("HanaDesktopPet.Window")
        panel.contentView = PetWindowView(model: viewModel, artworkCatalog: artworkCatalog, layout: characterLayout)
        if panel.setFrameUsingName("HanaDesktopPet.Window") {
            panel.setContentSize(contentSize)
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        self.panel = panel

        configureApplicationMenu()
        do {
            let server = try LocalHTTPServer(store: store)
            server.onStateChange = { [weak viewModel] in
                viewModel?.refreshFromServer()
            }
            server.onListenerState = { [weak viewModel] value in
                DispatchQueue.main.async { viewModel?.setListenerStatus(value) }
            }
            server.start()
            self.server = server
        } catch {
            viewModel.setListenerStatus("error")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "退出 Hana 桌宠",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }
}

@main
struct HanaDesktopPetMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = PetAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
