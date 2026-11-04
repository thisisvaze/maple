import AuthenticationServices
import SwiftUI

struct SettingsPanel: View {
    enum Appearance: String, CaseIterable {
        case system = "System", light = "Light", dark = "Dark"

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("pencilSounds") private var pencilSounds = true
    @AppStorage("pencilVolume") private var pencilVolume = 1.0
    @AppStorage("perfectShapes") private var perfectShapes = true
    @AppStorage("voiceInput") private var voiceInput = false
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var gmail = Gmail.account?.email
    @State private var connecting = false
    @State private var gmailFailed = false
    @State var guide = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.font(.body.weight(.semibold)).frame(minHeight: 44)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            if textSize.isAccessibilitySize {
                Picker("Settings", selection: $guide) {
                    Text("Preferences").tag(false)
                    Text("Gestures & Marks").tag(true)
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 20)
            } else {
                HStack(spacing: 0) {
                    tab("Preferences", symbol: "slider.horizontal.3", isGuide: false)
                    tab("Gestures & Marks", symbol: "hand.draw", isGuide: true)
                }
                .padding(.top, 4)
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if guide { gestures } else { preferences }
                }
                .padding(20)
            }
        }
        .frame(idealWidth: 370, idealHeight: 620)
        .background(Color(uiColor: .secondarySystemBackground))
        .tint(.blue)
        .environment(\.colorScheme, .dark)
        .presentationCompactAdaptation(.sheet)
    }

    private func tab(_ title: String, symbol: String, isGuide: Bool) -> some View {
        Button { guide = isGuide } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(guide == isGuide ? Color.blue : .secondary)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(alignment: .bottom) {
                if guide == isGuide { Rectangle().fill(.blue).frame(height: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(guide == isGuide ? .isSelected : [])
    }

    private var preferences: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                heading("Appearance")
                if textSize.isAccessibilitySize {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } else {
                    HStack(spacing: 10) {
                        ForEach(Appearance.allCases, id: \.self) { option in
                            appearanceOption(option)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Pencil Sounds", isOn: $pencilSounds)
                    .accessibilityIdentifier("pencil-sounds")
                Text("Hear the pencil, eraser, and edit brush move across the paper.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").accessibilityHidden(true)
                    Slider(value: $pencilVolume, in: 0...1)
                        .accessibilityLabel("Pencil Volume")
                        .accessibilityValue("\(Int(pencilVolume * 100)) percent")
                        .accessibilityIdentifier("pencil-volume")
                    Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
                .disabled(!pencilSounds)
                .opacity(pencilSounds ? 1 : 0.4)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Perfect Shapes", isOn: $perfectShapes)
                    .accessibilityIdentifier("perfect-shapes")
                Text("Draw a shape and hold the pencil still to straighten it. Turn this off to keep every stroke as drawn.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Ask Out Loud", isOn: $voiceInput)
                Text("Hold an Apple Pencil Pro squeeze, speak, then release to send. You can also tap the microphone. Recordings go to Meta to transcribe and answer on your page, up to one minute at a time.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                heading("Connections")
                HStack {
                    Label("Gmail", systemImage: "envelope")
                    Spacer()
                    if gmail == nil {
                        Button("Connect") { Task { await connectGmail() } }
                            .disabled(Gmail.clientID.isEmpty || connecting)
                            .accessibilityLabel("Connect Gmail")
                    } else {
                        Button("Disconnect", role: .destructive) { Task { await Gmail.disconnect(); gmail = nil } }
                            .accessibilityLabel("Disconnect Gmail")
                    }
                }
                .frame(minHeight: 44)
                Text((gmail.map { "Connected as \($0). " } ?? "") + "Maple can search your mail to answer a question, like a flight time or a receipt total. It only reads, and the emails it reads go to Meta with your question.")
                    .font(.footnote).foregroundStyle(.secondary)
                if gmailFailed {
                    Text("Couldn't connect to Gmail. Try again.").font(.footnote).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Connections.Kind.allCases) { ConnectionToggle(kind: $0) }
                Text("Maple can look through these to answer a question, like when you're free on Thursday or the total on a receipt you photographed. It only reads, and what it reads goes to Meta with your question.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func connectGmail() async {
        let signIn = Gmail.signIn()
        connecting = true
        defer { connecting = false }
        do {
            let callback = try await webAuthenticationSession.authenticate(using: signIn.url, callback: .customScheme(Gmail.scheme), additionalHeaderFields: [:])
            gmail = try await Gmail.connect(callback, signIn)
            gmailFailed = false
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
        } catch {
            gmailFailed = true
        }
    }

    private func appearanceOption(_ option: Appearance) -> some View {
        Button { appearance = option } label: {
            VStack(spacing: 8) {
                ZStack {
                    HStack(spacing: 0) {
                        Color(uiColor: option == .dark ? .darkGray : .init(white: 0.97, alpha: 1))
                        Color(uiColor: option == .light ? .init(white: 0.97, alpha: 1) : .darkGray)
                    }
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(option == .light ? Color.black.opacity(0.7) : option == .system ? .blue : .white)
                }
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(appearance == option ? Color.blue : .white.opacity(0.15), lineWidth: appearance == option ? 2 : 1)
                }
                Text(option.rawValue).font(.caption.weight(.medium))
            }
            .foregroundStyle(appearance == option ? .blue : Color.primary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.rawValue) Appearance")
        .accessibilityAddTraits(appearance == option ? .isSelected : [])
    }

    private var gestures: some View {
        Group {
            heading("Make a Mark")
            entry("?", "Ask a Question", "Write a question and lift the pencil. A double dot works too.")
            entry("??", "Think It Through", "Use two question marks for a fuller answer.")
            entry("=", "Work It Out", "Leave an equals sign at the end of a line for the value.")
            entry("…", "Keep Going", "Trail off a sequence or list and Maple carries it on.")
            entry("•", "Add to a List", "Leave an empty bullet for the next item.")
            entry("□", "Draw in a Box", "Draw an empty box beside your words for a drawing, graph, or picture.")
            entry("○", "Make a Change", "Use the coral edit brush to mark what Maple should change.")
            Divider()
            heading("Pencil & Touch")
            entry("2", "Undo", "Tap the page with two fingers.")
            entry("3", "Redo", "Tap the page with three fingers.")
            entry("↓", "Copy Menu", "Swipe down with three fingers to copy for another app.")
            entry("↔", "Move the Page", "Use two fingers to pan, pinch to zoom, or twist to rotate.")
            entry("◇", "Perfect Shapes", "Draw and hold to straighten. Keep holding to adjust; touch a finger down to constrain the shape.")
            entry("⇄", "Switch Tools", "Double-tap Apple Pencil to cycle through pen, eraser, and edit.")
            entry("◦", "Ask Out Loud", "Turn on Ask Out Loud, then hold a Pencil Pro squeeze or tap the microphone.")
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func entry(_ mark: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(mark).font(.system(size: 26, weight: .light)).foregroundStyle(.blue)
                .frame(width: 42, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Turns on one of the iPad's own connections, asking iPadOS for access the first time.
private struct ConnectionToggle: View {
    let kind: Connections.Kind
    @AppStorage private var on: Bool
    @State private var denied = false
    @Environment(\.openURL) private var openURL

    init(kind: Connections.Kind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: false, kind.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { on && kind.authorized }, set: { wanted in Task { await turn(wanted) } })) {
                Label(kind.rawValue, systemImage: kind.symbol)
            }
            .frame(minHeight: 44)
            if denied {
                Button("Maple can't see your \(kind.rawValue.lowercased()). Turn on access in the Settings app.") {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                }
                .font(.footnote)
            }
        }
    }

    private func turn(_ wanted: Bool) async {
        on = wanted ? await kind.requestAccess() : false
        denied = wanted && !on
    }
}
