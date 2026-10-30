import AppKit
import SwiftUI

/// Sunlight Instructions: everything the app teaches, in one window, chapters in a sidebar. The basics
/// (the wizard's tour, and its tutorial to play again), the trackpad's gestures acted out (as Settings › Trackpad), placing windows (the
/// three scopes acted out, with Try), and every key (as Settings › Shortcuts). Opened from the menu bar
/// icon's More, its right-click menu, Help › Sunlight Instructions (⌘?), and the ? in Settings › Windows,
/// which opens it on Placing Windows.
enum Manual {
    enum Chapter: String, CaseIterable, Identifiable {
        case basics, gestures, placing, shortcuts

        var id: Self { self }

        var title: String {
            switch self {
            case .basics: return "The Basics"
            case .gestures: return "Trackpad Gestures"
            case .placing: return "Placing Windows"
            case .shortcuts: return "Keyboard Shortcuts"
            }
        }

        var symbol: String {
            switch self {
            case .basics: return "sun.max"
            case .gestures: return "hand.draw"
            case .placing: return "rectangle.split.2x1"
            case .shortcuts: return "keyboard"
            }
        }
    }

    struct Row: Equatable {
        let title: String
        let how: String
    }

    /// The canvas in a few lines, in the order you'd learn it.
    static let gettingAround: [Row] = [
        Row(title: "See everything", how: "four-finger tap (or swipe up: Settings › Trackpad)"),
        Row(title: "Zoom", how: "pinch · ⌥ or ⌘ scroll"),
        Row(title: "Pan", how: "two-finger scroll · drag the empty canvas"),
        Row(title: "Go into a window", how: "click · pinch in over it"),
        Row(title: "Bring a window to the middle", how: "double-click · ⏎ over it"),
        Row(title: "Use a window at 1:1", how: "click, as on the desktop"),
        Row(title: "Canvas ↔ last window", how: "Mission Control key · four-finger tap"),
        Row(title: "Show Desktop", how: "F11 · four-finger spread"),
        Row(title: "Pan from anywhere, even inside a window", how: "four-finger drag, any direction"),
    ]

    /// Where the rest lives.
    static let whereThingsAre: [Row] = [
        Row(title: "The sun icon in the menu bar", how: "Sunlight on or off, the minimap, layouts; More for the rest"),
        Row(title: "Place windows", how: "⌃⌥ keys, the Window menu, a window’s right-click menu"),
        Row(title: "Open an app at a spot", how: "double-click the empty canvas · right-click › Open Here…"),
        Row(title: "Save and restore layouts", how: "⌘S · ⌘1 – ⌘9"),
        Row(title: "Settings", how: "⌘, · More › Settings…"),
        Row(title: "These instructions", how: "⌘? · More › Instructions…"),
    ]
}

// MARK: - Window

/// Which chapter shows, and the experimental flags the chapters follow (Arrange and Tidy, strip mode).
@MainActor
final class ManualModel: ObservableObject {
    @Published var chapter: Manual.Chapter = .basics
    @Published var arranging = Settings.arranging
    @Published var strip = Settings.stripModeEnabled

    init() {
        NotificationCenter.default.addObserver(forName: Settings.experimentalFeaturesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.arranging = Settings.arranging
                self?.strip = Settings.stripModeEnabled
            }
        }
    }
}

@MainActor
final class ManualController: NSWindowController {
    private let model = ManualModel()

    init(onTry: @escaping (PlacementGuide.Scope) -> Void, onSettings: @escaping () -> Void, onTutorial: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Sunlight Instructions"
        // Over the canvas while Sunlight is active, like Settings; away when another app comes in front.
        window.level = .floating
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        // Wide enough for the three placing cards beside the sidebar.
        window.contentMinSize = NSSize(width: 1080, height: 560)
        super.init(window: window)
        let hosting = NSHostingController(rootView: ManualView(model: model, onTry: onTry, onSettings: onSettings, onTutorial: onTutorial))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1100, height: 720))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Opens on a chapter, or wherever it was left.
    func show(_ chapter: Manual.Chapter? = nil) {
        guard let window else { return }
        if let chapter { model.chapter = chapter }
        if !window.isVisible { window.center() }
        NSApp.activate()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

struct ManualView: View {
    @ObservedObject var model: ManualModel
    let onTry: (PlacementGuide.Scope) -> Void
    let onSettings: () -> Void
    let onTutorial: () -> Void

    var body: some View {
        NavigationSplitView {
            List(Manual.Chapter.allCases, selection: Binding<Manual.Chapter?>(
                get: { model.chapter },
                set: { if let chapter = $0 { model.chapter = chapter } }
            )) { chapter in
                Label(chapter.title, systemImage: chapter.symbol).tag(chapter)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .navigationTitle(model.chapter.title)
        }
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.chapter {
        case .basics:
            BasicsChapter(onTutorial: onTutorial)
        case .gestures:
            TrackpadPane()
        case .placing:
            ScrollView {
                PlacementGuideView(onTry: onTry, onSettings: onSettings, onDone: nil, arranging: model.arranging)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        case .shortcuts:
            // Rebuilt when an experimental flag changes: the commands it lists follow them.
            ShortcutsPane()
                .id("\(model.arranging)-\(model.strip)")
        }
    }
}

/// The wizard's tour, a little longer: getting around the canvas, and where everything else is.
private struct BasicsChapter: View {
    let onTutorial: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    RowLabel(title: "The tutorial", subtitle: "The moves from setup, acted out, one at a time")
                    Spacer()
                    Button("Play the Tutorial", action: onTutorial)
                }
            }
            Section {
                ForEach(Manual.gettingAround, id: \.title) { row in
                    LabeledContent(row.title) { Text(row.how).foregroundStyle(.secondary) }
                }
            } header: {
                SectionHeader(title: "Getting around",
                              detail: "Every window sits on one big canvas. Zoom out to see them all and move them about; go into one to use it, at its real size.")
            }
            Section {
                ForEach(Manual.whereThingsAre, id: \.title) { row in
                    LabeledContent(row.title) {
                        Text(row.how)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                SectionHeader(title: "Where things are",
                              detail: "The other chapters act the gestures and placing out, and list every key.")
            }
        }
        .formStyle(.grouped)
    }
}
