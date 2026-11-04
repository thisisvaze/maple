import QuartzCore
import Testing
import UIKit
@testable import Maple

extension DeviceChecks {
    @Test func loadingWhileZooming() async throws {
        try #require(!UIAccessibility.isReduceMotionEnabled, "This benchmark needs animated loaders.")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host
        window.windowLevel = .normal + 3
        host.view.backgroundColor = .paper
        host.view.clipsToBounds = true
        window.isHidden = false
        let loaders = (0..<3).map { _ in Thinking(style: .pixels) }
        let orbs = [24.0, 34, 40].enumerated().map { i, size in
            let orb = Thinking(style: .orb)
            orb.frame = CGRect(x: 30 + i * 60, y: 40, width: Int(size), height: Int(size))
            host.view.addSubview(orb)
            return orb
        }
        for (i, loader) in loaders.enumerated() {
            host.view.addSubview(loader)
            loader.place(over: CGRect(x: 25, y: 100 + i * 240, width: 600, height: 400), turn: 0, zoom: 1)
            loader.layoutIfNeeded()
        }
        let paths = loaders.map { $0.cells.map(\.path) }
        let scales = loaders.map(\.contentScaleFactor)
        let probe = LoadingProbe(loaders)
        let link = CADisplayLink(target: probe, selector: #selector(LoadingProbe.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        defer {
            link.invalidate()
            (loaders + orbs).forEach { $0.removeFromSuperview() }
            window.isHidden = true
        }
        try await Task.sleep(for: .seconds(5))
        let gaps = probe.gaps.sorted()
        try #require(!gaps.isEmpty)
        let report: [String: Double] = ["frames": Double(gaps.count), "p95_ms": gaps[Int(Double(gaps.count - 1) * 0.95)] * 1000,
                                       "max_ms": gaps.last! * 1000, "over_33ms": Double(gaps.filter { $0 > 0.0334 }.count)]
        let data = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
        try data.write(to: URL.temporaryDirectory.appending(path: "maple-loading-profile.json"))
        print("Loading zoom: " + String(decoding: data, as: UTF8.self))
        #expect(gaps.count >= 200, "Loading should leave enough main-thread time for a 60 Hz pinch.")
        #expect(report["p95_ms"]! < 34, "Loading must not stall most zoom frames.")
        for (i, loader) in loaders.enumerated() {
            #expect(loader.layer.contents == nil, "The texture needs no bitmap backing.")
            #expect(loader.contentScaleFactor == scales[i] && loader.cells.count == 4)
            for (cell, path) in zip(loader.cells, paths[i]) {
                #expect(path != nil && cell.path === path, "Zoom must reuse the texture paths.")
            }
            let indicator = try #require(loader.indicator)
            #expect(abs(indicator.bounds.width * loader.pageZoom - 40) < 0.01)
            #expect(!loader.isUserInteractionEnabled && !indicator.isUserInteractionEnabled)
            #expect(loader.texture.animation(forKey: "shimmer") != nil && indicator.scribble.animation(forKey: "chase") != nil)
            loader.isHidden = true
            #expect(loader.texture.animation(forKey: "shimmer") == nil && indicator.scribble.animation(forKey: "chase") == nil)
            loader.isHidden = false
            #expect(loader.texture.animation(forKey: "shimmer") != nil && indicator.scribble.animation(forKey: "chase") != nil)
            loader.pause()
            #expect(loader.texture.animation(forKey: "shimmer") == nil)
            loader.resume()
            #expect(loader.texture.animation(forKey: "shimmer") != nil)
            loader.removeFromSuperview()
            #expect(loader.texture.animation(forKey: "shimmer") == nil && indicator.scribble.animation(forKey: "chase") == nil)
        }
    }
}

@MainActor private final class LoadingProbe: NSObject {
    let loaders: [Thinking]
    var start = 0.0, last = 0.0
    var gaps: [Double] = []
    init(_ loaders: [Thinking]) { self.loaders = loaders }
    @objc func tick(_ link: CADisplayLink) {
        if start == 0 { start = link.timestamp }
        if last > 0, link.timestamp - start > 0.5 { gaps.append(link.timestamp - last) }
        last = link.timestamp
        let zoom = 1.5 + 0.9 * sin((link.timestamp - start) * 3)
        for (i, loader) in loaders.enumerated() {
            loader.place(over: CGRect(x: 25, y: 100 + i * 240, width: 600, height: 400), turn: sin((link.timestamp - start) * 2) * 0.2, zoom: zoom)
            loader.layoutIfNeeded()
        }
    }
}
