//
//  LedgerBluetoothTransport.swift
//  ZcashLightClientKit
//

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// A Bluetooth LE connection to a Ledger device, opened by ``LedgerBluetoothScanner``.
///
/// Exchanges are serialized: one command is on the wire at a time. When an exchange fails once its
/// first frame has been written (a timeout, a disconnect, a reply that does not reassemble, a cancelled
/// task), the connection is closed: the device's reply to that command could otherwise be taken for the
/// reply to the next one. Every later exchange then throws the error that closed it, or
/// ``ZcashError/ledgerTransportClosed`` after a cancellation or ``close()``.
public actor LedgerBluetoothTransport: LedgerAPDUTransport {
    /// The device this transport is connected to.
    public nonisolated let device: LedgerBluetoothDevice

    private let connection: LedgerBluetoothConnection
    private let gate = LedgerSerialGate()

    init(device: LedgerBluetoothDevice, connection: LedgerBluetoothConnection) {
        self.device = device
        self.connection = connection
    }

    /// Sends one command and returns the device's reply; see
    /// ``LedgerAPDUTransport/exchange(_:timeout:)`` for what a thrown error means to the caller.
    ///
    /// Exchanges on this transport are serialized, one at a time. A caller cancelled while still
    /// queued behind another exchange on this same transport throws ``LedgerExchangeNotStarted``
    /// instead of `CancellationError`, and the transport stays open. The SDK's own commands
    /// normalize that to `CancellationError`; a caller that exchanges on this transport directly
    /// sees ``LedgerExchangeNotStarted`` itself.
    public func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        try await ledgerGatedExchange(on: gate) {
            try await connection.exchange(apdu, timeout: timeout)
        }
    }

    public func close() async {
        connection.close()
    }
}

/// One GATT connection and its Ledger framing. Every property is confined to the central's queue,
/// which is also the queue CoreBluetooth delivers the peripheral's callbacks on.
final class LedgerBluetoothConnection: NSObject, @unchecked Sendable {
    enum Phase {
        case connecting
        case discovering
        case subscribing
        case negotiatingFrameSize
        case ready
        case closed
    }

    /// The command in flight.
    final class PendingExchange {
        let id: Int
        let frames: [Data]
        let continuation: CheckedContinuation<Data, Error>
        var framesWritten = 0
        var awaitingWriteAcknowledgement = false
        var timeout: DispatchWorkItem?

        init(id: Int, frames: [Data], continuation: CheckedContinuation<Data, Error>) {
            self.id = id
            self.frames = frames
            self.continuation = continuation
        }
    }

    let peripheral: CBPeripheral
    let central: LedgerBluetoothCentral
    var queue: DispatchQueue { central.queue }
    var logger: Logger? { central.logger }

    var phase: Phase = .connecting
    var closeReason: ZcashError?
    var openContinuation: CheckedContinuation<Void, Error>?
    var openTimeout: DispatchWorkItem?
    var service: LedgerBluetoothService?
    var notifyCharacteristic: CBCharacteristic?
    var writeCharacteristic: CBCharacteristic?
    var writeType: CBCharacteristicWriteType = .withResponse
    var frameSize = 0
    var deframer: LedgerBLEDeframer?
    var pending: PendingExchange?
    var nextExchangeID = 0
    var cancelledExchangeIDs: Set<Int> = []

    init(peripheral: CBPeripheral, central: LedgerBluetoothCentral) {
        self.peripheral = peripheral
        self.central = central
        super.init()
    }

    // MARK: - Opening

    /// Connects, discovers the Ledger service, subscribes to the reply characteristic (which brings up
    /// pairing when the link is not yet bonded) and negotiates the frame size.
    func open(timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.queue.async {
                    self.beginOpening(timeout: timeout, continuation: continuation)
                }
            }
        } onCancel: {
            self.queue.async {
                self.fail(with: nil)
            }
        }
    }

    private func beginOpening(timeout: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
        guard phase == .connecting, openContinuation == nil else {
            continuation.resume(throwing: closeReason ?? ZcashError.ledgerTransportClosed)
            return
        }

        openContinuation = continuation
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.fail(with: .ledgerTimeout)
        }
        openTimeout = timeoutItem
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        peripheral.delegate = self
        central.requestConnection(peripheral)
    }

    /// The link is up. Called on the queue by the central.
    func didConnect() {
        guard phase == .connecting else {
            return
        }

        logger?.debug("Ledger BLE: connected, discovering services")
        phase = .discovering
        peripheral.discoverServices(LedgerBluetoothCentral.serviceUUIDs)
    }

    /// The handshake reply arrived: the connection is ready.
    func handleFrameSizeResponse(_ value: Data) {
        // The device answers the handshake first; any other frame this early is dropped, as Ledger's
        // web transport does.
        guard value.first == 0x08 else {
            logger?.debug("Ledger BLE: dropped a \(value.count)-byte frame during the handshake")
            return
        }

        do {
            let deviceFrameSize = try ZcashLedgerBackend.parseBLEMTUResponse(value)
            // A frame must also fit in one write on this link.
            frameSize = min(deviceFrameSize, peripheral.maximumWriteValueLength(for: writeType))
        } catch {
            fail(with: .ledgerMalformedReply("the BLE frame size handshake failed"))
            return
        }

        phase = .ready
        logger?.debug("Ledger BLE: ready, frame size \(frameSize)")
        openTimeout?.cancel()
        openTimeout = nil
        openContinuation?.resume()
        openContinuation = nil
    }

    // MARK: - Exchanging

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        let exchangeID: Int = queue.sync {
            self.nextExchangeID += 1
            return self.nextExchangeID
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                self.queue.async {
                    self.begin(exchangeID, apdu: apdu, timeout: timeout, continuation: continuation)
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancel(exchangeID)
            }
        }
    }

    private func begin(_ exchangeID: Int, apdu: Data, timeout: TimeInterval?, continuation: CheckedContinuation<Data, Error>) {
        if cancelledExchangeIDs.remove(exchangeID) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        guard phase == .ready else {
            continuation.resume(throwing: closeReason ?? ZcashError.ledgerTransportClosed)
            return
        }

        guard pending == nil else {
            continuation.resume(throwing: ZcashError.ledgerInternal("an exchange was started while another was in flight"))
            return
        }

        let frames: [Data]
        do {
            frames = try ZcashLedgerBackend.bleFrames(apdu, frameSize: frameSize)
        } catch {
            continuation.resume(throwing: ledgerZcashError(error))
            return
        }

        let exchange = PendingExchange(id: exchangeID, frames: frames, continuation: continuation)
        pending = exchange
        if let timeout {
            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.timeOut(exchangeID)
            }
            exchange.timeout = timeoutItem
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        }

        logger?.debug("Ledger BLE: sending a \(apdu.count)-byte command in \(frames.count) frame(s)")
        writePendingFrames()
    }

    private func cancel(_ exchangeID: Int) {
        guard let exchange = pending, exchange.id == exchangeID else {
            // Not started yet: the start still queued sees the mark.
            if exchangeID == nextExchangeID {
                cancelledExchangeIDs.insert(exchangeID)
            }
            return
        }

        if exchange.framesWritten == 0 {
            finishPending(with: .failure(CancellationError()))
        } else {
            fail(with: nil)
        }
    }

    private func timeOut(_ exchangeID: Int) {
        guard let exchange = pending, exchange.id == exchangeID else {
            return
        }

        logger?.warn("Ledger BLE: no reply before the timeout")
        fail(with: .ledgerTimeout)
    }

    /// Writes the frames of the command in flight, as far as the link lets it.
    func writePendingFrames() {
        guard let exchange = pending, let writeCharacteristic else {
            return
        }

        while exchange.framesWritten < exchange.frames.count {
            let frame = exchange.frames[exchange.framesWritten]
            if writeType == .withoutResponse {
                // Writes without a response are dropped when the link's buffer is full; CoreBluetooth
                // calls `peripheralIsReady(toSendWriteWithoutResponse:)` once there is room again.
                guard peripheral.canSendWriteWithoutResponse else {
                    return
                }

                peripheral.writeValue(frame, for: writeCharacteristic, type: .withoutResponse)
                exchange.framesWritten += 1
            } else {
                guard !exchange.awaitingWriteAcknowledgement else {
                    return
                }

                exchange.awaitingWriteAcknowledgement = true
                peripheral.writeValue(frame, for: writeCharacteristic, type: .withResponse)
                exchange.framesWritten += 1
            }
        }
    }

    /// A notification frame arrived while the connection is ready.
    func handleReplyFrame(_ frame: Data) {
        guard pending != nil, let deframer else {
            // Nothing is outstanding, so the frame cannot be attributed to a command.
            fail(with: .ledgerMalformedReply("the device sent a frame with no command outstanding"))
            return
        }

        do {
            if let reply = try deframer.push(frame) {
                logger?.debug("Ledger BLE: received a \(reply.count)-byte reply")
                finishPending(with: .success(reply))
            }
        } catch {
            fail(with: .ledgerMalformedReply("a reply frame did not reassemble"))
        }
    }

    private func finishPending(with result: Result<Data, Error>) {
        guard let exchange = pending else {
            return
        }

        pending = nil
        exchange.timeout?.cancel()
        exchange.continuation.resume(with: result)
    }

    // MARK: - Closing

    func close() {
        queue.async {
            self.fail(with: .ledgerTransportClosed)
        }
    }

    /// Ends the connection for good: fails whatever is in flight with `reason` (or `CancellationError`
    /// when `nil`), refuses every later exchange, and drops the link. Called on the queue.
    /// - Parameter evenWhileConnecting: `fail(with: .ledgerBluetoothDisconnected)` is otherwise a
    ///   no-op while `.connecting`: that disconnect belongs to an earlier connection to the same
    ///   peripheral, whose cancellation is still being delivered, not to this one. A Bluetooth
    ///   reset is not that stale per-peripheral signal -- every connection is genuinely gone,
    ///   `.connecting` included -- so it passes `true` to reach a connecting connection too.
    func fail(with reason: ZcashError?, evenWhileConnecting: Bool = false) {
        guard phase != .closed else {
            return
        }

        // A disconnect that arrives before this connection's link is up belongs to an earlier
        // connection to the same peripheral, whose cancellation is still being delivered.
        if phase == .connecting, case .ledgerBluetoothDisconnected = reason, !evenWhileConnecting {
            return
        }

        logger?.debug("Ledger BLE: connection closed (\(reason?.code.rawValue ?? "cancelled"))")
        phase = .closed
        closeReason = reason ?? .ledgerTransportClosed

        let error: Error = reason ?? CancellationError()
        openTimeout?.cancel()
        openTimeout = nil
        openContinuation?.resume(throwing: error)
        openContinuation = nil
        finishPending(with: .failure(error))

        if peripheral.delegate === self {
            peripheral.delegate = nil
        }
        central.releaseConnection(self)
    }

    /// The error for a failed CoreBluetooth operation: a pairing refusal when the link could not be
    /// encrypted or the device no longer holds the pairing, a connection failure otherwise.
    static func connectionError(_ error: Error?) -> ZcashError {
        guard let error else {
            return .ledgerBluetoothConnectionFailed(nil)
        }

        let nsError = error as NSError
        // CBATTError: insufficientAuthentication (5), insufficientAuthorization (8),
        // insufficientEncryptionKeySize (12), insufficientEncryption (15).
        let attPairingCodes: Set<Int> = [5, 8, 12, 15]
        // CBError: peerRemovedPairingInformation (14), encryptionTimedOut (15).
        let pairingCodes: Set<Int> = [14, 15]
        let isATTPairingFailure = nsError.domain == CBATTError.errorDomain && attPairingCodes.contains(nsError.code)
        let isPairingFailure = nsError.domain == CBError.errorDomain && pairingCodes.contains(nsError.code)
        if isATTPairingFailure || isPairingFailure {
            return .ledgerBluetoothPairingRefused
        }

        return .ledgerBluetoothConnectionFailed(error)
    }
}

extension LedgerBluetoothConnection: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard phase == .discovering else {
            return
        }

        if let error {
            fail(with: Self.connectionError(error))
            return
        }

        let match = (peripheral.services ?? []).lazy
            .compactMap { candidate in
                LedgerBluetoothService.service(uuid: candidate.uuid.uuidString).map { (candidate, $0) }
            }
            .first
        guard let match else {
            fail(with: .ledgerBluetoothConnectionFailed(nil))
            return
        }

        let (candidate, ledgerService) = match
        service = ledgerService
        let characteristicUUIDs = [ledgerService.notifyUUID, ledgerService.writeUUID, ledgerService.writeCmdUUID].map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(characteristicUUIDs, for: candidate)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard phase == .discovering, let ledgerService = self.service else {
            return
        }

        if let error {
            fail(with: Self.connectionError(error))
            return
        }

        let characteristics = service.characteristics ?? []
        let characteristic: (String) -> CBCharacteristic? = { uuid in
            characteristics.first { $0.uuid.uuidString.caseInsensitiveCompare(uuid) == .orderedSame }
        }

        guard let notify = characteristic(ledgerService.notifyUUID) else {
            fail(with: .ledgerBluetoothConnectionFailed(nil))
            return
        }

        // Ledger's React Native transport writes to the write-without-response characteristic when the
        // device has one, and falls back to the write characteristic otherwise.
        if let writeCmd = characteristic(ledgerService.writeCmdUUID), writeCmd.properties.contains(.writeWithoutResponse) {
            writeCharacteristic = writeCmd
            writeType = .withoutResponse
        } else if let write = characteristic(ledgerService.writeUUID), write.properties.contains(.write) {
            writeCharacteristic = write
            writeType = .withResponse
        } else if let write = characteristic(ledgerService.writeUUID), write.properties.contains(.writeWithoutResponse) {
            writeCharacteristic = write
            writeType = .withoutResponse
        } else {
            fail(with: .ledgerBluetoothConnectionFailed(nil))
            return
        }

        notifyCharacteristic = notify
        phase = .subscribing
        logger?.debug("Ledger BLE: subscribing to replies")
        // The reply characteristic requires an encrypted link, so on a device that is not yet bonded
        // this is what brings up the system pairing request.
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard phase == .subscribing, characteristic.uuid == notifyCharacteristic?.uuid else {
            return
        }

        if let error {
            fail(with: Self.connectionError(error))
            return
        }

        guard characteristic.isNotifying, let writeCharacteristic else {
            fail(with: .ledgerBluetoothConnectionFailed(nil))
            return
        }

        do {
            deframer = try LedgerBLEDeframer()
            let request = try ZcashLedgerBackend.bleMTURequest()
            phase = .negotiatingFrameSize
            logger?.debug("Ledger BLE: negotiating the frame size")
            peripheral.writeValue(request, for: writeCharacteristic, type: writeType)
        } catch {
            fail(with: .ledgerInternal("the BLE handshake could not be prepared"))
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writePendingFrames()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail(with: Self.connectionError(error))
            return
        }

        guard let exchange = pending else {
            return
        }

        exchange.awaitingWriteAcknowledgement = false
        writePendingFrames()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyCharacteristic?.uuid else {
            return
        }

        if let error {
            fail(with: Self.connectionError(error))
            return
        }

        guard let value = characteristic.value else {
            return
        }

        switch phase {
        case .negotiatingFrameSize:
            handleFrameSizeResponse(value)
        case .ready:
            handleReplyFrame(value)
        case .connecting, .discovering, .subscribing, .closed:
            break
        }
    }
}
#endif
