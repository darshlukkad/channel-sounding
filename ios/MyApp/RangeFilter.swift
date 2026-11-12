import Foundation

/// Turns noisy Channel Sounding distances into a stable estimate.
///
/// Each reading goes through three stages:
/// 1. **Median** of the last few readings removes single-reading spikes.
/// 2. **Jump gate**: if the median jumps far from the current estimate while
///    RSSI stays flat, the jump is most likely a multipath error rather than
///    real movement, so it's held back until several readings in a row agree.
///    A clear RSSI change lets a jump through immediately.
/// 3. **1D Kalman filter** smooths the remaining jitter while still following
///    real movement.
struct RangeFilter {
    struct Output {
        /// The filtered distance, in meters.
        let estimate: Double
        /// The median of the recent readings, in meters.
        let median: Double
        /// Whether this reading was held back by the jump gate.
        let rejected: Bool
    }

    /// Number of readings in the median window.
    var medianWindow = 7
    /// How quickly the true distance is expected to change, in m²/s.
    var processNoise = 0.05
    /// Expected variance of a median reading, in m² (σ ≈ 20 cm).
    var measurementNoise = 0.04
    /// A median further than this from the estimate counts as a jump, in meters.
    var jumpThreshold = 1.0
    /// An RSSI change smaller than this means the signal "looks flat", in dB.
    var rssiFlatThreshold = 3.0
    /// Consecutive agreeing readings needed to accept a jump without RSSI support.
    var confirmCount = 3
    /// How far back to look for the RSSI a jump is compared against, in seconds.
    /// The median lags a real move by a few readings, so the reference must
    /// predate the move or the RSSI change is already "used up".
    var rssiLookback: TimeInterval = 1.0

    private var window: [Double] = []
    private var estimate: Double?
    private var variance = 0.0
    private var lastTime: Date?
    private var pendingJumps: [Double] = []
    private var rssiHistory: [(time: Date, rssi: Double)] = []

    mutating func reset() {
        window.removeAll()
        estimate = nil
        variance = 0
        lastTime = nil
        pendingJumps.removeAll()
        rssiHistory.removeAll()
    }

    /// Feeds one distance reading and returns the updated estimate.
    /// - Parameters:
    ///   - meters: The raw (calibrated) distance reading.
    ///   - rssi: The current smoothed RSSI in dBm, if known.
    ///   - time: When the reading arrived.
    mutating func update(_ meters: Double, rssi: Double?, at time: Date = .now) -> Output {
        window.append(meters)
        if window.count > medianWindow {
            window.removeFirst(window.count - medianWindow)
        }
        let median = Self.median(of: window)
        let rssiFlat = rssiLooksFlat(rssi, at: time)
        recordRSSI(rssi, at: time)

        // The first reading initializes the filter.
        guard let current = estimate, let last = lastTime else {
            accept(median, at: time)
            return Output(estimate: median, median: median, rejected: false)
        }

        // Predict: uncertainty grows with the time since the last reading.
        let dt = max(time.timeIntervalSince(last), 0.001)
        variance += processNoise * dt
        lastTime = time

        if abs(median - current) > jumpThreshold && rssiFlat {
            pendingJumps.append(median)
            guard pendingJumps.count >= confirmCount else {
                return Output(estimate: current, median: median, rejected: true)
            }
            // Several readings in a row point to the same new distance, so
            // treat it as real movement and restart from there.
            let spread = (pendingJumps.max() ?? 0) - (pendingJumps.min() ?? 0)
            guard spread <= jumpThreshold else {
                pendingJumps.removeFirst()
                return Output(estimate: current, median: median, rejected: true)
            }
            let jumpTarget = Self.median(of: pendingJumps)
            window = pendingJumps
            accept(jumpTarget, at: time)
            return Output(estimate: jumpTarget, median: median, rejected: false)
        }

        if abs(median - current) > jumpThreshold {
            // A jump backed by a clear RSSI change is real movement: restart
            // there instead of slowly gliding across the gap.
            accept(median, at: time)
            return Output(estimate: median, median: median, rejected: false)
        }
        pendingJumps.removeAll()

        // Update: blend the prediction with the new median.
        let gain = variance / (variance + measurementNoise)
        let updated = current + gain * (median - current)
        variance *= 1 - gain
        estimate = updated
        return Output(estimate: updated, median: median, rejected: false)
    }

    /// Restarts the estimate at `value` with the measurement's uncertainty.
    private mutating func accept(_ value: Double, at time: Date) {
        estimate = value
        variance = measurementNoise
        lastTime = time
        pendingJumps.removeAll()
    }

    private mutating func recordRSSI(_ rssi: Double?, at time: Date) {
        guard let rssi else { return }
        rssiHistory.append((time, rssi))
        // Keep a little more than the lookback so a reference is always available.
        rssiHistory.removeAll { time.timeIntervalSince($0.time) > rssiLookback * 3 }
    }

    /// True when RSSI hasn't changed enough since ~`rssiLookback` ago to back up
    /// a distance jump. Without RSSI data the gate falls back to requiring confirmation.
    private func rssiLooksFlat(_ rssi: Double?, at time: Date) -> Bool {
        guard let rssi else { return true }
        let reference = rssiHistory.last { time.timeIntervalSince($0.time) >= rssiLookback } ?? rssiHistory.first
        guard let reference else { return true }
        return abs(rssi - reference.rssi) < rssiFlatThreshold
    }

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Standard deviation of `values`, used to show how much readings scatter.
    static func standardDeviation(of values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }
}
