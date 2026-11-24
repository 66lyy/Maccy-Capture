import ApplicationServices
import Foundation

enum ScreenshotElementDetection {
  nonisolated static let applicationMessagingTimeout: Float = 0.06
  nonisolated static let elementMessagingTimeout: Float = 0.04
  nonisolated struct Window: Sendable, Equatable {
    let pid: pid_t
    let frame: NSRect
    var id: CGWindowID = kCGNullWindowID
    var layer = 0
  }

  nonisolated struct Result: Sendable {
    enum Outcome: Sendable { case success, cannotComplete, unavailable }
    let rectangles: [NSRect]
    var outcome: Outcome = .success
  }

  nonisolated static func windows() -> [Window] {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let windowLevels = Set([CGWindowLevelKey.normalWindow, .floatingWindow, .modalPanelWindow, .popUpMenuWindow]
      .map { Int(CGWindowLevelForKey($0)) })
    return windows.compactMap { window in
      guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
            let id = window[kCGWindowNumber as String] as? CGWindowID,
            let layer = window[kCGWindowLayer as String] as? Int,
            windowLevels.contains(layer),
            let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary),
            rectangle.width >= 3, rectangle.height >= 3
      else { return nil }
      return Window(pid: pid, frame: rectangle, id: id, layer: layer)
    }
  }

  nonisolated static func rectangles(at point: NSPoint, in windows: [Window]? = nil) -> [NSRect] {
    guard let window = (windows ?? self.windows()).first(where: { $0.frame.contains(point) }) else { return [] }
    return probe(at: point, in: window).rectangles
  }

  nonisolated static func probe(at point: NSPoint, in window: Window) -> Result {
    let rectangle = window.frame
    guard AXIsProcessTrusted() else { return Result(rectangles: [rectangle], outcome: .unavailable) }
    let application = AXUIElementCreateApplication(window.pid)
    let timeoutError = AXUIElementSetMessagingTimeout(application, applicationMessagingTimeout)
    guard timeoutError == .success else {
      return Result(rectangles: [rectangle], outcome: timeoutError == .cannotComplete ? .cannotComplete : .unavailable)
    }
    var hit: AXUIElement?
    let hitError = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
    guard hitError == .success else {
      return Result(rectangles: [rectangle], outcome: hitError == .cannotComplete ? .cannotComplete : .unavailable)
    }
    var rectangles: [NSRect] = []
    var cannotComplete = false
    for _ in 0..<6 {
      guard let element = hit else { break }
      let error = AXUIElementSetMessagingTimeout(element, elementMessagingTimeout)
      if error == .cannotComplete { cannotComplete = true }
      guard error == .success else { break }
      if let position: CGPoint = value(kAXPositionAttribute, element: element, type: .cgPoint, zero: .zero,
                                       cannotComplete: &cannotComplete),
         let size: CGSize = value(kAXSizeAttribute, element: element, type: .cgSize, zero: .zero,
                                  cannotComplete: &cannotComplete) {
        let frame = NSRect(origin: position, size: size).intersection(rectangle)
        if frame.contains(point) { rectangles.append(frame) }
      }
      if cannotComplete { break }
      var parent: CFTypeRef?
      let parentError = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent)
      if parentError == .cannotComplete { cannotComplete = true }
      guard parentError == .success,
            let parent, CFGetTypeID(parent) == AXUIElementGetTypeID(), !CFEqual(parent, element) else { break }
      hit = (parent as! AXUIElement)
    }
    return Result(rectangles: cannotComplete ? [rectangle] : rectangles + [rectangle],
                  outcome: cannotComplete ? .cannotComplete : .success)
  }

  nonisolated private static func value<Value>(
    _ attribute: String, element: AXUIElement, type: AXValueType, zero: Value, cannotComplete: inout Bool
  ) -> Value? {
    var raw: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
    if error == .cannotComplete { cannotComplete = true }
    guard error == .success,
          let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == type else { return nil }
    var result = zero
    return withUnsafeMutablePointer(to: &result) { pointer in
      AXValueGetValue(value, type, pointer)
    } ? result : nil
  }
}

nonisolated struct ScreenshotProbeBackoff {
  private struct AppState {
    var inFlight = false
    var timedOut = false
    var delay: TimeInterval = 0
    var retryAfter: TimeInterval = 0
  }

  private var apps: [pid_t: AppState] = [:]

  mutating func begin(pid: pid_t, now: TimeInterval) -> Bool {
    var app = apps[pid] ?? AppState()
    guard !app.inFlight, now >= app.retryAfter else { return false }
    app.inFlight = true
    app.timedOut = false
    apps[pid] = app
    return true
  }

  mutating func timeOut(pid: pid_t, now: TimeInterval) {
    guard var app = apps[pid], app.inFlight, !app.timedOut else { return }
    app.timedOut = true
    app.delay = min(8, max(0.5, app.delay * 2))
    app.retryAfter = now + app.delay
    apps[pid] = app
  }

  @discardableResult
  mutating func complete(pid: pid_t, outcome: ScreenshotElementDetection.Result.Outcome, now: TimeInterval) -> Bool {
    guard var app = apps[pid], app.inFlight else { return false }
    app.inFlight = false
    if app.timedOut {
      app.retryAfter = now + app.delay
    } else if outcome == .cannotComplete {
      app.delay = min(8, max(0.5, app.delay * 2))
      app.retryAfter = now + app.delay
    } else if outcome == .success {
      apps[pid] = nil
      return true
    }
    apps[pid] = app
    return !app.timedOut
  }
}

@MainActor
final class ScreenshotElementProbe {
  static let shared = ScreenshotElementProbe()
  static let timeout: Duration = .seconds(1)
  private var backoff = ScreenshotProbeBackoff()

  @discardableResult
  func start(
    at point: NSPoint, in window: ScreenshotElementDetection.Window,
    detect: @escaping @Sendable (NSPoint, ScreenshotElementDetection.Window) -> ScreenshotElementDetection.Result,
    completion: @escaping @MainActor (ScreenshotElementDetection.Result) -> Void
  ) -> Bool {
    guard backoff.begin(pid: window.pid, now: ProcessInfo.processInfo.systemUptime) else { return false }
    let watchdog = Task {
      do { try await Task.sleep(for: Self.timeout) } catch { return }
      backoff.timeOut(pid: window.pid, now: ProcessInfo.processInfo.systemUptime)
      completion(.init(rectangles: [window.frame], outcome: .cannotComplete))
    }
    Task {
      let worker = Task.detached(priority: .userInitiated) { detect(point, window) }
      let result = await worker.value
      watchdog.cancel()
      let usable = backoff.complete(pid: window.pid, outcome: result.outcome, now: ProcessInfo.processInfo.systemUptime)
      guard usable else { return }
      try? await Task.sleep(for: .milliseconds(50))
      completion(result)
    }
    return true
  }
}
