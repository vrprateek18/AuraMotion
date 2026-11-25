import AppKit
import SwiftUI
import AuraMotionCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, AppEnvironmentObserver {
    private var statusItemController: StatusItemController?
    private var hudWindow: FloatingHUDWindow?
    private let commandMenuWindow = CommandMenuWindowController()
    private let clickFeedback = ClickFeedbackWindowController()
    private var displayLink: CADisplayLink?
    private var lastFeedbackID: UInt64 = 0

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Create Floating HUD Panel
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let hudRect = NSRect(x: screenRect.maxX - 240, y: screenRect.maxY - 220, width: 220, height: 200)
        let hud = FloatingHUDWindow(contentRect: hudRect)
        let controls = StatusItemController(hudWindow: hud)
        self.statusItemController = controls
        hud.contentView = NSHostingView(rootView: HUDView(openSettings: controls.openSettings))
        if AppEnvironment.shared.currentSettings.showHUD { hud.orderFrontRegardless() }
        self.hudWindow = hud

        // 3. Register environment observer
        let env = AppEnvironment.shared
        env.observer = self

        // 4. Register Sleep/Wake notifications for honest safety guarantees
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // 5. Start environment
        if let screen = NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(presentFrame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        env.start()
        if env.permissionsManager.gate.cachedSnapshot.statusLabel != nil {
            controls.openSettings()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.openSettings()
        return false
    }

    @objc private func presentFrame(_ link: CADisplayLink) {
        AppEnvironment.shared.displayTick(at: link.targetTimestamp)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        displayLink?.invalidate()
        AppEnvironment.shared.stop()
    }

    @objc private func handleWillSleep() {
        AppEnvironment.shared.outputCoordinator.emergencyRelease()
        let env = AppEnvironment.shared
        env.interactionQueue.async { env.stateMachine.transition(to: .trackingLost) }
    }

    @objc private func handleDidWake() {
        let env = AppEnvironment.shared
        env.interactionQueue.async { env.stateMachine.transition(to: .idle) }
    }

    // MARK: - AppEnvironmentObserver

    nonisolated public func environmentDidUpdateHUDSnapshot(_ snapshot: HUDSnapshot) {
        NotificationCenter.default.post(name: NSNotification.Name("HUDSnapshotUpdated"), object: snapshot)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.commandMenuWindow.update(snapshot.commandMenu)
            if snapshot.showHUD {
                if self.hudWindow?.isVisible == false { self.hudWindow?.orderFrontRegardless() }
            } else { self.hudWindow?.orderOut(nil) }
            if snapshot.clickFeedbackID != self.lastFeedbackID {
                self.lastFeedbackID = snapshot.clickFeedbackID
                if let point = snapshot.clickFeedbackLocation { self.clickFeedback.show(at: point) }
            }
            if snapshot.clickFeedbackLocation == nil { self.clickFeedback.hide() }
        }
    }
}
