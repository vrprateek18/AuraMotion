import Foundation
import CoreGraphics

public enum GestureCommand: String, CaseIterable, Sendable {
    case rightClick, doubleClick, missionControl, previousApp, nextApp, minimize, fullScreen, snapLeft, snapRight
    public var title: String {
        switch self {
        case .rightClick: return "Right click"
        case .doubleClick: return "Double click"
        case .missionControl: return "All windows"
        case .previousApp: return "Previous app"
        case .nextApp: return "Next app"
        case .minimize: return "Minimize"
        case .fullScreen: return "Full screen"
        case .snapLeft: return "Left half"
        case .snapRight: return "Right half"
        }
    }
    public var symbol: String {
        switch self {
        case .rightClick: return "cursorarrow.click"
        case .doubleClick: return "cursorarrow.click.2"
        case .missionControl: return "rectangle.3.group"
        case .previousApp: return "arrow.left"
        case .nextApp: return "arrow.right"
        case .minimize: return "minus.rectangle"
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .snapLeft: return "rectangle.lefthalf.filled"
        case .snapRight: return "rectangle.righthalf.filled"
        }
    }
}

public struct CommandMenuSnapshot: Sendable, Equatable {
    public let id: UInt64
    public let selected: GestureCommand?
    public let target: CGPoint
}

/// The palette consumes a pinch over a visible tile. Cursor movement belongs to
/// the ordinary pointer pipeline, including while the palette is visible.
public final class GestureCommandMenu: @unchecked Sendable {
    public var holdDuration: TimeInterval = 0.9
    public private(set) var isOpen = false
    public private(set) var contactFinger: HandJointName?
    public private(set) var closingFinger: HandJointName?
    private var holdStart: Double?
    private var palmAnchor: CGPoint?
    private var target: CGPoint = .zero
    private var selected: GestureCommand?
    private var frames: [GestureCommand: CGRect] = [:]
    private var confirmation = ContactConfirmation(duration: 0.08)
    private var lastTime: Double?
    private var openedAt = 0.0
    private var id: UInt64 = 0

    public init() {}
    public var snapshot: CommandMenuSnapshot? {
        isOpen ? CommandMenuSnapshot(id: id, selected: selected, target: target) : nil
    }
    public func cancel() {
        isOpen = false
        resetHold()
        frames.removeAll()
        selected = nil
        contactFinger = nil
        closingFinger = nil
        confirmation.reset()
    }
    public func resetHold() { holdStart = nil; palmAnchor = nil }

    @discardableResult
    public func observePalm(position: CGPoint?, timestamp: Double, target: @autoclosure () -> CGPoint) -> Bool {
        guard let position else { resetHold(); return false }
        if let previous = lastTime, timestamp - previous > 0.15 { resetHold() }
        lastTime = timestamp
        if let anchor = palmAnchor, hypot(position.x - anchor.x, position.y - anchor.y) > 0.035 { resetHold() }
        if holdStart == nil { holdStart = timestamp; palmAnchor = position }
        guard timestamp - (holdStart ?? timestamp) >= holdDuration else { return false }
        isOpen = true
        id &+= 1
        self.target = target()
        openedAt = timestamp
        resetHold()
        return true
    }

    /// Quartz screen coordinates of the tiles actually laid out by SwiftUI.
    public func setTileFrames(_ frames: [GestureCommand: CGRect], for id: UInt64) {
        guard isOpen, self.id == id else { return }
        self.frames = frames
    }

    public func consumeClosingContact(distance: CGFloat?, releaseThreshold: CGFloat) -> Bool {
        guard closingFinger != nil else { return false }
        if let distance, distance >= releaseThreshold { closingFinger = nil }
        return true
    }

    public func navigate(cursor: CGPoint, isPointing: Bool, finger: HandJointName, pinchDistance: CGFloat?,
                         contactThreshold: CGFloat, releaseThreshold: CGFloat, timestamp: Double) -> GestureCommand? {
        guard isOpen else { return nil }
        guard timestamp - openedAt <= 12 else { cancel(); return nil }
        let hovered = frames.first { $0.value.contains(cursor) }?.key
        guard let distance = pinchDistance else {
            selected = nil
            confirmation.reset()
            contactFinger = nil
            return nil
        }
        if distance >= releaseThreshold {
            contactFinger = nil
            confirmation.reset()
            selected = isPointing ? hovered : nil
        } else if distance <= contactThreshold, let selected, hovered == selected {
            if finger != contactFinger { confirmation.reset(); contactFinger = finger }
            if confirmation.update(matches: true, timestamp: timestamp) {
                cancel()
                closingFinger = finger
                return selected
            }
        } else {
            confirmation.reset()
            if hovered != selected { selected = nil }
        }
        return nil
    }
}
