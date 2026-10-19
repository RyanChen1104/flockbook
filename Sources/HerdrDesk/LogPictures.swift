import AppKit
import HerdrKit
import SwiftUI

private struct LogURLKey: EnvironmentKey { static let defaultValue: URL? = nil }
extension EnvironmentValues {
    var logURL: URL? { get { self[LogURLKey.self] } set { self[LogURLKey.self] = newValue } }
}

enum PictureLayout {
    static func thumb(_ r: LogImage.Ref, maxHeight: CGFloat = 120) -> CGSize { .zero }
    static func fit(_ r: LogImage.Ref, maxWidth: CGFloat) -> CGSize { .zero }
}

final class PictureCache: @unchecked Sendable {
    static let shared = PictureCache()
    var countLimit: Int { 0 }
    var totalCostLimit: Int { 0 }
    func removeAll() {}
    func cached(url: URL, ref: LogImage.Ref, maxPixel: Int) -> NSImage? { nil }
    func load(url: URL, ref: LogImage.Ref, maxPixel: Int) async -> NSImage? { nil }
}

enum PictureFiles {
    static let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flockbook-pictures")
    static func write(_ data: Data, format: LogImage.Format) -> URL? { nil }
    static func remove(_ url: URL) {}
}
