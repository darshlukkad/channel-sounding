import SwiftUI
import Charts

struct ContentView: View {
    @State private var manager = ChannelSoundingManager()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                StatusRow(state: manager.connectionState)

                DistanceCard(distance: manager.currentRange,
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
                        Button("Forget Accessory", role: .destructive) {
                            manager.forgetAccessory()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
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

/// Large live distance readout.
private struct DistanceCard: View {
    let distance: Double?
    let isRanging: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(distanceText)
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: distance)
            Text("Distance")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(.fill.tertiary, in: .rect(cornerRadius: 20))
    }

    private var distanceText: String {
        guard let distance else { return isRanging ? "…" : "--" }
        return distance.formatted(.number.precision(.fractionLength(2))) + " m"
    }
}

/// Line chart of recent distance readings.
private struct RangeChart: View {
    let readings: [RangeReading]

    var body: some View {
        Chart(readings) { reading in
            LineMark(
                x: .value("Time", reading.date),
                y: .value("Distance (m)", reading.meters)
            )
            .interpolationMethod(.monotone)
        }
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
