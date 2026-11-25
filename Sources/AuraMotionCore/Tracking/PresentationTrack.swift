import CoreGraphics
import Foundation

/// Reconstructs display-only positions between measured frames. A late or
/// discontinuous observation starts a new track without carrying velocity over.
struct PresentationTrack {
    let maxLead: CGFloat
    private(set) var point: CGPoint?
    private var sampleTime = 0.0
    private var arrival = 0.0
    private var velocity = CGVector.zero
    private var correction = CGVector.zero

    init(maxLead: CGFloat) { self.maxLead = maxLead }

    mutating func observe(_ next: CGPoint, timestamp: Double, received: Double) {
        let dt = timestamp - sampleTime
        defer { point = next; sampleTime = timestamp; arrival = received }
        let previousDisplay = position(at: received)
        guard let point, dt >= 1.0 / 160, dt <= 0.08, received >= arrival,
              next != point else {
            velocity = .zero
            correction = .zero
            return
        }
        velocity = CGVector(dx: (next.x - point.x) / dt, dy: (next.y - point.y) / dt)
        if let p = previousDisplay, hypot(p.x - next.x, p.y - next.y) <= maxLead {
            correction = CGVector(dx: p.x - next.x, dy: p.y - next.y)
        } else { correction = .zero }
    }

    func position(at time: Double) -> CGPoint? {
        let age = max(0, time - arrival)
        guard let point, age < 0.075 else { return nil }
        let lead = min(age, 1.0 / 40, maxLead / max(0.000001, hypot(velocity.dx, velocity.dy)))
        let remaining = max(0, 1 - age * 60)
        return CGPoint(x: point.x + velocity.dx * lead + correction.dx * remaining,
                       y: point.y + velocity.dy * lead + correction.dy * remaining)
    }
}

struct HandPreview {
    private var tracks: [HandJointName: PresentationTrack] = [:]
    private var identity: Int?

    mutating func observe(_ sample: HandSample?, received: Double) {
        if sample?.trackingID != identity { tracks.removeAll(); identity = sample?.trackingID }
        guard let sample else { return }
        tracks = tracks.filter { sample.joints[$0.key] != nil }
        for (name, joint) in sample.joints {
            guard joint.confidence >= 0.25 else { tracks[name] = nil; continue }
            tracks[name, default: PresentationTrack(maxLead: 0.012)]
                .observe(joint.position, timestamp: sample.hostTimestamp, received: received)
        }
    }

    func positions(at time: Double) -> [HandJointName: CGPoint] {
        tracks.compactMapValues { $0.position(at: time) }
    }
}
