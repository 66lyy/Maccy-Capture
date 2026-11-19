import CryptoKit
import Foundation
import SwiftData

@Model
class HistoryItemContent {
  private struct Fingerprint {
    let type: String
    let value: Data?
    let digest: Data
  }

  var type: String = ""
  var value: Data?

  @Transient private var cachedFingerprint: Fingerprint?

  var fingerprint: Data {
    let type = type
    let value = value
    if let cachedFingerprint, cachedFingerprint.type == type, cachedFingerprint.value == value {
      return cachedFingerprint.digest
    }
    var digest = SHA256()
    digest.update(data: Data(SHA256.hash(data: Data(type.utf8))))
    digest.update(data: Data([value == nil ? 0 : 1]))
    if let value { digest.update(data: value) }
    let fingerprint = Data(digest.finalize())
    cachedFingerprint = Fingerprint(type: type, value: value, digest: fingerprint)
    return fingerprint
  }

  @Relationship
  var item: HistoryItem?

  init(type: String, value: Data? = nil) {
    self.type = type
    self.value = value
  }
}
