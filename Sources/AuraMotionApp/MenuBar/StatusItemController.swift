import AppKit
import SwiftUI
import AuraMotionCore

@MainActor
public final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hudWindow: FloatingHUDWindow?
    private var diagnosticsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var calibrationWindow: NSWindow?
    private var movementCalibrationWindow: NSWindow?

    public init(hudWindow: FloatingHUDWindow) {
        self.hudWindow = hudWindow
        super.init()
        setupMenu()
    }

    private func setupMenu() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hand.point.up.fill", accessibilityDescription: "AuraMotion Pro")
        }

        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "AuraMotion Pro", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(title: "Pause Gesture Control", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let hudItem = NSMenuItem(title: "Toggle Floating HUD", action: #selector(toggleHUD), keyEquivalent: "h")
        hudItem.target = self
        menu.addItem(hudItem)

        menu.addItem(NSMenuItem.separator())

        let diagItem = NSMenuItem(title: "Diagnostics & Telemetry...", action: #selector(openDiagnostics), keyEquivalent: "d")
        diagItem.target = self
        menu.addItem(diagItem)

        let calItem = NSMenuItem(title: "Calibration...", action: #selector(openCalibration), keyEquivalent: "c")
        calItem.target = self
        menu.addItem(calItem)
        let movementItem = NSMenuItem(title: "Movement Calibration...", action: #selector(openMovementCalibration), keyEquivalent: "")
        movementItem.target = self
        menu.addItem(movementItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit AuraMotion", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func togglePause() {
        AppEnvironment.shared.togglePause()
    }

    @objc private func toggleHUD() {
        var settings = AppEnvironment.shared.currentSettings
        settings.showHUD.toggle()
        AppEnvironment.shared.updateSettings(settings)
    }

    @objc private func openDiagnostics() {
        if diagnosticsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 420, height: 640),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "AuraMotion Diagnostics"
            win.contentView = NSHostingView(rootView: DiagnosticsView())
            diagnosticsWindow = win
        }
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.isReleasedWhenClosed = false
            win.title = "AuraMotion Settings"
            win.collectionBehavior.insert(.moveToActiveSpace)
            win.contentView = NSHostingView(rootView: SettingsView())
            win.center()
            settingsWindow = win
        }
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openCalibration() {
        movementCalibrationWindow?.close()
        if calibrationWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 420, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "AuraMotion Calibration"
            win.contentView = NSHostingView(rootView: CalibrationView())
            calibrationWindow = win
        }
        calibrationWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openMovementCalibration() {
        calibrationWindow?.close()
        if movementCalibrationWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 440, height: 390),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AuraMotion Movement Calibration"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MovementCalibrationView())
            movementCalibrationWindow = window
        }
        movementCalibrationWindow?.makeKeyAndOrderFront(nil)
    }
}
