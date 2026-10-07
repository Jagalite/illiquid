import CryptoKit
import Foundation

// Verify against the public key embedded in the shipped app, not merely the
// private key supplied to CI. A mismatched CI key must never publish a feed.
let arguments = CommandLine.arguments
 guard arguments.count == 4,
       let signature = Data(base64Encoded: arguments[2]),
       let publicBytes = Data(base64Encoded: arguments[3]) else {
    fatalError("Usage: verify-update-signature.swift ARCHIVE SIGNATURE PUBLIC_KEY")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("Update signature does not match the app's public key.\n", stderr)
    exit(1)
}
print("Update archive signature matches the app's public key")
