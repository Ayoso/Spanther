import Foundation

/// Accuracy on the check screen.
public struct AccuracyReport: Codable, Sendable, Equatable {
    /// Mean distance between each target and the mean of its predictions (screen pt).
    public var meanErrorPt: Double
    /// Mean per-target RMS spread of predictions around their own mean (screen pt).
    public var jitterPt: Double
    public var meanErrorCm: Double
    public var jitterCm: Double
    public var meanErrorDeg: Double
    public var jitterDeg: Double
    public var targets: Int
}

public enum Metrics {
    /// `ptPerCm`: screen points per centimetre on this device (≈60 on current iPhones).
    /// `viewingDistanceCm`: measured face distance during the check (ARKit gives it).
    public static func report(samples: [(target: Vec2, predictions: [Vec2])], ptPerCm: Double, viewingDistanceCm: Double) -> AccuracyReport {
        let used = samples.filter { !$0.predictions.isEmpty }
        guard !used.isEmpty else {
            return AccuracyReport(meanErrorPt: .nan, jitterPt: .nan, meanErrorCm: .nan, jitterCm: .nan, meanErrorDeg: .nan, jitterDeg: .nan, targets: 0)
        }
        var err = 0.0, jit = 0.0
        for s in used {
            let n = Double(s.predictions.count)
            let mean = s.predictions.reduce(Vec2.zero, +) * (1 / n)
            err += mean.distance(to: s.target)
            jit += (s.predictions.reduce(0) { $0 + pow($1.distance(to: mean), 2) } / n).squareRoot()
        }
        err /= Double(used.count); jit /= Double(used.count)
        let toCm = { (pt: Double) in pt / ptPerCm }
        let toDeg = { (cm: Double) in atan(cm / max(1, viewingDistanceCm)) * 180 / .pi }
        return AccuracyReport(meanErrorPt: err, jitterPt: jit, meanErrorCm: toCm(err), jitterCm: toCm(jit),
                              meanErrorDeg: toDeg(toCm(err)), jitterDeg: toDeg(toCm(jit)), targets: used.count)
    }
}
