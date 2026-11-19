import Foundation

nonisolated struct RepositoryUpdateFeed: Sendable {
  enum Failure: Error {
    case unavailable, invalidRelease
  }

  struct Asset: Decodable, Sendable {
    let id: Int
    let name: String
    let size: Int
    let url: URL
  }

  struct Release: Decodable, Sendable {
    let tagName: String
    let draft: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case draft, assets
    }
  }

  struct Resolved: Sendable {
    let feedURL: URL
    let archives: [URL: Int]

    func permits(_ url: URL?, length: UInt64) -> Bool {
      guard let url, let expected = archives[url], expected > 0 else { return false }
      return UInt64(expected) == length
    }
  }

  static let repository = "66lyy/Maccy-Capture"
  static let tag = "capture-latest"
  static let feedName = "capture-appcast.xml"

  let repository: String

  init(repository: String = Self.repository) {
    self.repository = repository
  }

  var releaseURL: URL {
    URL(string: "https://api.github.com/repos/\(repository)/releases/tags/\(Self.tag)")!
  }

  func request() -> URLRequest {
    var request = URLRequest(url: releaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpShouldHandleCookies = false
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("MaccyCapture/Updates", forHTTPHeaderField: "User-Agent")
    return request
  }

  func resolve(data: Data, response: URLResponse) throws -> Resolved {
    guard let response = response as? HTTPURLResponse, response.url == releaseURL else {
      throw Failure.invalidRelease
    }
    guard response.statusCode == 200 else { throw Failure.unavailable }
    guard data.count <= 2_000_000,
          let release = try? JSONDecoder().decode(Release.self, from: data),
          !release.draft, release.tagName == Self.tag else {
      throw Failure.invalidRelease
    }
    let feeds = release.assets.filter { $0.name == Self.feedName }
    guard feeds.count == 1, let feed = feeds.first, valid(feed), feed.size <= 1_000_000 else {
      throw Failure.unavailable
    }
    let packages = release.assets.filter {
      $0.name.hasPrefix("Maccy-Capture-") && $0.name.hasSuffix("-universal.zip") && valid($0)
    }
    guard !packages.isEmpty, Set(packages.map(\.url)).count == packages.count else {
      throw Failure.invalidRelease
    }
    return Resolved(
      feedURL: URL(string: "https://github.com/\(repository)/releases/download/\(Self.tag)/\(Self.feedName)")!,
      archives: Dictionary(uniqueKeysWithValues: packages.map { ($0.url, $0.size) })
    )
  }

  private func valid(_ asset: Asset) -> Bool {
    asset.id > 0 && asset.size > 0 &&
      asset.url.absoluteString == "https://api.github.com/repos/\(repository)/releases/assets/\(asset.id)"
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
    completionHandler(nil)
  }
}
