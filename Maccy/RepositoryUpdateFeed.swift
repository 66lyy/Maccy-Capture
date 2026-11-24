import Foundation

nonisolated struct RepositoryUpdateFeed: Sendable {
  enum Channel: String, Sendable {
    case stable, preview
  }

  enum Failure: Error {
    case unavailable, invalidRelease
  }

  struct Resolved: Sendable {
    let feedURL: URL
    let archiveURL: URL
    let archiveLength: UInt64
    let repository: String

    func downloadURL(for enclosure: URL?, length: UInt64) -> URL? {
      guard length == archiveLength, let enclosure else { return nil }
      if enclosure == archiveURL { return archiveURL }
      let prefix = "https://api.github.com/repos/\(repository)/releases/assets/"
      guard let assetID = UInt64(enclosure.lastPathComponent), assetID > 0,
            enclosure.absoluteString == "\(prefix)\(assetID)" else { return nil }
      return archiveURL
    }

    func configureDownload(_ request: NSMutableURLRequest, enclosure: URL?, length: UInt64) {
      guard let download = downloadURL(for: enclosure, length: length), request.url == enclosure else {
        request.url = URL(string: "about:blank")
        return
      }
      request.url = download
      request.httpShouldHandleCookies = false
      request.cachePolicy = .reloadIgnoringLocalCacheData
    }
  }

  private struct Metadata: Decodable {
    let filename: String
    let length: UInt64
    let shortVersion: String
    let version: String
    let sourceRevision: String
  }

  static let repository = "66lyy/Maccy-Capture"
  static let feedName = "capture-appcast.xml"
  private static let metadataName = "UPDATE-METADATA.json"

  let repository: String
  let channel: Channel

  init(repository: String = Self.repository, channel: Channel = .stable) {
    self.repository = repository
    self.channel = channel
  }

  private var releases: String { "https://github.com/\(repository)/releases" }

  var releaseURL: URL {
    URL(string: releases + (channel == .stable ? "/latest" : ".atom"))!
  }

  func request() -> URLRequest {
    request(for: releaseURL, accept: channel == .stable ? "text/html" : "application/atom+xml")
  }

  private func request(for url: URL, accept: String) -> URLRequest {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpShouldHandleCookies = false
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("MaccyCapture/Updates", forHTTPHeaderField: "User-Agent")
    return request
  }

  func releaseTags(data: Data, response: URLResponse) throws -> [String] {
    guard let response = response as? HTTPURLResponse, response.url == releaseURL else {
      throw Failure.invalidRelease
    }
    switch channel {
    case .stable:
      guard [301, 302, 303, 307, 308].contains(response.statusCode) else { throw Failure.unavailable }
      guard let location = response.value(forHTTPHeaderField: "Location"),
            let url = URL(string: location, relativeTo: releaseURL)?.absoluteURL,
            let tag = tag(from: url.absoluteString) else { throw Failure.invalidRelease }
      return [tag]
    case .preview:
      guard response.statusCode == 200 else { throw Failure.unavailable }
      guard data.count <= 2_000_000 else { throw Failure.invalidRelease }
      let feed = ReleaseAtom()
      let parser = XMLParser(data: data)
      parser.shouldProcessNamespaces = true
      parser.delegate = feed
      guard parser.parse(), feed.isAtomFeed else { throw Failure.invalidRelease }
      let formatter = ISO8601DateFormatter()
      let entries = feed.entries.compactMap { entry -> (tag: String, date: Date)? in
        guard let tag = tag(from: entry.link),
              let date = formatter.date(from: entry.updated.trimmingCharacters(in: .whitespacesAndNewlines)) else {
          return nil
        }
        return (tag, date)
      }.sorted { $0.date > $1.date }
      var seen = Set<String>()
      let tags = entries.map(\.tag).filter { seen.insert($0).inserted }
      guard !tags.isEmpty else { throw Failure.unavailable }
      return tags
    }
  }

  private func tag(from link: String) -> String? {
    let prefix = releases + "/tag/"
    guard link.hasPrefix(prefix) else { return nil }
    let tag = String(link.dropFirst(prefix.count))
    return valid(tag: tag) ? tag : nil
  }

  private func valid(tag: String) -> Bool {
    let suffix = channel == .preview ? #"(-build[0-9]+(\.[0-9]+){0,2})?"# : ""
    return tag.range(of: #"\Amaccy-capture-v[0-9]+\.[0-9]+\.[0-9]+"# + suffix + #"\z"#,
                     options: .regularExpression) != nil
  }

  func resolve(
    tags: [String], isolation: isolated (any Actor)? = #isolation,
    load: (URLRequest) async throws -> (Data, URLResponse)
  ) async throws -> Resolved {
    for tag in tags where valid(tag: tag) {
      try Task.checkCancellation()
      do {
        return try await resolve(tag: tag, load: load)
      } catch is Failure where channel == .preview {
        continue
      }
    }
    throw Failure.unavailable
  }

  private func resolve(
    tag: String, isolation: isolated (any Actor)? = #isolation,
    load: (URLRequest) async throws -> (Data, URLResponse)
  ) async throws -> Resolved {
    let download = "\(releases)/download/\(tag)"
    let metadataURL = URL(string: "\(download)/\(Self.metadataName)")!
    let (data, response) = try await load(request(for: metadataURL, accept: "application/json"))
    try checkAssetResponse(response, for: metadataURL)
    guard data.count <= 1_000_000, let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
          metadata.length > 0,
          metadata.version.range(of: #"\A[0-9]+(\.[0-9]+){0,2}\z"#, options: .regularExpression) != nil,
          metadata.sourceRevision.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil else {
      throw Failure.invalidRelease
    }
    let stableTag = "maccy-capture-v\(metadata.shortVersion)"
    let archiveName = "Maccy-Capture-\(metadata.shortVersion)-build\(metadata.version)-\(metadata.sourceRevision.prefix(12))-universal.zip"
    guard (tag == stableTag || tag == "\(stableTag)-build\(metadata.version)"),
          metadata.filename == archiveName else { throw Failure.invalidRelease }

    let feedURL = URL(string: "\(download)/\(Self.feedName)")!
    var feedRequest = request(for: feedURL, accept: "application/rss+xml,*/*;q=0.1")
    feedRequest.httpMethod = "HEAD"
    let (_, feedResponse) = try await load(feedRequest)
    try checkAssetResponse(feedResponse, for: feedURL)
    guard (1...1_000_000).contains(feedResponse.expectedContentLength) else { throw Failure.invalidRelease }
    return Resolved(
      feedURL: feedURL, archiveURL: URL(string: "\(download)/\(archiveName)")!,
      archiveLength: metadata.length, repository: repository
    )
  }

  private func checkAssetResponse(_ response: URLResponse, for url: URL) throws {
    guard let response = response as? HTTPURLResponse, let actual = response.url,
          actual == url || Self.isAssetCDN(actual) else { throw Failure.invalidRelease }
    guard response.statusCode == 200 else { throw Failure.unavailable }
  }

  static func allowsAssetRedirect(from source: URL, to target: URL) -> Bool {
    guard source.scheme == "https", source.host == "github.com",
          source.path.contains("/releases/download/"),
          [metadataName, feedName].contains(source.lastPathComponent) else { return false }
    return isAssetCDN(target)
  }

  private static func isAssetCDN(_ url: URL) -> Bool {
    let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    return parts?.scheme == "https" && parts?.host == "release-assets.githubusercontent.com" &&
      parts?.port == nil && parts?.user == nil && parts?.password == nil && parts?.fragment == nil
  }
}

nonisolated private final class ReleaseAtom: NSObject, XMLParserDelegate {
  struct Entry {
    var link = ""
    var updated = ""
  }

  private(set) var entries: [Entry] = []
  private(set) var isAtomFeed = false
  private let namespace = "http://www.w3.org/2005/Atom"
  private var depth = 0
  private var entry: Entry?
  private var readingUpdated = false

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
    attributes: [String: String]
  ) {
    depth += 1
    guard namespaceURI == namespace else { return }
    if depth == 1 {
      isAtomFeed = elementName == "feed"
    } else if isAtomFeed, depth == 2, elementName == "entry" {
      entry = Entry()
    } else if depth == 3 {
      if elementName == "link", attributes["rel"] == "alternate", let link = attributes["href"] {
        entry?.link = link
      }
      readingUpdated = elementName == "updated"
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if depth == 3, readingUpdated {
      entry?.updated += string
    }
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
  ) {
    if depth == 3 {
      readingUpdated = false
    } else if depth == 2, let entry {
      entries.append(entry)
      self.entry = nil
    }
    depth -= 1
  }
}

nonisolated final class RepositoryUpdateSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    return try await session.data(for: request)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let source = response.url, source == task.originalRequest?.url, let target = request.url,
          RepositoryUpdateFeed.allowsAssetRedirect(from: source, to: target) else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
