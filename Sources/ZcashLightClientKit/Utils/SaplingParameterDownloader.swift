//
//  SaplingParameterDownloader.swift
//  ZcashLightClientKit
//
//  Created by Francisco Gindre on 10/7/20.
//

import Foundation
import CryptoKit

/// Small utility that converts Digest to the String
extension Digest {
    var bytes: [UInt8] { Array(makeIterator()) }
    var data: Data { Data(bytes) }

    var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Helper class to handle the download of Sapling parameters
public enum SaplingParameterDownloader {
    /// Download a Spend parameter from default host and stores it at given URL
    /// - Parameters:
    ///     - at: The destination URL for the download
    ///     - torClient: Optional TorClient for downloading over Tor. If nil, uses direct HTTPS.
    /// - Throws:
    ///     - `saplingParamsDownload` if file downloading fails.
    ///     - `saplingParamsCantMoveDownloadedFile` if file is downloaded but moving to final destination fails.
    ///     - `saplingParamsInvalidSpendParams` if the downloaded file is invalid.
    @discardableResult
    public static func downloadSpendParameter(_ at: URL, sourceURL: URL, logger: Logger, torClient: TorClient? = nil) async throws -> URL {
        return try await downloadFileWithRequestWithContinuation(
            sourceURL,
            logger: logger,
            at: at,
            torClient: torClient,
            validator: isSpendParamsSHA256Valid
        )
    }

    /// Download an Output parameter from default host and stores it at given URL
    /// - Parameters:
    ///     - at: The destination URL for the download
    ///     - torClient: Optional TorClient for downloading over Tor. If nil, uses direct HTTPS.
    /// - Throws:
    ///     - `saplingParamsDownload` if file downloading fails.
    ///     - `saplingParamsCantMoveDownloadedFile` if file is downloaded but moving to final destination fails.
    ///     - `saplingParamsInvalidOutputParams` if the downloaded file is invalid.
    @discardableResult
    public static func downloadOutputParameter(_ at: URL, sourceURL: URL, logger: Logger, torClient: TorClient? = nil) async throws -> URL {
        return try await downloadFileWithRequestWithContinuation(
            sourceURL,
            logger: logger,
            at: at,
            torClient: torClient,
            validator: isOutputParamsSHA256Valid
        )
    }

    /// Downloads the parameters if not present and provides the resulting URLs for both parameters
    /// - Parameters:
    ///     - spendURL: URL to check whether the parameter is already downloaded
    ///     - outputURL: URL to check whether the parameter is already downloaded
    ///     - torClientProvider: Closure that provides TorClient only when download is needed. If nil, uses direct HTTPS.
    ///       Never consulted for `file://` sources: those are local copies and Tor cannot fetch them.
    /// - Throws:
    ///     - `saplingParamsDownload` if file downloading fails.
    ///     - `saplingParamsCantMoveDownloadedFile` if file is downloaded but moving to final destination fails.
    ///     - `saplingParamsInvalidSpendParams` if the downloaded file is invalid.
    ///     - `saplingParamsInvalidOutputParams` if the downloaded file is invalid.
    @discardableResult
    public static func downloadParamsIfnotPresent(
        retryEnabled: Bool = false,
        spendURL: URL,
        spendSourceURL: URL,
        outputURL: URL,
        outputSourceURL: URL,
        logger: Logger,
        torClientProvider: (@Sendable () async -> TorClient?)? = nil
    ) async throws -> (spend: URL, output: URL) {
        if retryEnabled {
            var retryAttempts = 3

            while retryAttempts > 0 {
                do {
                    async let spendResultURL = ensureSpendParameter(at: spendURL, sourceURL: spendSourceURL, logger: logger, torClientProvider: torClientProvider)
                    async let outputResultURL = ensureOutputParameter(at: outputURL, sourceURL: outputSourceURL, logger: logger, torClientProvider: torClientProvider)

                    let results = try await [spendResultURL, outputResultURL]
                    return (spend: results[0], output: results[1])
                } catch {
                    retryAttempts -= 1
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
        }

        async let spendResultURL = ensureSpendParameter(at: spendURL, sourceURL: spendSourceURL, logger: logger, torClientProvider: torClientProvider)
        async let outputResultURL = ensureOutputParameter(at: outputURL, sourceURL: outputSourceURL, logger: logger, torClientProvider: torClientProvider)

        let results = try await [spendResultURL, outputResultURL]
        return (spend: results[0], output: results[1])
    }

    static func ensureSpendParameter(at url: URL, sourceURL: URL, logger: Logger, torClientProvider: (@Sendable () async -> TorClient?)? = nil) async throws -> URL {
        if isFilePresent(url: url) {
            try isSpendParamsSHA256Valid(url: url)
            return url
        } else {
            var torClient: TorClient?
            if !sourceURL.isFileURL {
                torClient = await torClientProvider?()
            }
            return try await downloadSpendParameter(url, sourceURL: sourceURL, logger: logger, torClient: torClient)
        }
    }

    static func ensureOutputParameter(at url: URL, sourceURL: URL, logger: Logger, torClientProvider: (@Sendable () async -> TorClient?)? = nil) async throws -> URL {
        if isFilePresent(url: url) {
            try isOutputParamsSHA256Valid(url: url)
            return url
        } else {
            var torClient: TorClient?
            if !sourceURL.isFileURL {
                torClient = await torClientProvider?()
            }
            return try await downloadOutputParameter(url, sourceURL: sourceURL, logger: logger, torClient: torClient)
        }
    }

    static func isFilePresent(url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func isSpendParamsSHA256Valid(url: URL) throws {
        if SHA256.hash(data: try Data(contentsOf: url)).hexString != Constants.spendParamFileSHA256 {
            try? FileManager.default.removeItem(at: url)
            throw ZcashError.saplingParamsInvalidSpendParams
        }
    }

    static func isOutputParamsSHA256Valid(url: URL) throws {
        if SHA256.hash(data: try Data(contentsOf: url)).hexString != Constants.outputParamFileSHA256 {
            try? FileManager.default.removeItem(at: url)
            throw ZcashError.saplingParamsInvalidOutputParams
        }
    }
}

private extension SaplingParameterDownloader {
    enum Constants {
        public static let spendParamFileSHA256 = "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13"
        public static let outputParamFileSHA256 = "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4"
    }

    static func downloadFileWithRequestWithContinuation(
    _ sourceURL: URL,
    logger: Logger,
    at destination: URL,
    torClient: TorClient? = nil,
    validator: @escaping (URL) throws -> Void
    ) async throws -> URL {
        if let torClient = torClient {
            return try await downloadFileWithTor(sourceURL, at: destination, logger: logger, torClient: torClient, validator: validator)
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                downloadFileWithRequest(sourceURL, at: destination, logger: logger, validator: validator) { result in
                    switch result {
                    case .success(let outputResultURL):
                        continuation.resume(returning: outputResultURL)
                    case .failure(let outputResultError):
                        continuation.resume(throwing: outputResultError)
                    }
                }
            }
        }
    }

    static func downloadFileWithRequest(
        _ sourceURL: URL,
        at destination: URL,
        logger: Logger,
        validator: @escaping (URL) throws -> Void,
        result: @escaping (Result<URL, Error>) -> Void
    ) {
        logger.debug("Downloading sapling file from \(sourceURL) via HTTPS")
        let request = URLRequest(url: sourceURL)
        let task = URLSession.shared.downloadTask(with: request) { url, _, error in
            if let error {
                result(.failure(ZcashError.saplingParamsDownload(error, sourceURL)))
                return
            } else if let localUrl = url {
                do {
                    // Validate BEFORE moving to destination (atomic: download → validate → move)
                    try validator(localUrl)
                    try safelyMoveItem(from: localUrl, to: destination)
                    result(.success(destination))
                } catch {
                    // Clean up temp file on validation or move failure
                    try? FileManager.default.removeItem(at: localUrl)
                    if error is ZcashError {
                        result(.failure(error))
                    } else {
                        result(.failure(ZcashError.saplingParamsCantMoveDownloadedFile(error, sourceURL, destination)))
                    }
                }
            }
        }

        task.resume()
    }

    /// Download a file over Tor using TorClient.
    /// Note: TorClient.httpRequest returns Data in memory (~47 MB for Sapling params).
    static func downloadFileWithTor(
        _ sourceURL: URL,
        at destination: URL,
        logger: Logger,
        torClient: TorClient,
        validator: @escaping (URL) throws -> Void
    ) async throws -> URL {
        logger.debug("Downloading sapling file from \(sourceURL) via Tor")

        let request = URLRequest(url: sourceURL)
        let (data, response) = try await torClient.httpRequest(for: request, retryLimit: 2)

        guard response.statusCode == 200 else {
            throw ZcashError.saplingParamsDownload(
                NSError(domain: "TorDownload", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode)"]),
                sourceURL
            )
        }

        // Write data to a temp file in the same directory as destination (atomic operations require same filesystem)
        let parentDir = destination.deletingLastPathComponent()
        let tempFile = parentDir.appendingPathComponent(UUID().uuidString)

        do {
            try data.write(to: tempFile, options: .atomic)
            // Validate BEFORE moving to destination (atomic: download → validate → move)
            try validator(tempFile)
            try safelyMoveItem(from: tempFile, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            if error is ZcashError {
                throw error
            } else {
                throw ZcashError.saplingParamsCantMoveDownloadedFile(error, sourceURL, destination)
            }
        }
    }

    /// Safely moves an item to a destination, handling both first-install (destination doesn't exist)
    /// and update (destination exists) scenarios atomically.
    static func safelyMoveItem(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let destinationExists = (try? fm.attributesOfItem(atPath: destination.path)) != nil

        if destinationExists {
            // Update scenario: use replaceItemAt for atomic replacement
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            // First-install scenario: ensure parent directory exists, then move
            let parentDir = destination.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
            try fm.moveItem(at: source, to: destination)
        }
    }
}
