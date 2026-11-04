import SwiftUI

/// Every page as a card, last written in first, like Procreate's gallery. + makes a new one.
struct Gallery: View {
    @State var pages = Page.all()
    @State var open: Page?
    @State var selection: Set<URL>?  // nil when not selecting
    @State var confirmingDeletion = false
    @State var deletionError: String?
    @State var settings = false
    @State var renaming: Page?
    @State var newName = ""
    @State var titleFrame = CGRect.zero  // the open page's name on screen
    @AppStorage("voiceInput") var voiceInput = false
    @AppStorage("aiEnabled") var aiEnabled = true
    @Namespace var zoom
    /// The Me page opens from the toolbar, so it isn't a card. `pages` keeps it so its changes still rerun the reading below.
    var cards: [Page] { pages.filter { !$0.isMe } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 32)], spacing: 40) {
                    ForEach(cards) { page in
                        VStack(spacing: 10) {
                            Button { tap(page) } label: {
                                Card(page: page, selected: selection.map { $0.contains(page.id) }, zoom: zoom)
                            }
                            .buttonStyle(.plain)
                            .highPriorityGesture(LongPressGesture().onEnded { _ in select(page) })
                            .accessibilityLabel(page.title)
                            .accessibilityAddTraits(selection?.contains(page.id) == true ? .isSelected : [])
                            .accessibilityHint(selection == nil ? "Opens this page. Touch and hold to select pages." : "Toggles selection.")
                            .accessibilityAction(named: "Select page") { select(page) }
                            .accessibilityAction(named: "Rename") { rename(page) }
                            // Tapping the name renames the page, like Procreate.
                            Button(page.title) { rename(page) }
                                .font(.headline)
                                .lineLimit(1)
                                .buttonStyle(.plain)
                                .accessibilityHidden(true)  // the card's Rename action covers it
                            Text(page.edited, format: .dateTime.month().day().hour().minute())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(32)
            }
            .background(Color(.systemGroupedBackground))
            .overlay {
                if cards.isEmpty {
                    ContentUnavailableView("No pages yet", systemImage: "square.and.pencil", description: Text("Tap + to start one."))
                }
            }
            .navigationTitle(selection.map { "\($0.count) Selected" } ?? "Pages")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settings = true }
                }
                if let selection {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { self.selection = nil }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                            .disabled(selection.isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Me", systemImage: "person.crop.circle") { open = pages.first(where: \.isMe) ?? .me }
                            .accessibilityHint("Opens what Maple remembers about you.")
                    }
                    .matchedTransitionSource(id: Page.me.id, in: zoom)
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Select") { selection = [] }
                            .disabled(cards.isEmpty)
                        Button("New page", systemImage: "plus") {
                            let page = Page.create()
                            pages = Page.all()  // its card is there to open out of, and close back into
                            open = page
                        }
                    }
                }
            }
            .alert("Delete these pages?", isPresented: $confirmingDeletion) {
                Button("Delete \(selection?.count ?? 0) \(selection?.count == 1 ? "Page" : "Pages")", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            .alert("Some pages couldn't be deleted", isPresented: Binding(
                get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionError ?? "")
            }
            .alert("Rename Page", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { page in
                TextField("Untitled page", text: $newName)
                Button("Rename") {
                    if newName != page.title { page.rename(newName) }
                    pages = Page.all()
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Leave it empty to name it from its ink.")
            }
            // Maple names pages whose ink changed since it last did. This runs again whenever the list changes, so a page
            // is named soon after it closes; a name that fails is tried again then.
            .task(id: [pages, aiEnabled] as [AnyHashable]) {
                guard aiEnabled else { return }
                var named = false
                for page in pages where page.needsName {
                    guard !Task.isCancelled, Marks.aiEnabled else { return }
                    named = await page.nameFromInk() || named
                }
                guard !Task.isCancelled, Marks.aiEnabled else { return }
                if named { pages = Page.all() }
                for page in pages where page.unread {
                    guard !Task.isCancelled, Marks.aiEnabled else { return }
                    guard let lines = await page.handwriting() else { continue }
                    guard !Task.isCancelled, Marks.aiEnabled else { return }
                    Memories.shared.change { $0.written(lines, page: page.url.lastPathComponent) }
                    try? Data().write(to: page.readFile)
                }
            }
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                Form {
                    Section {
                        Toggle("Ask Out Loud", isOn: $voiceInput)
                    } footer: {
                        Text("Squeeze and hold Apple Pencil Pro, ask out loud, and release to send. Your recording goes to Meta to transcribe and answer on your page, up to one minute at a time. You can also tap the microphone button.")
                    }
                }
                .navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
            }
        }
        .fullScreenCover(item: $open, onDismiss: { pages = Page.all() }) { page in
            Paper(page: page, voiceEnabled: voiceInput, aiEnabled: aiEnabled, titleFrame: titleFrame)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 12) {
                        Button { open = nil } label: {
                            Label("Pages", systemImage: "square.grid.2x2")
                                .labelStyle(.iconOnly)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        PageTitle(page: page)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { titleFrame = $0 }
                    }
                    // Up to the tool dock centered at the top, 146 pt wide, with a gap.
                    .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in max(width / 2 - 100, 44) }
                    .padding(16)
                    .containerCornerOffset(.leading)  // in a window, sit beside the close and resize controls, not under them
                }
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .interactiveDismissDisabled()  // a palm or a pinch on the paper never closes the page
                .navigationTransition(.zoom(sourceID: page.id, in: zoom))  // grows out of its card, shrinks back into it
        }
    }

    func tap(_ page: Page) {
        guard var selected = selection else { open = page; return }
        if !selected.insert(page.id).inserted { selected.remove(page.id) }
        selection = selected
    }

    func rename(_ page: Page) {
        newName = page.title
        renaming = page
    }

    func select(_ page: Page) {
        selection = (selection ?? []).union([page.id])
    }

    func deleteSelected() {
        guard let selected = selection else { return }
        for page in pages where selected.contains(page.id) {
            do {
                try page.delete()
                selection?.remove(page.id)
            } catch {
                deletionError = error.localizedDescription + " Pages that couldn't be deleted remain selected. You can try again."
            }
        }
        pages = Page.all()
        if selection?.isEmpty == true { selection = nil }
    }
}

/// A page's ink on paper.
struct Card: View {
    let page: Page
    var selected: Bool?  // nil when not selecting
    let zoom: Namespace.ID
    @State var image: UIImage?
    @State var loading = true
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        Color(uiColor: .paper)
            .aspectRatio(Page.aspect, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if loading { GalleryOrb().frame(width: 34, height: 34).accessibilityLabel("Loading page preview") }
            }
            .clipShape(.rect(cornerRadius: 6))
            .matchedTransitionSource(id: page.id, in: zoom) { $0.clipShape(.rect(cornerRadius: 6)) }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected == true ? Color.accentColor : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .background(.regularMaterial, in: Circle())
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .task(id: [page, scheme] as [AnyHashable]) {
                loading = true
                let thumbnail = await page.thumbnail(dark: scheme == .dark)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                    image = thumbnail
                    loading = false
                }
            }
    }
}

/// The open page's name beside the Pages button. Tap it to type a name, or write on it with Apple Pencil: Scribble's
/// scratch out, circle and join work as in any text field. While the page is open, Maple names it again a little after
/// its ink changes, until the person names it; an empty name hands it back to Maple.
struct PageTitle: View {
    static let every: Duration = .seconds(8)  // calibration knob: how often to look for new ink to name, one Muse call each time
    let page: Page
    @State var draft: String
    @State var start: String  // the name when editing began, so Maple renaming meanwhile isn't taken for the person's
    @FocusState var editing: Bool

    init(page: Page) {
        self.page = page
        let name = page.savedName ?? ""
        _draft = State(initialValue: name)
        _start = State(initialValue: name)
    }

    var body: some View {
        // The hidden text sizes the field to its name, and cuts a long one short before the tools.
        Text(draft.isEmpty ? "Untitled page" : draft)
            .lineLimit(1)
            .padding(.trailing, 2)  // room for the caret
            .hidden()
            .overlay {
                TextField("Untitled page", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .submitLabel(.done)
                    .onSubmit(commit)
            }
            .font(.headline)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.regularMaterial, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { editing = true }  // the padding too
            .accessibilityLabel("Page name")
            .animation(editing ? nil : .easeInOut(duration: 0.28), value: draft)  // Maple's new name eases in; typing doesn't
            .onChange(of: editing) { if !editing { commit() } }
            .onDisappear(perform: commit)
            .task {
                while !Task.isCancelled {
                    if !editing, page.needsName { _ = await page.nameFromInk() }
                    if !editing { draft = page.savedName ?? ""; start = draft }
                    try? await Task.sleep(for: Self.every)
                }
            }
    }

    func commit() {
        if draft != start { page.rename(draft) }
        draft = page.savedName ?? ""
        start = draft
    }
}

private struct GalleryOrb: UIViewRepresentable {
    func makeUIView(context: Context) -> Thinking { Thinking(style: .orb) }
    func updateUIView(_ view: Thinking, context: Context) {}
}
