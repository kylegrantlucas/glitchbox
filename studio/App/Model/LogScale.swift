import Foundation

/// Maps slider position 0...1 to a range skewed toward its minimum, spanning
/// five decades, so tiny intensities (0.003 of 0...100) stay reachable.
enum LogScale {
    private static let decades = 5.0
    private static var span: Double { pow(10, decades) - 1 }

    static func value(at position: Double, lo: Double, hi: Double) -> Double {
        lo + (hi - lo) * (pow(10, decades * position) - 1) / span
    }

    static func position(of value: Double, lo: Double, hi: Double) -> Double {
        let t = min(max((value - lo) / (hi - lo), 0), 1)
        return log10(1 + t * span) / decades
    }
}
