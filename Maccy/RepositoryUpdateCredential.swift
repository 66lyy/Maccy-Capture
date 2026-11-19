import Foundation
import LocalAuthentication
import Security

nonisolated enum RepositoryUpdateCredential {
  private static let service = "local.maccy.capture.repository-updates"

  static func read(allowInteraction: Bool = false) throws -> String? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = !allowInteraction
    query[kSecUseAuthenticationContext] = context
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
          let token = String(data: data, encoding: .utf8) else {
      throw Failure.keychain
    }
    return token
  }

  static func write(_ value: String) throws {
    let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard valid(token) else { throw Failure.invalidToken }
    let attributes: [CFString: Any] = [kSecValueData: Data(token.utf8)]
    let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var query = baseQuery.merging(attributes) { _, value in value }
      query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw Failure.keychain }
    } else if status != errSecSuccess {
      throw Failure.keychain
    }
  }

  static func remove() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain }
  }

  static func valid(_ token: String) -> Bool {
    (20...512).contains(token.utf8.count) &&
      token.utf8.allSatisfy { (33...126).contains($0) }
  }

  enum Failure: Error {
    case keychain, invalidToken
  }

  private static var baseQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: RepositoryUpdateFeed.repository,
      kSecAttrSynchronizable: false
    ]
  }
}
