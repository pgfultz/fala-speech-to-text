import SwiftUI
import AppKit

// MARK: - Window

private final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Allow sitting on top of the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@Observable
final class OverlayModel {
    var notch = true
    var notchSize = CGSize(width: 200, height: 32)
    var visible = false
}

final class OverlayController {
    static let shared = OverlayController()
    private let panel = OverlayPanel()
    private let model = OverlayModel()
    private var hideTimer: Timer?
    private static let size = CGSize(width: 520, height: 180)

    private init() {
        let host = NSHostingView(rootView: OverlayRoot(model: model, controller: .shared))
        host.sizingOptions = []
        panel.contentView = host
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = DictationController.shared.phase
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        let phase = DictationController.shared.phase
        if phase == .idle {
            model.visible = false
            hideTimer?.invalidate()
            hideTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                if self?.model.visible == false { self?.panel.orderOut(nil) }
            }
            return
        }
        hideTimer?.invalidate()
        if !panel.isVisible { position() }
        panel.orderFrontRegardless()
        if !model.visible {
            DispatchQueue.main.async { self.model.visible = true }
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let hasNotch = screen.safeAreaInsets.top > 0
        let style = AppSettings.shared.pillStyle
        model.notch = style == .notch || (style == .auto && hasNotch)

        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, hasNotch {
            model.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            model.notchSize = CGSize(width: 180, height: max(menuBar, 30))
        }

        let s = Self.size
        let x = screen.frame.midX - s.width / 2
        let y = model.notch ? screen.frame.maxY - s.height : screen.visibleFrame.minY + 28
        panel.setFrame(NSRect(x: x, y: y, width: s.width, height: s.height), display: false)
    }
}

// MARK: - Root

private struct OverlayRoot: View {
    let model: OverlayModel
    let controller: DictationController

    var body: some View {
        Group {
            if model.notch {
                NotchIsland(model: model, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                GlassPill(model: model, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 6)
            }
        }
        .preferredColorScheme(model.notch ? .dark : nil)
    }
}

private extension DictationController {
    var message: String? {
        switch phase {
        case .error(let m): m
        case .listening, .transcribing: partial.isEmpty ? nil : partial
        default: nil
        }
    }
    var engineSymbol: String { AppSettings.shared.engine.symbol }
}

private let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)

// MARK: - Notch island

private struct NotchIsland: View {
    let model: OverlayModel
    let controller: DictationController

    var body: some View {
        let phase = controller.phase
        let open = model.visible && phase != .idle
        let message = open ? controller.message : nil
        let wing: CGFloat = 70
        let n = model.notchSize
        let width = open ? max(n.width + wing * 2, message == nil ? 0 : 360) : n.width
        let height = n.height + (message == nil ? 0 : 30)

        ZStack(alignment: .top) {
            NotchShape(top: open ? 8 : 6, bottom: open ? 18 : 10)
                .fill(.black)
                .shadow(color: .black.opacity(open ? 0.35 : 0), radius: 14, y: 6)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Indicator(controller: controller, tint: .white)
                        .frame(width: wing, alignment: .center)
                        .padding(.leading, 8)
                    Spacer(minLength: n.width)
                    Trailing(controller: controller, color: .white)
                        .frame(width: wing, alignment: .center)
                        .padding(.trailing, 8)
                }
                .frame(height: n.height)

                if let message {
                    Text(message)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(isError(phase) ? 0.7 : 0.9))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.horizontal, 22)
                        .frame(height: 26)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .opacity(open ? 1 : 0)
            .blur(radius: open ? 0 : 6)
        }
        .frame(width: width, height: height)
        .animation(spring, value: open)
        .animation(spring, value: message == nil)
        .animation(spring, value: phase)
    }
}

private func isError(_ phase: Phase) -> Bool {
    if case .error = phase { return true }
    return false
}

/// The notch silhouette: flat top that flares into the bezel, rounded bottom corners.
private struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Glass pill

private struct GlassPill: View {
    let model: OverlayModel
    let controller: DictationController

    var body: some View {
        let phase = controller.phase
        let open = model.visible && phase != .idle
        let message = controller.message

        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Indicator(controller: controller, tint: .primary)
                Trailing(controller: controller, color: .primary)
            }
            .frame(height: 30)
            if let message {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(isError(phase) ? 0.65 : 0.85))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: 380)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .scaleEffect(open ? 1 : 0.6, anchor: .bottom)
        .opacity(open ? 1 : 0)
        .blur(radius: open ? 0 : 8)
        .animation(spring, value: open)
        .animation(spring, value: message == nil)
        .animation(spring, value: phase)
    }
}

// MARK: - Pieces

/// Left side: what the app is doing.
private struct Indicator: View {
    let controller: DictationController
    let tint: Color

    var body: some View {
        switch controller.phase {
        case .listening:
            HStack(spacing: 6) {
                PulseDot(level: controller.level, latched: controller.latched, tint: tint)
                if let start = controller.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Self.elapsed(from: start, to: ctx.date))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(tint.opacity(0.8))
                    }
                }
            }
            .transition(.blurReplace)
        case .transcribing:
            Image(systemName: controller.engineSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating)
                .transition(.blurReplace)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, options: .nonRepeating)
                .transition(.blurReplace)
        case .error:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint.opacity(0.7))
                .transition(.blurReplace)
        case .idle:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    static func elapsed(from: Date, to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PulseDot: View {
    let level: Float
    let latched: Bool
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 7 + CGFloat(level) * 9, height: 7 + CGFloat(level) * 9)
            if latched {
                Image(systemName: "lock.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(tint)
            } else {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
        }
        .frame(width: 18, height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Right side: live waveform while listening, a calm travelling wave while transcribing.
private struct Trailing: View {
    let controller: DictationController
    let color: Color

    var body: some View {
        switch controller.phase {
        case .listening:
            Waveform(level: controller.level, color: color, thinking: false)
        case .transcribing:
            Waveform(level: 0.45, color: color.opacity(0.7), thinking: true)
        case .done:
            Text(tr("Inserted", "Inserido")).font(.system(size: 12, weight: .medium)).foregroundStyle(color.opacity(0.8))
                .transition(.blurReplace)
        default:
            EmptyView()
        }
    }
}

struct Waveform: View {
    var level: Float
    var color: Color
    var thinking: Bool
    var bars = 9
    var maxHeight: CGFloat = 18
    var barWidth: CGFloat = 2.6

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: height(i, t))
                }
            }
            .frame(height: maxHeight)
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        let x = Double(i)
        let center = Double(bars - 1) / 2
        let dist = abs(x - center) / center
        let bell = 1 - dist * dist * 0.65
        let floor: CGFloat = 3
        if thinking {
            let wave = (sin(t * 6 - x * 0.75) + 1) / 2
            return floor + (maxHeight * 0.6 - floor) * CGFloat(wave * bell)
        }
        let wobble = 0.55 + 0.45 * sin(t * 11 + x * 1.9) * cos(t * 5.3 + x * 0.7)
        let breathing = 1.5 * (sin(t * 3 + x) + 1) / 2
        return floor + breathing + (maxHeight - floor) * CGFloat(Double(level) * bell * wobble)
    }
}
