import CryptoKit
import Foundation

enum VerificationFailure: Error {
  case invalidArguments, invalidSignature
}
do {
  guard CommandLine.arguments.count == 4,
        let publicKeyData = Data(base64Encoded: CommandLine.arguments[1]),
        let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    throw VerificationFailure.invalidArguments
  }
  let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
  let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
  guard key.isValidSignature(signature, for: archive) else {
    throw VerificationFailure.invalidSignature
  }
  print("Verified update archive against the pinned public key")
} catch {
  FileHandle.standardError.write(Data("Update archive signature verification failed.\n".utf8))
  exit(1)
}
