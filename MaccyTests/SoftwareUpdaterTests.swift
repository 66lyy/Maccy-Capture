import Foundation
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct SoftwareUpdaterTests {
  private let feed = RepositoryUpdateFeed(repository: "fixture/capture")

  private let stableTag = "maccy-capture-v2.8.0"
  private let previewTag = "maccy-capture-v2.8.0-build1042.1"
  private let packageName = "Maccy-Capture-2.8.0-build1042.1-abcdef123456-universal.zip"

  @Test("Update discovery uses public GitHub routes without credentials, profile data or cookies")
  func requestPrivacy() {
    let preview = RepositoryUpdateFeed(repository: "fixture/capture", channel: .preview)
    let requests = [feed.request(), preview.request()]
    #expect(requests.compactMap { $0.url?.absoluteString } == [
      "https://github.com/fixture/capture/releases/latest",
      "https://github.com/fixture/capture/releases.atom"
    ])
    for request in requests {
      #expect(request.url?.query == nil)
      #expect(request.httpMethod == "GET")
      #expect(request.httpBody == nil)
      #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
      #expect(!request.httpShouldHandleCookies)
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
  }

  @Test("The stable redirect resolves a tag-pinned appcast and exact archive")
  func validRelease() async throws {
    let tags = try feed.releaseTags(data: Data(), response: response(location: tagURL(stableTag)))
    #expect(tags == [stableTag])
    let resolved = try await feed.resolve(tags: tags) { request in
      try self.assetResponse(request, tag: stableTag)
    }
    let appcast = browserURL(stableTag, "capture-appcast.xml")
    let archive = browserURL(stableTag, packageName)
    #expect(resolved.feedURL == appcast)
    #expect(resolved.downloadURL(for: archive, length: 200) == archive)
    #expect(resolved.downloadURL(for: archive, length: 199) == nil)
    #expect(resolved.downloadURL(for: browserURL(previewTag, packageName), length: 200) == nil)
    #expect(resolved.downloadURL(for: URL(string: "\(archive)?token=fixture"), length: 200) == nil)
    #expect(resolved.downloadURL(for: nil, length: 200) == nil)
  }

  @Test("The legacy enclosure is rewritten to the pinned browser ZIP before Sparkle downloads it")
  func rewritesLegacyEnclosure() async throws {
    let resolved = try await feed.resolve(tags: [stableTag]) { request in
      try assetResponse(request, tag: stableTag)
    }
    let legacy = try #require(URL(string: "https://api.github.com/repos/fixture/capture/releases/assets/11"))
    let archive = browserURL(stableTag, packageName)
    #expect(resolved.downloadURL(for: legacy, length: 200) == archive)
    let request = NSMutableURLRequest(url: legacy)
    resolved.configureDownload(request, enclosure: legacy, length: 200)
    #expect(request.url == archive)
    #expect(!request.httpShouldHandleCookies)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)

    for variant in [
      "https://api.github.com/repos/other/capture/releases/assets/11",
      "https://api.github.com.evil.invalid/repos/fixture/capture/releases/assets/11",
      "https://api.github.com/repos/fixture/capture/releases/assets/0",
      "\(legacy)?token=fixture"
    ] {
      let foreign = try #require(URL(string: variant))
      #expect(resolved.downloadURL(for: foreign, length: 200) == nil)
      let blocked = NSMutableURLRequest(url: foreign)
      resolved.configureDownload(blocked, enclosure: foreign, length: 200)
      #expect(blocked.url?.absoluteString == "about:blank")
    }
    let invalidRequests: [(URL, UInt64)] = [(legacy, 199), (archive, 200)]
    for (url, length) in invalidRequests {
      let blocked = NSMutableURLRequest(url: url)
      resolved.configureDownload(blocked, enclosure: legacy, length: length)
      #expect(blocked.url?.absoluteString == "about:blank")
    }
  }

  @Test("Preview selects the newest complete stable or test release from the Atom index")
  func previewRelease() async throws {
    let preview = RepositoryUpdateFeed(repository: "fixture/capture", channel: .preview)
    let newer = "maccy-capture-v2.8.1"
    let candidates = [
      (tagURL(stableTag), "2026-11-20T07:26:36Z"),
      (tagURL(previewTag), "2026-11-20T07:36:57Z"),
      (tagURL(newer), "2026-11-20T08:00:00Z"),
      (tagURL("capture-latest"), "2026-11-20T09:00:00Z"),
      (tagURL("maccy-capture-v2.8.1-build1042.1.2.3"), "2026-11-20T09:00:00Z"),
      ("https://github.com/other/capture/releases/tag/\(newer)", "2026-11-20T09:00:00Z"),
      (tagURL("maccy-capture-v2.8.2"), "invalid")
    ]
    let previewResponse = response(200, url: preview.releaseURL)
    for entries in [candidates, Array(candidates.reversed())] {
      let tags = try preview.releaseTags(data: atom(entries), response: previewResponse)
      #expect(tags == [newer, previewTag, stableTag])
      let resolved = try await preview.resolve(tags: tags) { request in
        if request.url == browserURL(newer, "UPDATE-METADATA.json") {
          return (Data(), response(404, url: request.url))
        }
        return try assetResponse(request, tag: previewTag)
      }
      #expect(resolved.feedURL == browserURL(previewTag, "capture-appcast.xml"))
      let archive = browserURL(previewTag, packageName)
      #expect(resolved.downloadURL(for: archive, length: 200) == archive)
    }
    let tags = try preview.releaseTags(data: atom([
      candidates[1], (tagURL(stableTag), "2026-11-20T09:00:00Z")
    ]), response: previewResponse)
    #expect(tags.first == stableTag)

    #expect(throws: RepositoryUpdateFeed.Failure.unavailable) {
      _ = try preview.releaseTags(data: atom([]), response: previewResponse)
    }
    for data in [Data("{}".utf8), Data("<feed/>".utf8), Data(repeating: 32, count: 2_000_001)] {
      #expect(throws: RepositoryUpdateFeed.Failure.invalidRelease) {
        _ = try preview.releaseTags(data: data, response: previewResponse)
      }
    }
  }

  @Test("Failed release discovery reports update unavailability")
  func unavailableRelease() {
    for status in [401, 403, 404, 429, 500] {
      #expect(throws: RepositoryUpdateFeed.Failure.unavailable) {
        _ = try feed.releaseTags(data: Data(), response: response(status))
      }
    }
  }

  @Test("The Stable redirect must point to a valid stable tag in the configured repository")
  func malformedReleases() {
    for location in [
      nil, tagURL("upstream-latest"), tagURL("capture-latest"), tagURL(previewTag),
      tagURL("\(stableTag)/../capture-latest"), tagURL("\(stableTag)%0A"),
      tagURL("\(stableTag)?token=fixture"), "https://github.com/other/project/releases/tag/\(stableTag)",
      "https://github.com.evil.invalid/fixture/capture/releases/tag/\(stableTag)",
      "https://fixture@github.com/fixture/capture/releases/tag/\(stableTag)",
      "https://github.com:444/fixture/capture/releases/tag/\(stableTag)",
      "http://github.com/fixture/capture/releases/tag/\(stableTag)"
    ] {
      #expect(throws: RepositoryUpdateFeed.Failure.invalidRelease) {
        _ = try feed.releaseTags(data: Data(), response: response(location: location))
      }
    }
    #expect(throws: RepositoryUpdateFeed.Failure.invalidRelease) {
      _ = try feed.releaseTags(data: Data(), response: response(url: URL(string: "https://fixture.invalid")))
    }
  }

  @Test("Tagged assets reject missing feeds, unexpected redirects and malformed archive metadata")
  func rejectsInvalidAssets() async throws {
    for status in [404, 403] {
      await #expect(throws: RepositoryUpdateFeed.Failure.unavailable) {
        _ = try await feed.resolve(tags: [stableTag]) { request in
          if request.httpMethod == "HEAD" { return (Data(), response(status, url: request.url)) }
          return try assetResponse(request, tag: stableTag)
        }
      }
    }
    for override: [String: Any] in [
      ["filename": "../\(packageName)"], ["length": 0], ["version": "1?fixture"],
      ["shortVersion": "2.8.1"], ["sourceRevision": "0123456789abcdef"]
    ] {
      await #expect(throws: RepositoryUpdateFeed.Failure.invalidRelease) {
        _ = try await feed.resolve(tags: [stableTag]) { request in
          try assetResponse(request, tag: stableTag, override: override)
        }
      }
    }
    for destination in ["https://fixture.invalid", "https://user@release-assets.githubusercontent.com"] {
      await #expect(throws: RepositoryUpdateFeed.Failure.invalidRelease) {
        _ = try await feed.resolve(tags: [stableTag]) { _ in
          (Data(), response(200, url: URL(string: destination)))
        }
      }
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

  @Test("Discovery inspects the Stable redirect and only follows tagged asset redirects to GitHub's CDN")
  func validatesRedirects() async {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let asset = browserURL(stableTag, "UPDATE-METADATA.json")
    let cdn = URL(string: "https://release-assets.githubusercontent.com/asset?credential=fixture")!
    func redirected(_ original: URLRequest, _ source: URL, _ target: URL) async -> URLRequest? {
      let task = session.dataTask(with: original)
      defer { task.cancel() }
      return await withCheckedContinuation { continuation in
        RepositoryUpdateSession().urlSession(
          session, task: task, willPerformHTTPRedirection: response(url: source),
          newRequest: URLRequest(url: target)
        ) {
          continuation.resume(returning: $0)
        }
      }
    }
    #expect(await redirected(feed.request(), feed.releaseURL, URL(string: tagURL(stableTag))!) == nil)
    #expect(await redirected(URLRequest(url: asset), asset, cdn)?.url == cdn)
    #expect(await redirected(URLRequest(url: asset), cdn, cdn) == nil)
    for foreign in ["http://release-assets.githubusercontent.com", "https://release-assets.githubusercontent.com.evil.invalid",
                    "https://api.github.com/repos/fixture/capture/releases/assets/9"] {
      #expect(await redirected(URLRequest(url: asset), asset, URL(string: foreign)!) == nil)
    }
  }

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

  private func tagURL(_ tag: String) -> String {
    "https://github.com/fixture/capture/releases/tag/\(tag)"
  }

  private func browserURL(_ tag: String, _ asset: String) -> URL {
    URL(string: "https://github.com/fixture/capture/releases/download/\(tag)/\(asset)")!
  }

  private func atom(_ entries: [(String, String)]) -> Data {
    let elements = entries.map { link, updated in
      """
      <entry><link rel="alternate" href="\(link)"/><updated>\(updated)</updated></entry>
      """
    }.joined()
    return Data("<feed xmlns=\"http://www.w3.org/2005/Atom\">\(elements)</feed>".utf8)
  }

  private func assetResponse(
    _ request: URLRequest, tag: String, override: [String: Any] = [:]
  ) throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    #expect(!request.httpShouldHandleCookies)
    if url == browserURL(tag, "capture-appcast.xml") {
      #expect(request.httpMethod == "HEAD")
      return (Data(), response(200, url: url, headers: ["Content-Length": "100"]))
    }
    #expect(url == browserURL(tag, "UPDATE-METADATA.json"))
    let metadata: [String: Any] = [
      "filename": packageName, "length": 200, "shortVersion": "2.8.0",
      "version": "1042.1", "sourceRevision": "abcdef123456abcdef123456abcdef123456abcd"
    ]
    return (try JSONSerialization.data(withJSONObject: metadata.merging(override) { _, value in value }),
            response(200, url: url))
  }

  private func response(
    _ status: Int = 302, url: URL? = nil, location: String? = nil, headers: [String: String] = [:]
  ) -> HTTPURLResponse {
    var headers = headers
    headers["Location"] = location
    return HTTPURLResponse(url: url ?? feed.releaseURL, statusCode: status, httpVersion: nil, headerFields: headers)!
  }
}
