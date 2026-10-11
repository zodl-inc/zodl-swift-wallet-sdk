//
//  LedgerBluetoothScanner.swift
//  ZcashLightClientKit
//

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// Finds Ledger devices over Bluetooth LE and opens connections to them.
///
/// The app must declare `NSBluetoothAlwaysUsageDescription` in its `Info.plist`; the first scan
/// triggers the system's permission prompt. The first connection to a device triggers Bluetooth
/// pairing: the system shows a pairing request and the device shows a code for the user to confirm.
///
/// A transport keeps the Bluetooth machinery it needs alive, so the scanner may be released once the
/// connection is open.
public final class LedgerBluetoothScanner: @unchecked Sendable {
    // @unchecked Sendable: every mutable state lives in `central`, confined to its dispatch queue.
    private let central: LedgerBluetoothCentral

    /// - Parameter logger: Receives connection stages, frame sizes and error kinds; never command or
    ///   reply bytes.
    public init(logger: Logger? = nil) {
        central = LedgerBluetoothCentral(logger: logger)
    }

    /// Scans for Ledger devices.
    ///
    /// The stream yields every device found so far each time the list changes, devices the system is
    /// already connected to included. It ends with ``ZcashError/ledgerBluetoothUnsupported``,
    /// ``ZcashError/ledgerBluetoothUnauthorized`` or ``ZcashError/ledgerBluetoothPoweredOff`` when
    /// Bluetooth is unavailable, or ``ZcashError/ledgerBluetoothDisconnected`` when it resets while
    /// this is the active scan. Scanning stops when the iteration ends; one scan runs at a time, and a
    /// new one ends the previous stream.
    public func devices() -> AsyncThrowingStream<[LedgerBluetoothDevice], Error> {
        // Each element is the whole list, so a slow consumer only needs the latest one.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let central = self.central
            let scan = central.beginScan(continuation)
            continuation.onTermination = { _ in
                central.endScan(scan)
            }
        }
    }

    /// Connects to a device, subscribes to its replies and negotiates the frame size.
    ///
    /// Connecting to a device that already has a live connection replaces it: the last caller to
    /// connect always wins. The displaced connection fails with the non-restartable
    /// ``ZcashError/ledgerTransportReplaced``, never the restartable
    /// ``ZcashError/ledgerTransportClosed``, since reconnecting on this error would only displace
    /// whichever connection replaced it in turn.
    ///
    /// - Parameters:
    ///   - device: A device from ``devices()``.
    ///   - timeout: How long connecting may take, in seconds, pairing included: the user confirms the
    ///     pairing code on the device within it.
    /// - Throws: ``ZcashError/ledgerDeviceNotFound`` when the system no longer knows the device,
    ///   ``ZcashError/ledgerBluetoothPairingRefused`` when pairing was refused or the device no longer
    ///   holds it, ``ZcashError/ledgerTimeout``, ``ZcashError/ledgerBluetoothConnectionFailed(_:)``,
    ///   ``ZcashError/ledgerTransportReplaced`` when a later call to this method, for the same
    ///   device, displaces this one while it is still connecting,
    ///   ``ZcashError/ledgerBluetoothDisconnected`` when Bluetooth resets while this call is
    ///   connecting, or `CancellationError`.
    public func connect(to device: LedgerBluetoothDevice, timeout: TimeInterval = 60) async throws -> LedgerBluetoothTransport {
        try await central.waitUntilPoweredOn()
        // The state change that ends the wait resumes every waiter at once, a caller cancelled in
        // that same instant included; such a caller must not go on to displace a connection a
        // live caller is making. `central.connect` displaces synchronously, so nothing can be
        // cancelled between this check and the displacement.
        try Task.checkCancellation()
        let connection = try await central.connect(to: device, timeout: timeout)
        return LedgerBluetoothTransport(device: device, connection: connection)
    }
}

/// The `CBCentralManager` and its delegate. Every property is confined to `queue`, which is also the
/// queue CoreBluetooth delivers its callbacks on.
final class LedgerBluetoothCentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "co.electriccoin.ZcashLightClientKit.LedgerBluetooth")
    let logger: Logger?

    private var manager: CBCentralManager?
    /// The callers of ``waitUntilPoweredOn()`` parked until the central's state is known, by the
    /// waiter's own id so a cancelled one can be taken out again.
    private var stateWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Waiters whose task was cancelled before their continuation was parked: the cancellation
    /// handler and the parking both run on `queue`, in either order, so whichever runs second
    /// resolves the wait.
    private var cancelledStateWaiters: Set<UUID> = []
    private var scanID = 0
    private var scanContinuation: AsyncThrowingStream<[LedgerBluetoothDevice], Error>.Continuation?
    private var discovered: [UUID: LedgerBluetoothDevice] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connections: [UUID: LedgerBluetoothConnection] = [:]

    init(logger: Logger?) {
        self.logger = logger
        super.init()
        queue.async {
            self.manager = CBCentralManager(
                delegate: self,
                queue: self.queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
    }

    static var serviceUUIDs: [CBUUID] {
        LedgerBluetoothService.all.map { CBUUID(string: $0.serviceUUID) }
    }

    // MARK: - State

    /// Returns once Bluetooth is powered on, or throws the reason it is not available.
    ///
    /// A caller cancelled while the state is still unknown (or resetting) is taken out of the wait
    /// and thrown `CancellationError` at once, instead of staying parked until Bluetooth comes up and
    /// then going on to connect for a caller that is no longer there.
    func waitUntilPoweredOn() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard self.cancelledStateWaiters.remove(id) == nil else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    switch self.availability(for: self.manager?.state ?? .unknown) {
                    case .success(true):
                        continuation.resume()
                    case .success(false):
                        self.stateWaiters[id] = continuation
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            queue.async {
                if let waiter = self.stateWaiters.removeValue(forKey: id) {
                    waiter.resume(throwing: CancellationError())
                } else {
                    self.cancelledStateWaiters.insert(id)
                }
            }
        }
    }

    /// `true` when powered on, `false` while `state` is not known yet (before construction finishes,
    /// this is `.unknown`; see ``waitUntilPoweredOn()``).
    private func availability(for state: CBManagerState) -> Result<Bool, ZcashError> {
        switch state {
        case .poweredOn:
            return .success(true)
        case .unknown, .resetting:
            return .success(false)
        case .unsupported:
            return .failure(.ledgerBluetoothUnsupported)
        case .unauthorized:
            return .failure(.ledgerBluetoothUnauthorized)
        case .poweredOff:
            return .failure(.ledgerBluetoothPoweredOff)
        @unknown default:
            return .failure(.ledgerBluetoothUnsupported)
        }
    }

    /// Updates for a new central state, read from the delegate callback by
    /// ``centralManagerDidUpdateState(_:)``. CoreBluetooth tears down every connection across a
    /// `.resetting`, so every open connection and the active scan, if any, fail with
    /// ``ZcashError/ledgerBluetoothDisconnected`` (restartable); state waiters are left queued,
    /// since a reset normally comes back to `.poweredOn` on its own. `.unknown` keeps the "not known
    /// yet" behavior from before this state existed: nothing to do.
    func handleStateChange(_ state: CBManagerState) {
        logger?.debug("Ledger BLE: central state \(state.rawValue)")

        switch availability(for: state) {
        case .success(true):
            let waiters = stateWaiters.values
            stateWaiters = [:]
            waiters.forEach { $0.resume() }
        case .success(false):
            guard state == .resetting else {
                return
            }

            let error = ZcashError.ledgerBluetoothDisconnected
            // `evenWhileConnecting`: a reset is not the stale per-peripheral disconnect
            // `fail(with:)` otherwise ignores while `.connecting` -- every connection is
            // genuinely gone, one still opening included.
            connections.values.forEach { $0.fail(with: error, evenWhileConnecting: true) }
            scanContinuation?.finish(throwing: error)
            scanContinuation = nil
            // CoreBluetooth invalidates every `CBPeripheral` it handed out below `.poweredOn`, so a
            // cached one from before the reset must not be reused once it comes back.
            peripherals = [:]
            discovered = [:]
        case .failure(let error):
            let waiters = stateWaiters.values
            stateWaiters = [:]
            waiters.forEach { $0.resume(throwing: error) }
            scanContinuation?.finish(throwing: error)
            scanContinuation = nil
            connections.values.forEach { $0.fail(with: error) }
            // Same invalidation as the reset above: every state here is below `.poweredOn` too.
            peripherals = [:]
            discovered = [:]
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleStateChange(central.state)
    }

    // MARK: - Scanning

    /// Starts a scan feeding `continuation`, ending any scan in progress. Returns the scan's identifier.
    func beginScan(_ continuation: AsyncThrowingStream<[LedgerBluetoothDevice], Error>.Continuation) -> Int {
        let scan: Int = queue.sync {
            self.scanID += 1
            return self.scanID
        }

        Task {
            do {
                try await waitUntilPoweredOn()
                queue.async {
                    self.startScanning(scan, continuation: continuation)
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }

        return scan
    }

    func endScan(_ scan: Int) {
        queue.async {
            guard self.scanID == scan else {
                return
            }

            // Invalidates the scan, so that a start still waiting for Bluetooth does not begin it.
            self.scanID += 1
            self.scanContinuation = nil
            self.manager?.stopScan()
        }
    }

    private func startScanning(_ scan: Int, continuation: AsyncThrowingStream<[LedgerBluetoothDevice], Error>.Continuation) {
        guard scan == scanID, let manager else {
            continuation.finish()
            return
        }

        scanContinuation?.finish()
        scanContinuation = continuation
        discovered = [:]

        // A device already connected to the system does not advertise.
        for service in LedgerBluetoothService.all {
            for peripheral in manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: service.serviceUUID)]) {
                peripherals[peripheral.identifier] = peripheral
                discovered[peripheral.identifier] = LedgerBluetoothDevice(
                    id: peripheral.identifier,
                    name: peripheral.name,
                    model: service.model,
                    rssi: nil
                )
            }
        }
        publishDiscovered()

        manager.scanForPeripherals(
            withServices: Self.serviceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        logger?.debug("Ledger BLE: scanning")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard let service = advertised.lazy.compactMap({ LedgerBluetoothService.service(uuid: $0.uuidString) }).first else {
            return
        }

        // 127 is CoreBluetooth's "not available".
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
        let device = LedgerBluetoothDevice(
            id: peripheral.identifier,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            model: service.model,
            rssi: rssi
        )

        peripherals[peripheral.identifier] = peripheral
        guard discovered[peripheral.identifier] != device else {
            return
        }

        discovered[peripheral.identifier] = device
        publishDiscovered()
    }

    private func publishDiscovered() {
        let devices = discovered.values.sorted { lhs, rhs in
            (lhs.rssi ?? Int.max) > (rhs.rssi ?? Int.max)
        }
        scanContinuation?.yield(devices)
    }

    // MARK: - Connecting

    func connect(to device: LedgerBluetoothDevice, timeout: TimeInterval) async throws -> LedgerBluetoothConnection {
        let connection: LedgerBluetoothConnection = try queue.sync {
            guard let manager else {
                throw ZcashError.ledgerBluetoothUnsupported
            }

            let knownPeripheral = peripherals[device.id] ?? manager.retrievePeripherals(withIdentifiers: [device.id]).first
            guard let peripheral = knownPeripheral else {
                throw ZcashError.ledgerDeviceNotFound
            }

            if let existing = connections[device.id] {
                // Last caller to connect wins. `.ledgerTransportReplaced` rather than the
                // restartable `.ledgerTransportClosed`: that would invite the displaced owner to
                // reconnect, which would just displace this new connection in turn.
                logger?.debug("Ledger BLE: a new connection replaced an existing one")
                existing.fail(with: .ledgerTransportReplaced)
            }

            let connection = LedgerBluetoothConnection(peripheral: peripheral, central: self)
            connections[device.id] = connection
            return connection
        }

        try await connection.open(timeout: timeout)
        return connection
    }

    /// Asks CoreBluetooth to connect. Called on `queue` by the connection.
    func requestConnection(_ peripheral: CBPeripheral) {
        manager?.connect(peripheral, options: nil)
    }

    /// Drops the link and forgets the connection. Called on `queue` by the connection.
    func releaseConnection(_ connection: LedgerBluetoothConnection) {
        // A connection that was replaced no longer owns the link.
        let identifier = connection.peripheral.identifier
        guard connections[identifier] === connection else {
            return
        }

        connections[identifier] = nil
        manager?.cancelPeripheralConnection(connection.peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connections[peripheral.identifier]?.didConnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connections[peripheral.identifier]?.fail(with: LedgerBluetoothConnection.connectionError(error))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connections[peripheral.identifier]?.fail(with: .ledgerBluetoothDisconnected)
    }
}
#endif
