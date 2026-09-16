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
        let resultURL = try await downloadFileWithRequestWithContinuation(sourceURL, logger: logger, at: at, torClient: torClient)
        try isSpendParamsSHA1Valid(url: resultURL)
        return resultURL
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
        let resultURL = try await downloadFileWithRequestWithContinuation(sourceURL, logger: logger, at: at, torClient: torClient)
        try isOutputParamsSHA1Valid(url: resultURL)
        return resultURL
    }

    /// Downloads the parameters if not present and provides the resulting URLs for both parameters
    /// - Parameters:
    ///     - spendURL: URL to check whether the parameter is already downloaded
    ///     - outputURL: URL to check whether the parameter is already downloaded
    ///     - torClient: Optional TorClient for downloading over Tor. If nil, uses direct HTTPS.
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
        torClient: TorClient? = nil
    ) async throws -> (spend: URL, output: URL) {
        if retryEnabled {
            var retryAttempts = 3

            while retryAttempts > 0 {
                do {
                    async let spendResultURL = ensureSpendParameter(at: spendURL, sourceURL: spendSourceURL, logger: logger, torClient: torClient)
                    async let outputResultURL = ensureOutputParameter(at: outputURL, sourceURL: outputSourceURL, logger: logger, torClient: torClient)

                    let results = try await [spendResultURL, outputResultURL]
                    return (spend: results[0], output: results[1])
                } catch {
                    retryAttempts -= 1
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
        }

        async let spendResultURL = ensureSpendParameter(at: spendURL, sourceURL: spendSourceURL, logger: logger, torClient: torClient)
        async let outputResultURL = ensureOutputParameter(at: outputURL, sourceURL: outputSourceURL, logger: logger, torClient: torClient)

        let results = try await [spendResultURL, outputResultURL]
        return (spend: results[0], output: results[1])
    }

    static func ensureSpendParameter(at url: URL, sourceURL: URL, logger: Logger, torClient: TorClient? = nil) async throws -> URL {
        if isFilePresent(url: url) {
            try isSpendParamsSHA1Valid(url: url)
            return url
        } else {
            return try await downloadSpendParameter(url, sourceURL: sourceURL, logger: logger, torClient: torClient)
        }
    }

    static func ensureOutputParameter(at url: URL, sourceURL: URL, logger: Logger, torClient: TorClient? = nil) async throws -> URL {
        if isFilePresent(url: url) {
            try isOutputParamsSHA1Valid(url: url)
            return url
        } else {
            return try await downloadOutputParameter(url, sourceURL: sourceURL, logger: logger, torClient: torClient)
        }
    }

    static func isFilePresent(url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func isSpendParamsSHA1Valid(url: URL) throws {
        if Insecure.SHA1.hash(data: try Data(contentsOf: url)).hexString != Constants.spendParamFileSHA1 {
            try? FileManager.default.removeItem(at: url)
            throw ZcashError.saplingParamsInvalidSpendParams
        }
    }

    static func isOutputParamsSHA1Valid(url: URL) throws {
        if Insecure.SHA1.hash(data: try Data(contentsOf: url)).hexString != Constants.outputParamFileSHA1 {
            try? FileManager.default.removeItem(at: url)
            throw ZcashError.saplingParamsInvalidOutputParams
        }
    }
}

private extension SaplingParameterDownloader {
    enum Constants {
        public static let spendParamFileSHA1 = "a15ab54c2888880e53c823a3063820c728444126"
        public static let outputParamFileSHA1 = "0ebc5a1ef3653948e1c46cf7a16071eac4b7e352"
    }

    static func downloadFileWithRequestWithContinuation(
    _ sourceURL: URL,
    logger: Logger,
    at destination: URL,
    torClient: TorClient? = nil
    ) async throws -> URL {
        if let torClient = torClient {
            return try await downloadFileWithTor(sourceURL, at: destination, logger: logger, torClient: torClient)
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                downloadFileWithRequest(sourceURL, at: destination, logger: logger) { result in
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
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: localUrl)
                    result(.success(destination))
                } catch {
                    result(.failure(ZcashError.saplingParamsCantMoveDownloadedFile(error, sourceURL, destination)))
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
        torClient: TorClient
    ) async throws -> URL {
        logger.debug("Downloading sapling file from \(sourceURL) via Tor")

        let request = URLRequest(url: sourceURL)
        let (data, response) = try torClient.httpRequest(for: request, retryLimit: 2)

        guard response.statusCode == 200 else {
            throw ZcashError.saplingParamsDownload(
                NSError(domain: "TorDownload", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode)"]),
                sourceURL
            )
        }

        // Write data to a temp file first, then move to destination
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)

        do {
            try data.write(to: tempFile, options: .atomic)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempFile)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            throw ZcashError.saplingParamsCantMoveDownloadedFile(error, sourceURL, destination)
        }
    }
}
