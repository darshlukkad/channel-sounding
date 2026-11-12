import SwiftUI
import Charts

struct ContentView: View {
    @State private var manager = ChannelSoundingManager()
    @State private var isConfirmingCalibration = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                StatusRow(state: manager.connectionState)

                DistanceCard(distance: manager.currentRange,
                             rawDistance: manager.rawRange,
                             spread: manager.spread,
                             rssi: manager.rssi,
                             calibrationOffset: manager.calibrationOffset,
                             isRanging: manager.connectionState.isRanging)

                RangeChart(readings: manager.rangeReadings)

                if let error = manager.sessionError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                controls
            }
            .padding()
            .navigationTitle("Channel Sounding")
            .toolbar {
                if manager.hasPairedAccessory {
                    Menu {
                        Button("Calibrate at 1 m", systemImage: "ruler") {
                            isConfirmingCalibration = true
                        }
                        .disabled(manager.currentRange == nil)

                        Button("Reset Calibration", systemImage: "arrow.counterclockwise") {
                            manager.resetCalibration()
                        }
                        .disabled(manager.calibrationOffset == 0)

                        Divider()

                        Button("Forget Accessory", role: .destructive) {
                            manager.forgetAccessory()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Calibrate at 1 m", isPresented: $isConfirmingCalibration,
                                titleVisibility: .visible) {
                Button("Calibrate") {
                    manager.calibrate(atKnownDistance: 1.0)
                }
            } message: {
                Text("Place the board exactly 1 m from the phone with a clear line of sight, and wait until the distance settles.")
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch manager.connectionState {
        case .idle:
            Button {
                manager.showAccessoryPicker()
            } label: {
                Label(manager.hasPairedAccessory ? "Connect" : "Add Accessory",
                      systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!manager.isSessionActivated)

        case .connecting:
            ProgressView("Connecting…")

        case .connected:
            VStack(spacing: 12) {
                Button {
                    manager.startChannelSounding()
                } label: {
                    Label("Start Ranging", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Disconnect", role: .destructive) {
                    manager.disconnect()
                }
            }

        case .ranging:
            Button {
                manager.stopChannelSounding()
            } label: {
                Label("Stop Ranging", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
    }
}

/// Shows the current connection state with an icon.
private struct StatusRow: View {
    let state: ConnectionState

    var body: some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var text: String {
        switch state {
        case .idle: "Not connected"
        case .connecting(let name): "Connecting to \(name)"
        case .connected(let name): "Connected to \(name)"
        case .ranging(let name): "Ranging with \(name)"
        }
    }

    private var icon: String {
        switch state {
        case .idle: "antenna.radiowaves.left.and.right.slash"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .connected: "checkmark.circle"
        case .ranging: "dot.radiowaves.left.and.right"
        }
    }
}

/// Large live distance readout with raw reading, spread, and signal details.
private struct DistanceCard: View {
    let distance: Double?
    let rawDistance: Double?
    let spread: Double?
    let rssi: Double?
    let calibrationOffset: Double
    let isRanging: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(distanceText)
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: distance)
            Text("Distance (filtered)")
                .font(.headline)
                .foregroundStyle(.secondary)

            if !detailText.isEmpty {
                Text(detailText)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            if !signalText.isEmpty {
                Text(signalText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(.fill.tertiary, in: .rect(cornerRadius: 20))
    }

    private var distanceText: String {
        guard let distance else { return isRanging ? "…" : "--" }
        return distance.formatted(.number.precision(.fractionLength(2))) + " m"
    }

    /// "Raw 1.23 m · ±8 cm"
    private var detailText: String {
        var parts: [String] = []
        if let rawDistance {
            parts.append("Raw " + rawDistance.formatted(.number.precision(.fractionLength(2))) + " m")
        }
        if let spread {
            parts.append("±\(Int((spread * 100).rounded())) cm")
        }
        return parts.joined(separator: " · ")
    }

    /// "RSSI −62 dBm · Offset −0.23 m"
    private var signalText: String {
        var parts: [String] = []
        if let rssi {
            parts.append("RSSI \(Int(rssi.rounded())) dBm")
        }
        if calibrationOffset != 0 {
            parts.append("Offset " + calibrationOffset.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always())) + " m")
        }
        return parts.joined(separator: " · ")
    }
}

/// Line chart of recent raw and filtered distance readings.
private struct RangeChart: View {
    let readings: [RangeReading]

    var body: some View {
        Chart(readings) { reading in
            LineMark(
                x: .value("Time", reading.date),
                y: .value("Distance (m)", reading.raw),
                series: .value("Series", "Raw")
            )
            .foregroundStyle(by: .value("Series", "Raw"))
            .lineStyle(StrokeStyle(lineWidth: 1))

            LineMark(
                x: .value("Time", reading.date),
                y: .value("Distance (m)", reading.filtered),
                series: .value("Series", "Filtered")
            )
            .foregroundStyle(by: .value("Series", "Filtered"))
            .lineStyle(StrokeStyle(lineWidth: 3))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(["Raw": Color.secondary.opacity(0.5), "Filtered": Color.accentColor])
        .chartYAxisLabel("meters")
        .chartXAxis(.hidden)
        .frame(height: 180)
        .overlay {
            if readings.isEmpty {
                Text("No readings yet")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
