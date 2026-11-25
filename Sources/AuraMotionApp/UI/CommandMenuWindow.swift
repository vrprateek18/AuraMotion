import AppKit
import SwiftUI
import AuraMotionCore

@MainActor
final class CommandMenuWindowController {
    private let panel: NSPanel
    private var hostingView: NSHostingView<CommandMenuView>?
    private var displayed: CommandMenuSnapshot?
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func update(_ menu: CommandMenuSnapshot?) {
        guard menu != displayed else { return }
        let isNewMenu = displayed?.id != menu?.id
        displayed = menu
        guard let menu else { panel.orderOut(nil); return }
        if isNewMenu {
            let height = CGDisplayBounds(CGMainDisplayID()).height
            let point = CGPoint(x: menu.target.x, y: height - menu.target.y)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2))
            }
        }
        let view = CommandMenuView(menu: menu) { [weak self] localFrames in
            guard let self, self.displayed?.id == menu.id else { return }
            let topLeft = CGPoint(x: self.panel.frame.minX, y: CGDisplayBounds(CGMainDisplayID()).height - self.panel.frame.maxY)
            let globalFrames = localFrames.mapValues { $0.offsetBy(dx: topLeft.x, dy: topLeft.y) }
            let env = AppEnvironment.shared
            env.interactionQueue.async { env.stateMachine.commandMenu.setTileFrames(globalFrames, for: menu.id) }
        }
        if let hostingView {
            hostingView.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            hostingView = host
            panel.contentView = host
        }
        if isNewMenu { panel.orderFrontRegardless() }
    }
}

private struct CommandTileFrames: PreferenceKey {
    static let defaultValue: [GestureCommand: CGRect] = [:]
    static func reduce(value: inout [GestureCommand: CGRect], nextValue: () -> [GestureCommand: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct CommandMenuView: View {
    let menu: CommandMenuSnapshot
    let onLayout: ([GestureCommand: CGRect]) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Hand Commands", systemImage: "hand.draw.fill").font(.headline)
            Text("Aim with your cursor, then pinch to choose.")
                .font(.system(size: 20, weight: .semibold))
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(GestureCommand.allCases, id: \.self) { command in
                    VStack(spacing: 8) {
                        Image(systemName: command.symbol).font(.system(size: 23))
                        Text(command.title).font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity).frame(height: 72)
                    .foregroundStyle(menu.selected == command ? Color.white : Color.primary)
                    .background(menu.selected == command ? Color.blue : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: CommandTileFrames.self,
                            value: [command: geo.frame(in: .named("palette"))])
                    })
                }
            }
            Text("Lower your hand to dismiss · Closes after 12 seconds")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 560, height: 430)
        .coordinateSpace(name: "palette")
        .onPreferenceChange(CommandTileFrames.self, perform: onLayout)
        .id(menu.id)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.15)))
    }
}
