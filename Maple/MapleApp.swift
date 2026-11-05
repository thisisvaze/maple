import SwiftUI

@main
struct MapleApp: App {
    var body: some Scene {
        WindowGroup { Root() }
    }
}

/// The appearance is read in a view: on iOS 27.2 an App's own @AppStorage stopped updating its scene after a change or
/// two, so Dark stayed on through System and Light (5 Nov, simulator).
private struct Root: View {
    @AppStorage("appearance") private var appearance = SettingsPanel.Appearance.system
    var body: some View { Gallery().preferredColorScheme(appearance.colorScheme) }
}

extension UIColor {
    // Calibration knobs: tune by eye on the device.
    static let paper = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1B / 255, alpha: 1)
        : UIColor(red: 0xFB / 255, green: 0xFB / 255, blue: 0xFA / 255, alpha: 1) }
    static let graphite = UIColor(red: 0x23 / 255, green: 0x23 / 255, blue: 0x22 / 255, alpha: 1)  // PencilKit flips it in dark mode
}
