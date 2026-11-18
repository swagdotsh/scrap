import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let keyData = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let contents = try? Data(contentsOf: URL(fileURLWithPath: arguments[3])) else {
    FileHandle.standardError.write(Data("Usage: verify-ed-signature.swift <public-key> <signature> <file>\n".utf8))
    exit(2)
}
exit(key.isValidSignature(signature, for: contents) ? 0 : 1)
