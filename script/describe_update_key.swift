import CryptoKit
import Foundation

// Reads a Sparkle EdDSA private key from standard input and prints only its public key.
let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  .trimmingCharacters(in: .whitespacesAndNewlines)
func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("SPARKLE_PRIVATE_KEY: \(message)\n".utf8))
  exit(1)
}
guard let keyData = Data(base64Encoded: input) else {
  fail("\(input.count) characters, not valid Base64; expected the Base64 key printed by `generate_keys -x`.")
}
switch keyData.count {
case 32:
  guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    fail("32 bytes but not a usable Ed25519 private key.")
  }
  print(key.publicKey.rawRepresentation.base64EncodedString())
case 96:
  print(keyData.suffix(32).base64EncodedString())
default:
  fail("\(input.count) characters decoding to \(keyData.count) bytes; a Sparkle private key is 32 bytes (or 96 in the legacy format).")
}
