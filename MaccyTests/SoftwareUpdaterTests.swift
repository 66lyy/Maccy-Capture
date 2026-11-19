import Foundation
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct SoftwareUpdaterTests {
  private let feed = RepositoryUpdateFeed(repository: "fixture/capture")
  private let fixtureToken = String(repeating: "x", count: 40)

  @Test("Update discovery uses only the pinned GitHub API without profile or cookie data")
  func requestPrivacy() {
    let request = feed.request(token: fixtureToken)
    #expect(request.url?.absoluteString == "https://api.github.com/repos/fixture/capture/releases/tags/capture-latest")
    #expect(request.url?.query == nil)
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixtureToken)")
    #expect(feed.request(token: nil).value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test("A rolling prerelease resolves its exact feed and allowed archive assets")
  func validRelease() throws {
    let resolved = try feed.resolve(data: releaseData(), response: response())
    #expect(resolved.feedURL.absoluteString == assetURL(10))
    #expect(resolved.permits(URL(string: assetURL(11)), length: 200))
    #expect(!resolved.permits(URL(string: assetURL(11)), length: 199))
    #expect(!resolved.permits(URL(string: assetURL(12)), length: 200))
    #expect(!resolved.permits(nil, length: 200))
  }

  @Test("Unauthorized, expired and unavailable private repository access has an explicit result")
  func privateAccessFailures() {
    for status in [401, 403, 404] {
      #expect(throws: RepositoryUpdateFeed.Failure.self) {
        _ = try feed.resolve(data: Data(), response: response(status))
      }
    }
  }

  @Test("Wrong tags, drafts, missing feeds and duplicate assets are rejected")
  func malformedReleases() throws {
    let variants: [[String: Any]] = [
      ["tag_name": "upstream-latest"],
      ["draft": true],
      ["assets": []],
      ["assets": [asset(10, "capture-appcast.xml", 100), asset(10, "capture-appcast.xml", 100)]],
      ["assets": [asset(10, "capture-appcast.xml", 1_000_001), asset(11, packageName, 200)]]
    ]
    for override in variants {
      #expect(throws: RepositoryUpdateFeed.Failure.self) {
        _ = try feed.resolve(data: releaseData(override), response: response())
      }
    }
  }

  @Test("Credentials cannot be redirected by a release to another repository, host or scheme")
  func rejectsForeignAssets() throws {
    for url in [
      "http://api.github.com/repos/fixture/capture/releases/assets/10",
      "https://api.github.com.evil.invalid/repos/fixture/capture/releases/assets/10",
      "https://api.github.com/repos/other/project/releases/assets/10",
      "https://api.github.com/repos/fixture/capture/releases/assets/10?token=fixture",
      "https://fixture@api.github.com/repos/fixture/capture/releases/assets/10",
      "https://api.github.com:444/repos/fixture/capture/releases/assets/10"
    ] {
      var invalid = asset(10, "capture-appcast.xml", 100)
      invalid["url"] = url
      #expect(throws: RepositoryUpdateFeed.Failure.self) {
        _ = try feed.resolve(
          data: releaseData(["assets": [invalid, asset(11, packageName, 200)]]), response: response()
        )
      }
    }
    #expect(throws: RepositoryUpdateFeed.Failure.self) {
      let foreign = HTTPURLResponse(
        url: URL(string: "https://fixture.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil
      )!
      _ = try feed.resolve(data: releaseData(), response: foreign)
    }
  }

  @Test("Update preferences are local and test construction never reads Keychain or starts networking")
  func isolatedPreferences() throws {
    let domain = "local.maccy.updates.fixture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    var secret: String?
    var reads = 0
    var requests = 0
    let updater = SoftwareUpdater(
      defaults: defaults,
      readCredential: { _ in reads += 1; return secret },
      writeCredential: { secret = $0 },
      removeCredential: { secret = nil },
      load: { _ in requests += 1; throw RepositoryUpdateFeed.Failure.network }
    )
    #expect(updater.automaticallyChecksForUpdates)
    updater.start()
    updater.checkForUpdates()
    #expect(reads == 0)
    #expect(requests == 0)
    updater.automaticallyChecksForUpdates = false
    #expect(defaults.bool(forKey: SoftwareUpdater.automaticChecksKey) == false)
    #expect(updater.saveAccessToken(" \(fixtureToken)\n"))
    #expect(secret == fixtureToken)
    #expect(updater.hasCredential)
    #expect(defaults.string(forKey: "token") == nil)
    updater.clearAccessToken()
    #expect(secret == nil)
    #expect(!updater.hasCredential)
    #expect(!updater.saveAccessToken("bad\nheader"))
    #expect(secret == nil)
    updater.stop()
  }

  @Test("Repository discovery never follows a redirect with credentials")
  func refusesRedirects() async {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: feed.request(token: fixtureToken))
    let response = HTTPURLResponse(
      url: feed.releaseURL, statusCode: 302, httpVersion: nil,
      headerFields: ["Location": "https://fixture.invalid"]
    )!
    let redirected: URLRequest? = await withCheckedContinuation { continuation in
      RepositoryUpdateSession().urlSession(
        session, task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: URL(string: "https://fixture.invalid")!)
      ) {
        continuation.resume(returning: $0)
      }
    }
    #expect(redirected == nil)
    task.cancel()
  }

  @Test("Unsafe header credentials are rejected without writing any secret")
  func credentialValidation() {
    #expect(RepositoryUpdateCredential.valid(fixtureToken))
    for token in ["", "short", String(repeating: "x", count: 513), "\(fixtureToken)\r\nInjected: true"] {
      #expect(!RepositoryUpdateCredential.valid(token))
    }
  }

  @Test("Keychain failures are generic and do not echo the credential")
  func credentialFailure() throws {
    let domain = "local.maccy.updates.fixture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let updater = SoftwareUpdater(defaults: defaults, writeCredential: { _ in
      throw RepositoryUpdateCredential.Failure.keychain
    })
    #expect(!updater.saveAccessToken(fixtureToken))
    #expect(updater.statusKey == "UpdateCredentialFailed")
    #expect(!updater.hasCredential)
  }

  private var packageName: String { "Maccy-Capture-2.8.0-abcdef123456-universal.zip" }

  private func assetURL(_ identifier: Int) -> String {
    "https://api.github.com/repos/fixture/capture/releases/assets/\(identifier)"
  }

  private func asset(_ identifier: Int, _ name: String, _ size: Int) -> [String: Any] {
    ["id": identifier, "name": name, "size": size, "url": assetURL(identifier)]
  }

  private func releaseData(_ override: [String: Any] = [:]) throws -> Data {
    let release: [String: Any] = [
      "tag_name": "capture-latest", "draft": false, "prerelease": true,
      "assets": [asset(10, "capture-appcast.xml", 100), asset(11, packageName, 200)]
    ]
    return try JSONSerialization.data(withJSONObject: release.merging(override) { _, value in value })
  }

  private func response(_ status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: feed.releaseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
  }
}
