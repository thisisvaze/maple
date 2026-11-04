import PencilKit
import SwiftUI
import Testing
@testable import Maple

extension DeviceChecks {
    @Test func preferencesReachNewPages() throws {
        let defaults = UserDefaults.standard
        let keys = ["pencilSounds", "pencilVolume", "perfectShapes"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let folder = URL.temporaryDirectory.appending(path: "maple-settings-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now)
        var controllers: [CanvasController] = []
        defer {
            for controller in controllers {
                controller.marks.stop()
                controller.pencilSound.stop()
                controller.saveTask?.cancel()
            }
            Store.queue.sync {}
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            defaults.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        func open() -> CanvasController {
            let controller = CanvasController(page: page)
            controller.loadViewIfNeeded()
            controller.setAIEnabled(false)
            controllers.append(controller)
            return controller
        }

        keys.forEach { defaults.removeObject(forKey: $0) }
        let original = open()
        #expect(original.pencilSound.enabled && original.pencilSound.volume == 1)
        #expect(original.quickShape.isEnabled)

        defaults.set(false, forKey: "pencilSounds")
        defaults.set(0.25, forKey: "pencilVolume")
        defaults.set(false, forKey: "perfectShapes")
        let quiet = open()
        #expect(!quiet.pencilSound.enabled && quiet.pencilSound.volume == 0.25)
        quiet.pencilSound.suspended = true
        quiet.pencilSound.suspended = false
        #expect(!quiet.pencilSound.enabled, "Finishing voice capture must not turn muted sounds back on.")
        #expect(!quiet.quickShape.isEnabled)
        quiet.quickShape.start(CGPoint(x: 2000, y: 3000))
        quiet.quickShape.move([CGPoint(x: 2300, y: 3000)])
        quiet.quickShape.rested()
        #expect(quiet.quickShape.shape == nil && quiet.quickShape.preview.superlayer == nil)
        quiet.quickShape.lift()
        #expect(quiet.canvas.drawing.strokes.isEmpty, "With snapping off, a held stroke stays with PencilKit.")

        defaults.set(true, forKey: "pencilSounds")
        defaults.set(0.6, forKey: "pencilVolume")
        defaults.set(true, forKey: "perfectShapes")
        let restored = open()
        #expect(restored.pencilSound.enabled && abs(restored.pencilSound.volume - 0.6) < 0.001)
        #expect(restored.quickShape.isEnabled)
        #expect(SettingsPanel.Appearance.system.colorScheme == nil)
        #expect(SettingsPanel.Appearance.light.colorScheme == .light)
        #expect(SettingsPanel.Appearance.dark.colorScheme == .dark)
    }

    @Test func appearanceReachesInkWindow() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let folder = URL.temporaryDirectory.appending(path: "maple-appearance-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now), controller = CanvasController(page: page)
        let host = UIWindow(windowScene: scene)
        host.addSubview(controller.view)
        controller.view.frame = host.bounds
        controller.overrideUserInterfaceStyle = .dark
        controller.viewDidLayoutSubviews()
        controller.setAIEnabled(false)
        defer {
            controller.marks.stop()
            controller.pencilSound.stop()
            controller.saveTask?.cancel()
            controller.turner.isHidden = true
            host.isHidden = true
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        controller.canvas.drawing = PKDrawing(strokes: [AgentPen.stroke([
            CGPoint(x: 2000, y: 3000), CGPoint(x: 2140, y: 3020)
        ], width: 3, step: 2)])
        let ink = controller.canvas.drawing.dataRepresentation()
        controller.viewDidAppear(false)
        let window = try #require(controller.turner as? Turner)
        #expect(window.overrideUserInterfaceStyle == .dark)
        controller.overrideUserInterfaceStyle = .light
        controller.view.layoutIfNeeded()
        #expect(window.overrideUserInterfaceStyle == .light, "The separate ink window must follow appearance changes.")
        #expect(controller.canvas.drawing.dataRepresentation() == ink, "Appearance must not rewrite saved ink.")
        controller.viewWillDisappear(false)
    }
}
