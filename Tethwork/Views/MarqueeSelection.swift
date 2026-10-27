import AppKit
import SwiftUI

/// Tracks item frames in a named coordinate space for marquee hit-testing.
struct MarqueeFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Reports this view's frame for marquee selection.
    func marqueeFrame(id: String, in space: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: MarqueeFrameKey.self,
                    value: [id: geo.frame(in: .named(space))]
                )
            }
        )
    }
}

/// Observes mouse events without stealing hits from SwiftUI (hitTest always nil).
struct MarqueeMonitorView: NSViewRepresentable {
    var frames: [String: CGRect]
    var currentSelection: Set<String>
    @Binding var marqueeRect: CGRect?
    var onSelect: (Set<String>) -> Void
    var onEmptyClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            currentSelection: currentSelection,
            onSelect: onSelect,
            onEmptyClick: onEmptyClick
        )
    }

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.coordinator = context.coordinator
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        context.coordinator.frames = frames
        context.coordinator.currentSelection = currentSelection
        context.coordinator.onSelect = onSelect
        context.coordinator.onEmptyClick = onEmptyClick
        context.coordinator.marqueeRectBinding = $marqueeRect
        nsView.coordinator = context.coordinator
    }

    static func dismantleNSView(_ nsView: TrackerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var frames: [String: CGRect] = [:]
        var currentSelection: Set<String>
        var onSelect: (Set<String>) -> Void
        var onEmptyClick: () -> Void
        var marqueeRectBinding: Binding<CGRect?>?
        weak var view: TrackerView?

        private var monitor: Any?
        private var startPoint: CGPoint?
        private var didDrag = false
        private var additive = false
        private var baseline: Set<String> = []
        private var tracking = false

        init(
            currentSelection: Set<String>,
            onSelect: @escaping (Set<String>) -> Void,
            onEmptyClick: @escaping () -> Void
        ) {
            self.currentSelection = currentSelection
            self.onSelect = onSelect
            self.onEmptyClick = onEmptyClick
        }

        func start() {
            stop()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            tracking = false
            startPoint = nil
            didDrag = false
            DispatchQueue.main.async { [weak self] in
                self?.marqueeRectBinding?.wrappedValue = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, view.window != nil else { return event }

            let pointInView = view.convert(event.locationInWindow, from: nil)
            let inBounds = view.bounds.insetBy(dx: -1, dy: -1).contains(pointInView)

            switch event.type {
            case .leftMouseDown:
                guard inBounds else { return event }
                // Click on an item — let SwiftUI handle taps / file drag.
                if frames.values.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(pointInView) }) {
                    tracking = false
                    return event
                }
                tracking = true
                startPoint = pointInView
                didDrag = false
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                additive = flags.contains(.command) || flags.contains(.shift)
                baseline = additive ? currentSelection : []
                return event

            case .leftMouseDragged:
                guard tracking, let start = startPoint else { return event }
                let distance = hypot(pointInView.x - start.x, pointInView.y - start.y)
                if distance < 4 { return event }
                didDrag = true
                let rect = CGRect(
                    x: min(start.x, pointInView.x),
                    y: min(start.y, pointInView.y),
                    width: abs(pointInView.x - start.x),
                    height: abs(pointInView.y - start.y)
                )
                marqueeRectBinding?.wrappedValue = rect
                let ids = Set(frames.compactMap { id, frame in
                    frame.intersects(rect) ? id : nil
                })
                onSelect(baseline.union(ids))
                return nil // consume so ScrollView doesn't scroll-drag oddly

            case .leftMouseUp:
                guard tracking else { return event }
                tracking = false
                defer {
                    startPoint = nil
                    didDrag = false
                    marqueeRectBinding?.wrappedValue = nil
                }
                if didDrag {
                    return nil
                }
                if !additive {
                    onEmptyClick()
                }
                return event

            default:
                return event
            }
        }
    }
}

final class TrackerView: NSView {
    weak var coordinator: MarqueeMonitorView.Coordinator?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: CGPoint) -> NSView? {
        // Never steal hits — SwiftUI items must receive clicks.
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            coordinator?.stop()
        } else {
            coordinator?.start()
        }
    }
}

/// Content + empty-space marquee selection (clicks on items stay with SwiftUI).
struct MarqueeSelectable<Content: View>: View {
    let spaceName: String
    let currentSelection: Set<String>
    let onSelect: (Set<String>) -> Void
    let onEmptyClick: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var frames: [String: CGRect] = [:]
    @State private var marqueeRect: CGRect?

    var body: some View {
        content()
            .coordinateSpace(name: spaceName)
            .onPreferenceChange(MarqueeFrameKey.self) { frames = $0 }
            .overlay {
                if let rect = marqueeRect, rect.width > 1, rect.height > 1 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .background {
                MarqueeMonitorView(
                    frames: frames,
                    currentSelection: currentSelection,
                    marqueeRect: $marqueeRect,
                    onSelect: onSelect,
                    onEmptyClick: onEmptyClick
                )
            }
    }
}
