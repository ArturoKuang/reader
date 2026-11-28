#!/usr/bin/env swift
import CryptoKit
import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case missingKey
    case invalidKey
    case invalidSignature
    case verificationFailed

    var description: String {
        switch self {
        case .usage(let msg): return msg
        case .missingKey: return "READER_UPDATE_SIGNING_KEY environment variable is required."
        case .invalidKey: return "Invalid base64 Ed25519 key."
        case .invalidSignature: return "Invalid base64 Ed25519 signature."
        case .verificationFailed: return "Ed25519 signature verification failed."
        }
    }
}

func argValue(_ flag: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--keygen") {
        let priv = Curve25519.Signing.PrivateKey()
        print("PRIVATE_KEY_B64=\(priv.rawRepresentation.base64EncodedString())")
        print("PUBLIC_KEY_B64=\(priv.publicKey.rawRepresentation.base64EncodedString())")
        exit(0)
    }

    if args.contains("--verify") {
        guard let manifestPath = argValue("--manifest", in: args),
              let sigPath = argValue("--signature", in: args),
              let pubB64 = argValue("--public-key", in: args) else {
            throw CLIError.usage("Usage: sign-manifest.swift --verify --manifest <file> --signature <file> --public-key <base64>")
        }
        guard let pubData = Data(base64Encoded: pubB64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else {
            throw CLIError.invalidKey
        }
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let sigString = try String(contentsOfFile: sigPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sigData = Data(base64Encoded: sigString) else {
            throw CLIError.invalidSignature
        }
        guard pubKey.isValidSignature(sigData, for: manifestData) else {
            throw CLIError.verificationFailed
        }
        print("Verified \(manifestPath)")
        exit(0)
    }

    guard let manifestPath = argValue("--manifest", in: args),
          let outputPath = argValue("--output", in: args) else {
        throw CLIError.usage("Usage: sign-manifest.swift --manifest <file> --output <file>")
    }
    guard let privB64 = ProcessInfo.processInfo.environment["READER_UPDATE_SIGNING_KEY"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !privB64.isEmpty else {
        throw CLIError.missingKey
    }
    guard let privData = Data(base64Encoded: privB64),
          let privKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) else {
        throw CLIError.invalidKey
    }
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    let signature = try privKey.signature(for: manifestData)
    let encoded = signature.base64EncodedString() + "\n"
    try encoded.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("Signed \(manifestPath) -> \(outputPath)")
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
