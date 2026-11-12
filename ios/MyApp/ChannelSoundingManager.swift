import Foundation
import CoreBluetooth
import AccessorySetupKit
import UIKit

/// A single distance reading captured from a Channel Sounding procedure.
struct RangeReading: Identifiable {
    let id = UUID()
    let date = Date()
    /// The calibrated reading as reported by Channel Sounding, in meters.
    let raw: Double
    /// The filtered estimate after this reading, in meters.
    let filtered: Double
}

/// The connection lifecycle of the paired accessory.
enum ConnectionState: Equatable {
    case idle
    case connecting(String)
    case connected(String)
    case ranging(String)

    var isConnected: Bool {
        switch self {
        case .connected, .ranging: true
        default: false
        }
    }

    var isRanging: Bool {
        if case .ranging = self { return true }
        return false
    }
}

/// Pairs the accessory with AccessorySetupKit, connects with Core Bluetooth,
/// and runs a Channel Sounding session with the iPhone as the initiator.
@Observable
final class ChannelSoundingManager: NSObject {
    private(set) var connectionState: ConnectionState = .idle
    /// The filtered distance, in meters.
    private(set) var currentRange: Double?
    /// The latest calibrated reading before filtering, in meters.
    private(set) var rawRange: Double?
    /// Standard deviation of recent raw readings, in meters.
    private(set) var spread: Double?
    /// Smoothed RSSI of the connection, in dBm.
    private(set) var rssi: Double?
    /// Readings held back as likely multipath errors in this session.
    private(set) var gatedCount = 0
    private(set) var rangeReadings: [RangeReading] = []
    private(set) var sessionError: String?
    private(set) var isSessionActivated = false

    /// Fixed error subtracted from every reading, in meters. Persisted across launches.
    private(set) var calibrationOffset: Double = UserDefaults.standard.double(forKey: ChannelSoundingManager.calibrationOffsetKey) {
        didSet { UserDefaults.standard.set(calibrationOffset, forKey: Self.calibrationOffsetKey) }
    }
    private static let calibrationOffsetKey = "calibrationOffset"

    /// Maximum number of readings kept for the chart.
    private let maxReadings = 200
    /// Number of recent raw readings used for the spread value.
    private let spreadWindow = 20
    /// How often to read RSSI while ranging.
    private let rssiInterval: Duration = .milliseconds(500)
    /// Weight of each new RSSI sample in the smoothed value.
    private let rssiSmoothing = 0.3

    private var filter = RangeFilter()
    private var rssiTask: Task<Void, Never>?

    private let accessorySession = ASAccessorySession()
    private var central: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var pendingPeripheralIdentifier: UUID?
    private var pendingPeripheralName: String?

    /// Service UUIDs the accessory advertises, read from Info.plist so the picker
    /// filter and the AccessorySetupKit declaration always match.
    private static let accessoryServiceUUIDs: [CBUUID] = {
        let strings = Bundle.main.infoDictionary?["NSAccessorySetupBluetoothServices"] as? [String] ?? []
        return strings.map { CBUUID(string: $0) }
    }()

    var hasPairedAccessory: Bool {
        !accessorySession.accessories.isEmpty
    }

    override init() {
        super.init()
        accessorySession.activate(on: .main) { [weak self] event in
            self?.handleAccessoryEvent(event)
        }
    }

    // MARK: - Pairing

    /// Presents the system accessory picker, or reconnects if an accessory is already paired.
    func showAccessoryPicker() {
        guard isSessionActivated else { return }

        if let accessory = accessorySession.accessories.first,
           let identifier = accessory.bluetoothIdentifier {
            connectAccessory(identifier: identifier, name: accessory.displayName)
            return
        }

        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = Self.accessoryServiceUUIDs.first
        descriptor.supportedOptions = .bluetoothPairingLE

        let item = ASPickerDisplayItem(
            name: "nRF54L15 Reflector",
            productImage: UIImage(systemName: "antenna.radiowaves.left.and.right") ?? UIImage(),
            descriptor: descriptor)

        accessorySession.showPicker(for: [item]) { [weak self] error in
            if let error {
                self?.sessionError = error.localizedDescription
            }
        }
    }

    /// Removes the paired accessory so a different board can be paired.
    func forgetAccessory() {
        guard let accessory = accessorySession.accessories.first else { return }
        disconnect()
        accessorySession.removeAccessory(accessory) { [weak self] error in
            if let error {
                self?.sessionError = error.localizedDescription
            }
        }
    }

    private func handleAccessoryEvent(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            isSessionActivated = true
            // Reconnect automatically to a previously paired accessory.
            if let accessory = accessorySession.accessories.first,
               let identifier = accessory.bluetoothIdentifier {
                connectAccessory(identifier: identifier, name: accessory.displayName)
            }
        case .accessoryAdded:
            guard let accessory = event.accessory,
                  let identifier = accessory.bluetoothIdentifier else { return }
            connectAccessory(identifier: identifier, name: accessory.displayName)
        case .accessoryRemoved:
            connectionState = .idle
        default:
            break
        }
    }

    // MARK: - Connection

    private func connectAccessory(identifier: UUID, name: String) {
        // Create the central manager only after pairing; creating it earlier
        // triggers the Bluetooth permission prompt and blocks the picker.
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        if central?.state == .poweredOn {
            retrieveAndConnect(identifier: identifier, name: name)
        } else {
            pendingPeripheralIdentifier = identifier
            pendingPeripheralName = name
            connectionState = .connecting(name)
        }
    }

    private func retrieveAndConnect(identifier: UUID, name: String) {
        let peripherals = central?.retrievePeripherals(withIdentifiers: [identifier]) ?? []
        if let peripheral = peripherals.first {
            connectedPeripheral = peripheral
            peripheral.delegate = self
            connectionState = .connecting(name)
            central?.connect(peripheral)
            return
        }
        // Not in Core Bluetooth's cache yet (first launch after pairing), so scan for it.
        pendingPeripheralIdentifier = identifier
        pendingPeripheralName = name
        connectionState = .connecting(name)
        central?.scanForPeripherals(withServices: Self.accessoryServiceUUIDs)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        if connectionState.isRanging { stopChannelSounding() }
        central?.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Channel Sounding

    func startChannelSounding() {
        guard let peripheral = connectedPeripheral, connectionState.isConnected else { return }
        guard !connectionState.isRanging else { return }
        guard CBCentralManager.supports(.channelSounding) else {
            sessionError = "Channel Sounding is not supported on this device."
            return
        }

        resetMeasurements()
        sessionError = nil

        let config = CBChannelSoundingSessionConfiguration(role: .initiator)
        peripheral.startChannelSoundingSession(config)
        startRSSIPolling(peripheral)

        if case .connected(let name) = connectionState {
            connectionState = .ranging(name)
        }
    }

    func stopChannelSounding() {
        connectedPeripheral?.cancelChannelSoundingSession()
        stopRSSIPolling()
        if case .ranging(let name) = connectionState {
            connectionState = .connected(name)
        }
    }

    // MARK: - Measurements

    private func resetMeasurements() {
        filter.reset()
        rangeReadings.removeAll()
        currentRange = nil
        rawRange = nil
        spread = nil
        gatedCount = 0
    }

    private func handleDistance(_ reportedMeters: Double) {
        let raw = reportedMeters - calibrationOffset
        let output = filter.update(raw, rssi: rssi)
        if output.rejected { gatedCount += 1 }

        rawRange = raw
        currentRange = output.estimate
        rangeReadings.append(RangeReading(raw: raw, filtered: output.estimate))
        if rangeReadings.count > maxReadings {
            rangeReadings.removeFirst(rangeReadings.count - maxReadings)
        }
        let recent = rangeReadings.suffix(spreadWindow).map(\.raw)
        spread = recent.count >= 5 ? RangeFilter.standardDeviation(of: recent) : nil
    }

    // MARK: - Calibration

    /// Sets the offset so the current filtered distance reads as `knownDistance`.
    /// Place the board exactly that far from the phone, let it settle, then call this.
    func calibrate(atKnownDistance knownDistance: Double = 1.0) {
        guard let currentRange else { return }
        calibrationOffset += currentRange - knownDistance
        // Restart the filter so old, uncalibrated readings don't pull the estimate.
        resetMeasurements()
    }

    func resetCalibration() {
        calibrationOffset = 0
        resetMeasurements()
    }

    // MARK: - RSSI

    /// Reads RSSI periodically while ranging; the filter uses it to tell real
    /// movement from multipath jumps.
    private func startRSSIPolling(_ peripheral: CBPeripheral) {
        stopRSSIPolling()
        rssi = nil
        rssiTask = Task { [weak self, rssiInterval] in
            while !Task.isCancelled {
                peripheral.readRSSI()
                try? await Task.sleep(for: rssiInterval)
                if self == nil { return }
            }
        }
    }

    private func stopRSSIPolling() {
        rssiTask?.cancel()
        rssiTask = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension ChannelSoundingManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unauthorized {
                sessionError = "Bluetooth access is not authorized."
            }
            return
        }
        if let identifier = pendingPeripheralIdentifier {
            let name = pendingPeripheralName ?? "Accessory"
            pendingPeripheralIdentifier = nil
            pendingPeripheralName = nil
            retrieveAndConnect(identifier: identifier, name: name)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard peripheral.identifier == pendingPeripheralIdentifier else { return }
        central.stopScan()
        let name = pendingPeripheralName ?? peripheral.name ?? "Accessory"
        pendingPeripheralIdentifier = nil
        pendingPeripheralName = nil
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting(name)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if case .connecting(let name) = connectionState {
            connectionState = .connected(name)
        } else {
            connectionState = .connected(peripheral.name ?? "Accessory")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connectedPeripheral = nil
        connectionState = .idle
        sessionError = error?.localizedDescription ?? "Failed to connect."
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        stopRSSIPolling()
        connectedPeripheral = nil
        currentRange = nil
        rawRange = nil
        connectionState = .idle
        if let error { sessionError = error.localizedDescription }
    }
}

// MARK: - CBPeripheralDelegate

extension ChannelSoundingManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral,
                    didReceive results: CBChannelSoundingProcedureResults?,
                    error: Error?) {
        if let error {
            sessionError = Self.channelSoundingErrorMessage(for: error)
            return
        }
        // The API reports a negative sentinel when no valid measurement is available.
        guard let distance = results?.distance, distance > 0 else { return }
        handleDistance(distance)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        // 127 means the controller couldn't measure RSSI.
        guard error == nil, RSSI.intValue != 127 else { return }
        let sample = RSSI.doubleValue
        rssi = rssi.map { $0 + rssiSmoothing * (sample - $0) } ?? sample
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didCompleteChannelSoundingSession error: Error?) {
        stopRSSIPolling()
        if case .ranging(let name) = connectionState {
            connectionState = .connected(name)
        }
        if let error { sessionError = Self.channelSoundingErrorMessage(for: error) }
    }

    /// Builds a readable message that includes the error code, plus recovery
    /// hints for the Channel Sounding failures seen with nRF54L15 reflectors.
    private static func channelSoundingErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        let base = "\(error.localizedDescription) (\(nsError.domain) \(nsError.code))"

        guard nsError.domain == CBError.errorDomain else { return base }
        switch nsError.code {
        case 19:
            // channelSoundingConfigurationFailed: often happens on the first attempt
            // right after a fresh AccessorySetupKit pairing on iOS 27.
            return base + "\nChannel Sounding configuration failed. Power-cycle the board, reconnect, and start ranging again."
        case CBError.operationNotSupported.rawValue:
            return base + "\nThe board connected but didn't accept Channel Sounding. Check that its firmware is a CS reflector with the Ranging Service (RAS) enabled."
        default:
            return base
        }
    }
}
