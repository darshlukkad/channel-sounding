import Foundation
import CoreBluetooth
import AccessorySetupKit
import UIKit

/// A single distance reading captured from a Channel Sounding procedure.
struct RangeReading: Identifiable {
    let id = UUID()
    let date = Date()
    let meters: Double
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
    private(set) var currentRange: Double?
    private(set) var rangeReadings: [RangeReading] = []
    private(set) var sessionError: String?
    private(set) var isSessionActivated = false

    /// Maximum number of readings kept for the chart.
    private let maxReadings = 200

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

        rangeReadings.removeAll()
        currentRange = nil
        sessionError = nil

        let config = CBChannelSoundingSessionConfiguration(role: .initiator)
        peripheral.startChannelSoundingSession(config)

        if case .connected(let name) = connectionState {
            connectionState = .ranging(name)
        }
    }

    func stopChannelSounding() {
        connectedPeripheral?.cancelChannelSoundingSession()
        if case .ranging(let name) = connectionState {
            connectionState = .connected(name)
        }
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
        connectedPeripheral = nil
        currentRange = nil
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
            sessionError = error.localizedDescription
            return
        }
        // The API reports a negative sentinel when no valid measurement is available.
        guard let distance = results?.distance, distance > 0 else { return }
        currentRange = distance
        rangeReadings.append(RangeReading(meters: distance))
        if rangeReadings.count > maxReadings {
            rangeReadings.removeFirst(rangeReadings.count - maxReadings)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didCompleteChannelSoundingSession error: Error?) {
        if case .ranging(let name) = connectionState {
            connectionState = .connected(name)
        }
        if let error { sessionError = error.localizedDescription }
    }
}
