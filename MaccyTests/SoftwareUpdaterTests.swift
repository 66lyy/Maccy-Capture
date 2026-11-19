import Foundation
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct SoftwareUpdaterTests {
  private let feed = RepositoryUpdateFeed(repository: "fixture/capture")

  @Test("Update discovery uses the pinned GitHub API without credentials, profile data or cookies")
  func requestPrivacy() {
    let request = feed.request()
    #expect(request.url?.absoluteString == "https://api.github.com/repos/fixture/capture/releases/latest")
    #expect(request.url?.query == nil)
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(!request.httpShouldHandleCookies)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test("A stable release resolves its tagged feed and allowed archive assets")
  func validRelease() throws {
    let resolved = try feed.resolve(data: releaseData(), response: response())
    #expect(resolved.feedURL.absoluteString ==
      "https://github.com/fixture/capture/releases/download/maccy-capture-v2.8.0/capture-appcast.xml?asset=10")
    #expect(resolved.permits(URL(string: assetURL(11)), length: 200))
    #expect(!resolved.permits(URL(string: assetURL(11)), length: 199))
    #expect(!resolved.permits(URL(string: assetURL(12)), length: 200))
    #expect(!resolved.permits(nil, length: 200))
  }

  @Test("Preview releases are only accepted on the preview channel")
  func previewRelease() throws {
    let preview = RepositoryUpdateFeed(repository: "fixture/capture", channel: .preview)
    let previewURL = try #require(preview.request().url)
    #expect(previewURL.absoluteString == "https://api.github.com/repos/fixture/capture/releases/tags/capture-latest")
    let previewResponse = try #require(HTTPURLResponse(
      url: previewURL, statusCode: 200, httpVersion: nil, headerFields: nil
    ))
    let data = try releaseData(["tag_name": "capture-latest", "prerelease": true])
    let resolved = try preview.resolve(data: data, response: previewResponse)
    #expect(resolved.feedURL.absoluteString ==
      "https://github.com/fixture/capture/releases/download/capture-latest/capture-appcast.xml?asset=10")
    #expect(throws: RepositoryUpdateFeed.Failure.invalidRelease) {
      _ = try feed.resolve(data: data, response: response())
    }
    #expect(throws: RepositoryUpdateFeed.Failure.invalidRelease) {
      _ = try preview.resolve(data: releaseData(), response: previewResponse)
    }
  }

  @Test("Replacing the appcast changes its download URL")
  func replacedAppcast() throws {
    let nextFeed = try feed.resolve(
      data: releaseData(["assets": [asset(20, "capture-appcast.xml", 100), asset(11, packageName, 200)]]),
      response: response()
    )
    #expect(nextFeed.feedURL.query == "asset=20")
  }

  @Test("Failed release discovery reports update unavailability")
  func unavailableRelease() {
    for status in [401, 403, 404, 429, 500] {
      #expect(throws: RepositoryUpdateFeed.Failure.unavailable) {
        _ = try feed.resolve(data: Data(), response: response(status))
      }
    }
  }

  @Test("Wrong tags, drafts, missing feeds and duplicate assets are rejected")
  func malformedReleases() throws {
    let variants: [[String: Any]] = [
      ["tag_name": "upstream-latest"],
      ["tag_name": "maccy-capture-v2.8.0/../capture-latest"],
      ["tag_name": "maccy-capture-v2.8.0\n"],
      ["tag_name": "capture-latest"],
      ["prerelease": true],
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

  @Test("Release assets must belong to the configured repository and use the exact API URLs")
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

  @Test("Startup checks default to enabled, respect local preferences, and stay offline during tests")
  func isolatedPreferences() throws {
    let domain = "local.maccy.updates.fixture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let updater = SoftwareUpdater(
      defaults: defaults,
      load: { _ in
        Issue.record("Tests must not request update metadata")
        throw URLError(.notConnectedToInternet)
      }
    )
    #expect(updater.automaticallyChecksForUpdates)
    #expect(updater.channel == .stable)
    updater.channel = .preview
    #expect(SoftwareUpdater(defaults: defaults).channel == .preview)
    defaults.set("unknown", forKey: SoftwareUpdater.channelKey)
    #expect(SoftwareUpdater(defaults: defaults).channel == .stable)
    updater.start()
    updater.checkForUpdates()
    #expect(!updater.isChecking)
    updater.automaticallyChecksForUpdates = false
    #expect(defaults.bool(forKey: SoftwareUpdater.automaticChecksKey) == false)
    #expect(!SoftwareUpdater(defaults: defaults).automaticallyChecksForUpdates)
    updater.stop()
  }

  @Test("Release discovery never follows a redirect")
  func refusesRedirects() async {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: feed.request())
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

  private var packageName: String { "Maccy-Capture-2.8.0-abcdef123456-universal.zip" }

  private func assetURL(_ identifier: Int) -> String {
    "https://api.github.com/repos/fixture/capture/releases/assets/\(identifier)"
  }

  private func asset(_ identifier: Int, _ name: String, _ size: Int) -> [String: Any] {
    ["id": identifier, "name": name, "size": size, "url": assetURL(identifier)]
  }

  private func releaseData(_ override: [String: Any] = [:]) throws -> Data {
    let release: [String: Any] = [
      "tag_name": "maccy-capture-v2.8.0", "draft": false, "prerelease": false,
      "assets": [asset(10, "capture-appcast.xml", 100), asset(11, packageName, 200)]
    ]
    return try JSONSerialization.data(withJSONObject: release.merging(override) { _, value in value })
  }

  private func response(_ status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: feed.releaseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
  }
}
