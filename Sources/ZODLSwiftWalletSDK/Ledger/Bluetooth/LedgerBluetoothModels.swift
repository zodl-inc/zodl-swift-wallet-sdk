//
//  LedgerBluetoothModels.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// A Ledger model that speaks Bluetooth LE.
public enum LedgerDeviceModel: String, CaseIterable, Equatable, Hashable, Sendable {
    case nanoX
    case stax
    case flex
    case nanoGen5

    /// The product name Ledger uses for the model.
    public var productName: String {
        switch self {
        case .nanoX: return "Ledger Nano X"
        case .stax: return "Ledger Stax"
        case .flex: return "Ledger Flex"
        case .nanoGen5: return "Ledger Nano Gen5"
        }
    }
}

/// A Ledger device found by ``LedgerBluetoothScanner``.
public struct LedgerBluetoothDevice: Equatable, Hashable, Identifiable, Sendable {
    /// The identifier the system assigned the device. Stable on this phone, and different on another.
    public let id: UUID
    /// The name the device advertises, such as "Nano X 1A2B".
    public let name: String?
    public let model: LedgerDeviceModel
    /// The received signal strength in dBm, or `nil` for a device already connected to the system,
    /// which does not advertise.
    public let rssi: Int?
}

/// The GATT layout of one Ledger Bluetooth service.
///
/// Taken from LedgerHQ/device-sdk-ts at commit `2c92958de2c1e0318cc68551871ec74044106b54`,
/// `packages/device-management-kit/src/api/device-model/data/StaticDeviceModelDataSource.ts`
/// (`bluetoothSpec`). The Nano Gen5 (`DeviceModelId.APEX` there) advertises one of two services.
struct LedgerBluetoothService: Equatable {
    let model: LedgerDeviceModel
    let serviceUUID: String
    let notifyUUID: String
    /// The characteristic written with a response.
    let writeUUID: String
    /// The characteristic written without a response, which Ledger's React Native transport prefers
    /// when the device exposes it (`RNBleApduSender.ts`, same commit).
    let writeCmdUUID: String

    static let all: [LedgerBluetoothService] = [
        LedgerBluetoothService(
            model: .nanoX,
            serviceUUID: "13d63400-2c97-0004-0000-4c6564676572",
            notifyUUID: "13d63400-2c97-0004-0001-4c6564676572",
            writeUUID: "13d63400-2c97-0004-0002-4c6564676572",
            writeCmdUUID: "13d63400-2c97-0004-0003-4c6564676572"
        ),
        LedgerBluetoothService(
            model: .stax,
            serviceUUID: "13d63400-2c97-6004-0000-4c6564676572",
            notifyUUID: "13d63400-2c97-6004-0001-4c6564676572",
            writeUUID: "13d63400-2c97-6004-0002-4c6564676572",
            writeCmdUUID: "13d63400-2c97-6004-0003-4c6564676572"
        ),
        LedgerBluetoothService(
            model: .flex,
            serviceUUID: "13d63400-2c97-3004-0000-4c6564676572",
            notifyUUID: "13d63400-2c97-3004-0001-4c6564676572",
            writeUUID: "13d63400-2c97-3004-0002-4c6564676572",
            writeCmdUUID: "13d63400-2c97-3004-0003-4c6564676572"
        ),
        LedgerBluetoothService(
            model: .nanoGen5,
            serviceUUID: "13d63400-2c97-8004-0000-4c6564676572",
            notifyUUID: "13d63400-2c97-8004-0001-4c6564676572",
            writeUUID: "13d63400-2c97-8004-0002-4c6564676572",
            writeCmdUUID: "13d63400-2c97-8004-0003-4c6564676572"
        ),
        LedgerBluetoothService(
            model: .nanoGen5,
            serviceUUID: "13d63400-2c97-9004-0000-4c6564676572",
            notifyUUID: "13d63400-2c97-9004-0001-4c6564676572",
            writeUUID: "13d63400-2c97-9004-0002-4c6564676572",
            writeCmdUUID: "13d63400-2c97-9004-0003-4c6564676572"
        )
    ]

    /// The service with this UUID, compared case-insensitively.
    static func service(uuid: String) -> LedgerBluetoothService? {
        all.first { $0.serviceUUID.caseInsensitiveCompare(uuid) == .orderedSame }
    }
}
