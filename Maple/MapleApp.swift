import SwiftUI

@main
struct MapleApp: App {
    var body: some Scene {
        WindowGroup {
            Paper(page: Page.all().first ?? Page.create())
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

extension UIColor {
    // Calibration knobs: tune by eye on the device.
    static let paper = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1B / 255, alpha: 1)
        : UIColor(red: 0xFB / 255, green: 0xFB / 255, blue: 0xFA / 255, alpha: 1) }
    static let graphite = UIColor(red: 0x23 / 255, green: 0x23 / 255, blue: 0x22 / 255, alpha: 1)  // PencilKit flips it in dark mode
}
