import SwiftUI

/// Every page as a card, last written in first, like Procreate's gallery. + makes a new one.
struct Gallery: View {
    @State var pages = Page.all()
    @State var open: Page?
    @State var selection: Set<URL>?  // nil when not selecting
    @State var confirmingDeletion = false
    @State var deletionError: String?
    @State var settings = false
    @AppStorage("voiceInput") var voiceInput = false
    @Namespace var zoom

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 32)], spacing: 40) {
                    ForEach(pages) { page in
                        Button { tap(page) } label: {
                            Card(page: page, selected: selection.map { $0.contains(page.id) }, zoom: zoom)
                        }
                        .buttonStyle(.plain)
                        .highPriorityGesture(LongPressGesture().onEnded { _ in select(page) })
                        .accessibilityAddTraits(selection?.contains(page.id) == true ? .isSelected : [])
                        .accessibilityHint(selection == nil ? "Opens this page. Touch and hold to select pages." : "Toggles selection.")
                        .accessibilityAction(named: "Select page") { select(page) }
                    }
                }
                .padding(32)
            }
            .background(Color(.systemGroupedBackground))
            .overlay {
                if pages.isEmpty {
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
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Select") { selection = [] }
                            .disabled(pages.isEmpty)
                        Button("New page", systemImage: "plus") {
                            let page = Page.create()
                            pages = Page.all()  // its card is there to open out of, and close back into
                            open = page
                        }
                    }
                }
            }
            .alert("Delete selected pages?", isPresented: $confirmingDeletion) {
                Button("Delete \(selection?.count ?? 0) \(selection?.count == 1 ? "Page" : "Pages")", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These pages and their contents will be permanently deleted. This cannot be undone.")
            }
            .alert("Couldn't delete all selected pages", isPresented: Binding(
                get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionError ?? "")
            }
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                Form {
                    Section {
                        Toggle("Voice input", isOn: $voiceInput)
                    } footer: {
                        Text("Squeeze and hold Apple Pencil Pro to record a question through the iPad microphone. Release to send it to Meta and get an answer about your page. Recording stops after one minute and waits for release. You can also tap the microphone button to start and stop.")
                    }
                }
                .navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
            }
        }
        .fullScreenCover(item: $open, onDismiss: { pages = Page.all() }) { page in
            Paper(page: page, voiceEnabled: voiceInput)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    Button { open = nil } label: {
                        Label("Pages", systemImage: "square.grid.2x2")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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

/// A page's ink on paper, with when it was last written in.
struct Card: View {
    let page: Page
    var selected: Bool?  // nil when not selecting
    let zoom: Namespace.ID
    @State var image: UIImage?
    @Environment(\.colorScheme) var scheme

    var body: some View {
        VStack(spacing: 10) {
            Color(uiColor: .paper)
                .aspectRatio(Page.aspect, contentMode: .fit)
                .overlay { if let image { Image(uiImage: image).resizable().scaledToFit() } }
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
            Text("Untitled page").font(.headline)
            Text(page.edited, format: .dateTime.month().day().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .task(id: [page, scheme] as [AnyHashable]) {
            image = await page.thumbnail(dark: scheme == .dark)
        }
    }
}
