import ApplicationServices
import Foundation

enum ScreenshotElementDetection {
  nonisolated static func rectangles(at point: NSPoint) -> [NSRect] {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    for window in windows {
      guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
            window[kCGWindowLayer as String] as? Int == 0,
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { continue }
      guard rectangle.contains(point) else { continue }
      guard AXIsProcessTrusted() else { return [rectangle] }
      let application = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(application, 0.06)
      var hit: AXUIElement?
      guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success
      else { return [rectangle] }
      var rectangles: [NSRect] = []
      for _ in 0..<6 {
        guard let element = hit else { break }
        AXUIElementSetMessagingTimeout(element, 0.04)
        if let position: CGPoint = value(kAXPositionAttribute, element: element, type: .cgPoint, zero: .zero),
           let size: CGSize = value(kAXSizeAttribute, element: element, type: .cgSize, zero: .zero) {
          let frame = NSRect(origin: position, size: size).intersection(rectangle)
          if frame.contains(point) { rectangles.append(frame) }
        }
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
              let parent, CFGetTypeID(parent) == AXUIElementGetTypeID(), !CFEqual(parent, element) else { break }
        hit = (parent as! AXUIElement)
      }
      return rectangles + [rectangle]
    }
    return []
  }

  nonisolated private static func value<Value>(
    _ attribute: String, element: AXUIElement, type: AXValueType, zero: Value
  ) -> Value? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == type else { return nil }
    var result = zero
    return withUnsafeMutablePointer(to: &result) { pointer in
      AXValueGetValue(value, type, pointer)
    } ? result : nil
  }
}
