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

  @Test("Preview selects the first complete stable or test release in API order")
  func previewRelease() throws {
    let preview = RepositoryUpdateFeed(repository: "fixture/capture", channel: .preview)
    #expect(preview.request().url?.absoluteString ==
      "https://api.github.com/repos/fixture/capture/releases?per_page=10")
    let previewResponse = try #require(HTTPURLResponse(
      url: preview.releaseURL, statusCode: 200, httpVersion: nil, headerFields: nil
    ))
    func releases(_ overrides: [[String: Any]]) throws -> Data {
      let objects = try overrides.map {
        try JSONSerialization.jsonObject(with: releaseData($0))
      }
      return try JSONSerialization.data(withJSONObject: objects)
    }
    let test: [String: Any] = ["tag_name": "maccy-capture-v2.8.1-build1042.1", "prerelease": true]
    let skipped: [[String: Any]] = [
      ["draft": true],
      ["tag_name": "capture-latest", "prerelease": true],
      ["tag_name": "maccy-capture-v2.8.1-build1042.1.2.3", "prerelease": true],
      ["assets": []],
      ["assets": [asset(11, packageName, 200)]],
      ["assets": [asset(10, "capture-appcast.xml", 100), asset(11, packageName, 0)]],
      ["assets": [asset(10, "capture-appcast.xml", 100, state: "starter"), asset(11, packageName, 200)]],
      ["assets": [asset(10, "capture-appcast.xml", 100), asset(12, "capture-appcast.xml", 100),
                  asset(11, packageName, 200)]]
    ]
    let resolved = try preview.resolve(data: releases(skipped + [test, [:]]), response: previewResponse)
    #expect(resolved.feedURL.absoluteString ==
      "https://github.com/fixture/capture/releases/download/maccy-capture-v2.8.1-build1042.1/capture-appcast.xml?asset=10")
    #expect(resolved.permits(URL(string: assetURL(11)), length: 200))
    let stable = try preview.resolve(data: releases([[:], test]), response: previewResponse)
    #expect(stable.feedURL.path.contains("maccy-capture-v2.8.0/"))
    for overrides in [[], skipped] {
      #expect(throws: RepositoryUpdateFeed.Failure.unavailable) {
        _ = try preview.resolve(data: releases(overrides), response: previewResponse)
      }
    }
    for data in [Data("{}".utf8), Data("invalid".utf8), Data(repeating: 32, count: 2_000_001)] {
      #expect(throws: RepositoryUpdateFeed.Failure.invalidRelease) {
        _ = try preview.resolve(data: data, response: previewResponse)
      }
    }
    #expect(throws: RepositoryUpdateFeed.Failure.invalidRelease) {
      _ = try feed.resolve(data: releaseData(test), response: response())
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

  @Test("Automatic checks run at launch and repeat after the daily interval")
  func recurringAutomaticChecks() async throws {
    let clock = CheckClock()
    var requests: [URLRequest] = []
    let updater = try makeUpdater(clock: clock) { request in
      requests.append(request)
      throw RepositoryUpdateFeed.Failure.unavailable
    }
    defer { updater.stop() }

    updater.start()
    #expect(updater.isChecking)
    updater.start()
    try await waitUntil { clock.delays.count == 1 }
    #expect(requests.map(\.url) == [RepositoryUpdateFeed().releaseURL])
    #expect(clock.delays == [.seconds(86_400)])

    updater.channel = .preview
    clock.advance()
    try await waitUntil { clock.delays.count == 2 }
    #expect(requests.map(\.url) == [
      RepositoryUpdateFeed().releaseURL, RepositoryUpdateFeed(channel: .preview).releaseURL
    ])

    updater.stop()
    #expect(clock.advance() == false)
    #expect(requests.count == 2)
  }

  @Test("Opting in checks immediately and opting out cancels the next check")
  func togglingAutomaticChecks() async throws {
    let clock = CheckClock()
    var requests = 0
    let updater = try makeUpdater(clock: clock, enabled: false) { _ in
      requests += 1
      throw RepositoryUpdateFeed.Failure.unavailable
    }
    defer { updater.stop() }

    updater.start()
    #expect(!updater.isChecking)
    #expect(clock.delays.isEmpty)
    updater.automaticallyChecksForUpdates = true
    #expect(updater.isChecking)
    try await waitUntil { clock.delays.count == 1 }
    #expect(requests == 1)

    updater.automaticallyChecksForUpdates = false
    #expect(clock.advance() == false)
    #expect(requests == 1)
  }

  @Test("Opting out cancels automatic discovery without affecting manual checks")
  func cancelsAutomaticDiscovery() async throws {
    let clock = CheckClock()
    let (response, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    var requests = 0
    var isCapturing = false
    let updater = try makeUpdater(clock: clock, hasActiveCapture: { isCapturing }) { _ in
      requests += 1
      if requests == 1 {
        for await _ in response { break }
      }
      throw URLError(.cancelled)
    }
    defer { updater.stop() }

    updater.start()
    try await waitUntil { requests == 1 }
    updater.automaticallyChecksForUpdates = false
    try await waitUntil { !updater.isChecking }
    #expect(updater.statusKey == "UpdateReady")
    #expect(clock.delays.isEmpty)

    isCapturing = true
    updater.checkForUpdates()
    try await waitUntil { !updater.isChecking }
    #expect(requests == 2)
    #expect(clock.delays.isEmpty)
  }

  @Test("An automatic check waits for capture to end, then resumes its daily schedule")
  func captureDeferral() async throws {
    let clock = CheckClock()
    var isCapturing = true
    var requests = 0
    let updater = try makeUpdater(clock: clock, hasActiveCapture: { isCapturing }) { _ in
      requests += 1
      throw RepositoryUpdateFeed.Failure.unavailable
    }
    defer { updater.stop() }

    updater.start()
    try await waitUntil { clock.delays.count == 1 }
    clock.advance()
    try await waitUntil { clock.delays.count == 2 }
    #expect(requests == 0)
    #expect(!updater.isChecking)
    #expect(clock.delays == [.seconds(30), .seconds(30)])

    isCapturing = false
    clock.advance()
    try await waitUntil { clock.delays.count == 3 }
    #expect(requests == 1)
    #expect(clock.delays.last == .seconds(86_400))
  }

  @Test("Capture starting during discovery defers the automatic check and retries")
  func captureStartsDuringDiscovery() async throws {
    let clock = CheckClock()
    var isCapturing = false
    var requests = 0
    let updater = try makeUpdater(clock: clock, hasActiveCapture: { isCapturing }) { request in
      requests += 1
      if requests == 1 { isCapturing = true }
      let url = try #require(request.url)
      let response = try #require(HTTPURLResponse(
        url: url, statusCode: 404, httpVersion: nil, headerFields: nil
      ))
      return (Data(), response)
    }
    defer { updater.stop() }

    updater.start()
    try await waitUntil { clock.delays.count == 1 }
    #expect(updater.statusKey == "UpdateReady")
    #expect(clock.delays == [.seconds(30)])

    isCapturing = false
    clock.advance()
    try await waitUntil { clock.delays.count == 2 }
    #expect(requests == 2)
    #expect(updater.statusKey == "UpdateReleaseUnavailable")
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

  private func makeUpdater(
    clock: CheckClock, enabled: Bool = true, hasActiveCapture: @escaping () -> Bool = { false },
    load: @escaping (URLRequest) async throws -> (Data, URLResponse)
  ) throws -> SoftwareUpdater {
    let defaults = try #require(UserDefaults(suiteName: "local.maccy.updates.clock.\(UUID().uuidString)"))
    defaults.register(defaults: [SoftwareUpdater.automaticChecksKey: enabled])
    return SoftwareUpdater(
      defaults: defaults, load: load, canCheck: { true }, hasActiveCapture: hasActiveCapture, sleep: clock.sleep
    )
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
  }

  @MainActor
  private final class CheckClock {
    private(set) var delays: [Duration] = []
    private var ticks: [AsyncStream<Void>.Continuation] = []

    func sleep(_ delay: Duration) async throws {
      let (stream, continuation) = AsyncStream<Void>.makeStream()
      delays.append(delay)
      ticks.append(continuation)
      for await _ in stream { break }
      try Task.checkCancellation()
    }

    @discardableResult
    func advance() -> Bool {
      let tick = ticks.removeFirst()
      let result = tick.yield(())
      tick.finish()
      if case .terminated = result { return false }
      return true
    }
  }

  private func assetURL(_ identifier: Int) -> String {
    "https://api.github.com/repos/fixture/capture/releases/assets/\(identifier)"
  }

  private func asset(_ identifier: Int, _ name: String, _ size: Int, state: String = "uploaded") -> [String: Any] {
    [
      "id": identifier, "name": name, "size": size, "url": assetURL(identifier),
      "state": state, "created_at": "2026-11-20T02:07:00Z"
    ]
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
