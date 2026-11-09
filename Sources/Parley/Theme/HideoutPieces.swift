import AppKit
import SwiftUI

// MARK: - Hand-cut shape

/// A rounded rectangle whose edges wander very slightly, as if cut out with scissors. Stable for
/// a given seed and size.
struct WobblyRect: InsettableShape {
    var seed: Int = 1
    var radius: CGFloat = 14
    var amplitude: CGFloat = 1.4
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> WobblyRect {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    private func jitter(_ i: Int) -> CGFloat {
        let v = sin(Double(i) * 12.9898 + Double(seed) * 78.233) * 43758.5453
        return CGFloat((v - v.rounded(.down)) * 2 - 1) * amplitude
    }

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > 2, rect.height > 2 else { return Path() }
        let r = min(radius, min(rect.width, rect.height) / 2)
        let step: CGFloat = 44
        var points: [CGPoint] = []
        var index = 0

        func add(_ p: CGPoint, normal: CGVector) {
            let j = jitter(index)
            index += 1
            points.append(CGPoint(x: p.x + normal.dx * j, y: p.y + normal.dy * j))
        }
        func edge(_ a: CGPoint, _ b: CGPoint, normal: CGVector) {
            let length = hypot(b.x - a.x, b.y - a.y)
            let count = max(1, Int(length / step))
            for k in 0...count {
                let t = CGFloat(k) / CGFloat(count)
                add(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), normal: normal)
            }
        }
        func corner(_ c: CGPoint, from start: CGFloat) {
            for k in 1...2 {
                let a = start + CGFloat(k) / 3 * .pi / 2
                let n = CGVector(dx: cos(a), dy: sin(a))
                points.append(CGPoint(x: c.x + n.dx * r, y: c.y + n.dy * r))
            }
        }

        edge(CGPoint(x: rect.minX + r, y: rect.minY), CGPoint(x: rect.maxX - r, y: rect.minY), normal: .init(dx: 0, dy: -1))
        corner(CGPoint(x: rect.maxX - r, y: rect.minY + r), from: -.pi / 2)
        edge(CGPoint(x: rect.maxX, y: rect.minY + r), CGPoint(x: rect.maxX, y: rect.maxY - r), normal: .init(dx: 1, dy: 0))
        corner(CGPoint(x: rect.maxX - r, y: rect.maxY - r), from: 0)
        edge(CGPoint(x: rect.maxX - r, y: rect.maxY), CGPoint(x: rect.minX + r, y: rect.maxY), normal: .init(dx: 0, dy: 1))
        corner(CGPoint(x: rect.minX + r, y: rect.maxY - r), from: .pi / 2)
        edge(CGPoint(x: rect.minX, y: rect.maxY - r), CGPoint(x: rect.minX, y: rect.minY + r), normal: .init(dx: -1, dy: 0))
        corner(CGPoint(x: rect.minX + r, y: rect.minY + r), from: .pi)

        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var path = Path()
        path.move(to: mid(points[points.count - 1], points[0]))
        for i in points.indices {
            path.addQuadCurve(to: mid(points[i], points[(i + 1) % points.count]), control: points[i])
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Cards

extension View {
    /// A hand-cut paper card with a soft shadow. Use a stable seed per item.
    func paperCard(_ fill: Color = Hideout.card, seed: Int = 1, radius: CGFloat = 14, shadow: Bool = true) -> some View {
        background {
            WobblyRect(seed: seed, radius: radius)
                .fill(fill)
                .shadow(color: .black.opacity(shadow ? 0.10 : 0), radius: 3, y: 1.5)
        }
    }

    /// Paper card with a running quilt stitch just inside its edge.
    func stitchedCard(_ fill: Color = Hideout.card, stitch: Color = Hideout.stitch, seed: Int = 2, radius: CGFloat = 18) -> some View {
        self
            .paperCard(fill, seed: seed, radius: radius)
            .overlay {
                WobblyRect(seed: seed, radius: max(radius - 5, 2), amplitude: 0.8)
                    .inset(by: 5)
                    .stroke(stitch, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [6, 5]))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    /// A flat card for safety UI: strong coloured edge, no decoration.
    func noticeCard(fill: Color, edge: Color, radius: CGFloat = 12) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(edge, lineWidth: 1.5))
    }
}

// MARK: - Decorations

/// A strip of washi tape, with pinked ends.
struct WashiTape: View {
    var color: Color = Hideout.marigold
    var width: CGFloat = 54
    var height: CGFloat = 16
    var angle: Double = -3

    var body: some View {
        TapeShape()
            .fill(color.opacity(0.82))
            .overlay(TapeShape().fill(.white.opacity(0.10)).padding(.vertical, 5))
            .frame(width: width, height: height)
            .rotationEffect(.degrees(angle))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private struct TapeShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let teeth = 4
            let tooth = rect.height / CGFloat(teeth)
            let depth: CGFloat = 3
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            for i in 0..<teeth {
                let y = rect.minY + CGFloat(i) * tooth
                p.addLine(to: CGPoint(x: rect.maxX - depth, y: y + tooth / 2))
                p.addLine(to: CGPoint(x: rect.maxX, y: y + tooth))
            }
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            for i in (0..<teeth).reversed() {
                let y = rect.minY + CGFloat(i) * tooth
                p.addLine(to: CGPoint(x: rect.minX + depth, y: y + tooth / 2))
                p.addLine(to: CGPoint(x: rect.minX, y: y))
            }
            p.closeSubpath()
            return p
        }
    }
}

/// Paper bunting and small warm bulbs on a sagging cord, drawn edge to edge.
struct Bunting: View {
    var height: CGFloat = 40

    var body: some View {
        // Read here, not in the deferred drawing closure, so a change of skin redraws it.
        let colors = Hideout.palette.flags.map(\.color)
        let marigold = Hideout.marigold
        Canvas { context, size in
            let spans = max(1, Int((size.width / 130).rounded()))
            let spanWidth = size.width / CGFloat(spans)
            let sag: CGFloat = 11

            func cordPoint(_ x: CGFloat) -> CGPoint {
                let t = (x.truncatingRemainder(dividingBy: spanWidth)) / spanWidth
                return CGPoint(x: x, y: 3 + 4 * sag * t * (1 - t))
            }

            var cord = Path()
            cord.move(to: cordPoint(0))
            for x in stride(from: CGFloat(2), through: size.width, by: 2) { cord.addLine(to: cordPoint(x)) }
            context.stroke(cord, with: .color(Color(red: 0.98, green: 0.93, blue: 0.82).opacity(0.85)), lineWidth: 1.25)

            var x: CGFloat = 12
            var i = 0
            while x < size.width - 10 {
                let a = cordPoint(x)
                let b = cordPoint(x + 16)
                if i % 3 == 2 {
                    let c = cordPoint(x + 6)
                    let bulb = CGRect(x: c.x - 3.5, y: c.y - 1, width: 7, height: 7)
                    context.fill(Path(ellipseIn: bulb.insetBy(dx: -4, dy: -4)), with: .color(marigold.opacity(0.28)))
                    context.fill(Path(ellipseIn: bulb), with: .color(marigold))
                    x += 16
                } else {
                    var flag = Path()
                    flag.move(to: a)
                    flag.addLine(to: b)
                    flag.addLine(to: CGPoint(x: (a.x + b.x) / 2 + 0.8, y: max(a.y, b.y) + 16))
                    flag.closeSubpath()
                    context.fill(flag, with: .color(colors[i % colors.count]))
                    x += 23
                }
                i += 1
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The little lantern that marks the assistant's replies. A hanging ring, a peaked cap, a caged
/// glass and a flame: the padlock is this app's sign for encryption, so this must never read as one.
struct LanternMark: View {
    var size: CGFloat = 18

    var body: some View {
        // Registers this view with the skin: the drawing closure below runs later.
        let _ = Hideout.skin
        Canvas { context, canvas in
            let s = canvas.width / 18
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let metal = GraphicsContext.Shading.color(Hideout.emberText)

            context.fill(Path(ellipseIn: CGRect(x: 1.5 * s, y: 3.2 * s, width: 15 * s, height: 15 * s)),
                         with: .color(Hideout.marigold.opacity(0.22)))

            // The wire ring it hangs from, much narrower than the body.
            context.stroke(Path(ellipseIn: CGRect(x: 7.7 * s, y: 0.7 * s, width: 2.6 * s, height: 2.6 * s)),
                           with: metal, lineWidth: 0.8 * s)

            var glass = Path()
            glass.move(to: p(6, 5.6))
            glass.addQuadCurve(to: p(6, 14.6), control: p(4.6, 10.1))
            glass.addLine(to: p(12, 14.6))
            glass.addQuadCurve(to: p(12, 5.6), control: p(13.4, 10.1))
            glass.closeSubpath()
            context.fill(glass, with: .color(Hideout.marigold.opacity(0.45)))

            var bars = Path()
            bars.move(to: p(4.7, 5.6))
            bars.addLine(to: p(4.7, 14.8))
            bars.move(to: p(13.3, 5.6))
            bars.addLine(to: p(13.3, 14.8))
            context.stroke(bars, with: metal, lineWidth: 0.9 * s)

            var cap = Path()
            cap.move(to: p(9, 2.8))
            cap.addLine(to: p(13.8, 6))
            cap.addLine(to: p(4.2, 6))
            cap.closeSubpath()
            context.fill(cap, with: metal)

            var flame = Path()
            flame.move(to: p(9, 7))
            flame.addCurve(to: p(9, 13.4), control1: p(9.5, 8.8), control2: p(11.4, 13.4))
            flame.addCurve(to: p(9, 7), control1: p(6.6, 13.4), control2: p(8.5, 8.8))
            flame.closeSubpath()
            context.fill(flame, with: .color(Hideout.ember))

            context.fill(Path(roundedRect: CGRect(x: 4.2 * s, y: 14.6 * s, width: 9.6 * s, height: 1.9 * s), cornerRadius: 0.7 * s),
                         with: metal)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A picture taped to the wall: follows the appearance, drawn with a paper border.
struct TapedPicture: View {
    @Environment(\.colorScheme) private var scheme
    let day: String
    let night: String
    var width: CGFloat
    var aspect: CGFloat

    var body: some View {
        let image = Hideout.art(scheme == .dark ? night : day)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(aspect, contentMode: .fill)
            } else {
                Hideout.paperDeep
            }
        }
        .frame(width: width, height: width / aspect)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(9)
        .background {
            WobblyRect(seed: 7, radius: 9, amplitude: 1.2)
                .fill(Hideout.card)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        }
        .overlay(alignment: .top) { WashiTape(color: Hideout.rose, width: 84, height: 22, angle: -2.5).offset(y: -10) }
        .accessibilityHidden(true)
    }
}

/// Three fireflies, for "working on it". Only animates while on screen and honours Reduce Motion.
struct FirefliesIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots(phase: 0, animated: false)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                dots(phase: timeline.date.timeIntervalSinceReferenceDate, animated: true)
            }
        }
    }

    private func dots(phase: Double, animated: Bool) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                let level = animated ? (sin(phase * 2.6 - Double(i) * 0.9) + 1) / 2 : 0.7
                ZStack {
                    Circle().fill(Hideout.firefly.opacity(0.28 * level)).frame(width: 15, height: 15)
                    Circle().fill(Hideout.firefly.opacity(0.4 + 0.6 * level)).frame(width: 7, height: 7)
                }
                .frame(width: 15, height: 15)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small spinner in a Hideout colour; the system one ignores `.tint` and stays grey. Only
/// animates while on screen, and is a still arc under Reduce Motion.
struct HideoutSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color = Hideout.emberText
    var size: CGFloat = 14

    var body: some View {
        Group {
            if reduceMotion {
                arc(degrees: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    arc(degrees: (timeline.date.timeIntervalSinceReferenceDate * 300).truncatingRemainder(dividingBy: 360))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("In progress")
    }

    private func arc(degrees: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
            .padding(1)
            .rotationEffect(.degrees(degrees))
    }
}

// MARK: - Buttons

/// Paper-tag buttons. The label's colour comes from the kind.
struct TagButtonStyle: ButtonStyle {
    enum Kind { case primary, soft, danger }
    var kind: Kind = .soft
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, kind: kind, isEnabled: isEnabled)
    }

    private struct Inner: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let isEnabled: Bool
        @ViewState private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                // Disabled is its own quiet look, whatever the kind: fading the whole button took
                // its label below 4.5:1 and left a primary looking pressable.
                .foregroundStyle(isEnabled ? foreground : Hideout.inkSoft)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background {
                    WobblyRect(seed: 11, radius: 10, amplitude: 0.8)
                        .fill(isEnabled ? fill : Hideout.paperDeep)
                        .brightness(hovering && isEnabled && !pressed ? 0.03 : pressed ? -0.05 : 0)
                        .shadow(color: .black.opacity(pressed || !isEnabled ? 0 : 0.12), radius: 1.5, y: 1)
                }
                .overlay {
                    if !isEnabled {
                        WobblyRect(seed: 11, radius: 10, amplitude: 0.8)
                            .stroke(Hideout.inkFaint.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3]))
                    } else if kind == .soft {
                        WobblyRect(seed: 11, radius: 10, amplitude: 0.8)
                            .stroke(Hideout.inkFaint.opacity(0.55), lineWidth: 1)
                    }
                }
                .scaleEffect(pressed ? 0.98 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            switch kind {
            case .primary: Hideout.ember
            case .soft: Hideout.paperDeep
            case .danger: Hideout.danger
            }
        }

        private var foreground: Color {
            switch kind {
            case .primary: Hideout.onEmber
            case .soft: Hideout.ink
            case .danger: Hideout.paper
            }
        }
    }
}

/// Round icon button: header and composer tools. `onWall` for the sidebar.
struct RoundIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var onWall = false
    var hoverFill: Color = Hideout.emberWash

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, size: size, onWall: onWall, hoverFill: hoverFill)
    }

    private struct Inner: View {
        let configuration: ButtonStyle.Configuration
        let size: CGFloat
        let onWall: Bool
        let hoverFill: Color
        @ViewState private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(onWall ? Hideout.wallInk : Hideout.inkSoft)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(onWall ? Hideout.tag.opacity(hovering ? 0.75 : 0.45) : (hovering ? hoverFill : Hideout.paperDeep))
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Window chrome helpers

/// Lets the custom header drag the window, on every supported macOS. A double-click does what
/// System Settings says a double-click on a title bar does.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window?.performMiniaturize(nil)
                case "None": break
                default: window?.performZoom(nil)
                }
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keeps the enclosing scroll view's scroller floating over its content. A legacy scroller takes
/// its width out of the content, which shifts anything centred in it off the composer's column.
/// Goes inside the ScrollView's content.
struct OverlayScrollers: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
        }

        /// After AppKit's own handling of the change, which puts the preferred style back.
        @objc func scheduleApply() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let scroll = enclosingScrollView, scroll.scrollerStyle != .overlay else { return }
            scroll.scrollerStyle = .overlay
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        NotificationCenter.default.addObserver(probe, selector: #selector(Probe.scheduleApply),
                                               name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.scheduleApply()
    }
}

/// Hides the table's own selection highlight, so a row can draw its own paper tag.
struct ListSelectionHighlightRemover: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            var ancestor = superview
            for _ in 0..<8 {
                guard let view = ancestor else { return }
                if let table = Self.firstTable(in: view) {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    return
                }
                ancestor = view.superview
            }
        }

        private static func firstTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews {
                if let found = firstTable(in: sub) { return found }
            }
            return nil
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {
        DispatchQueue.main.async { nsView.apply() }
    }
}
