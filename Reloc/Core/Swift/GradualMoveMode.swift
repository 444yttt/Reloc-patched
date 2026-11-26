import Foundation

/// How injected coordinates travel from the phone's current fix to the target pin.
public enum GradualMoveMode: String, CaseIterable, Identifiable, Sendable {
    case immediate
    case highway120
    case shinkansen300
    case test600

    public var id: String { rawValue }

    /// Cruise speed in km/h. `0` means jump straight to the target (warp).
    public var speedKmh: Double {
        switch self {
        case .immediate: return 0
        case .highway120: return 120
        case .shinkansen300: return 300
        case .test600: return 600
        }
    }

    public var title: String {
        switch self {
        case .immediate: return "即座（ワープ）"
        case .highway120: return "120 km/h（高速道路）"
        case .shinkansen300: return "300 km/h（新幹線）"
        case .test600: return "600 km/h（高速テスト）"
        }
    }
}

public struct GradualMoveStatus: Equatable, Sendable {
    public var isMoving: Bool
    public var remainingMeters: Double
    public var speedKmh: Double
}
