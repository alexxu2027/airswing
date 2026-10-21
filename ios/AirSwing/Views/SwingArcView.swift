import SwiftUI

/// Face-on swing arc: address at the bottom, the backswing turning up to the left in grey, the
/// downswing in the accent colour to impact, and the follow-through faint.
struct SwingArcView: View {
    let arc: SwingArc

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 * 0.7
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            func position(_ p: SwingArc.Point) -> CGPoint {
                // Pointing out of the plane pulls the line in or out, so plane changes show.
                let r = radius * min(1.4, max(0.6, 1 - p.offPlane))
                return CGPoint(x: center.x - r * sin(p.angle), y: center.y + r * cos(p.angle))
            }

            func line(_ range: ClosedRange<Int>) -> Path {
                var path = Path()
                path.addLines(arc.points[range].map(position))
                return path
            }

            func dot(_ i: Int, _ size: CGFloat, _ color: Color) {
                let c = position(arc.points[i])
                context.fill(Path(ellipseIn: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)),
                             with: .color(color))
            }

            let guide = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: guide), with: .color(.secondary.opacity(0.15)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            let last = arc.points.count - 1
            let top = arc.index(at: arc.phases.top)
            let impact = max(top, arc.index(at: arc.phases.downswingEnd))
            let stroke = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }

            context.stroke(line(impact...last), with: .color(.accentColor.opacity(0.25)), style: stroke(4))
            context.stroke(line(0...top), with: .color(.secondary.opacity(0.7)), style: stroke(5))
            context.stroke(line(top...impact), with: .color(.accentColor), style: stroke(6))
            dot(0, 9, .secondary)
            dot(top, 11, .primary)
            dot(impact, 13, .accentColor)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(String(format: "Swing arc. The backswing turned %.0f degrees.", arc.backswingDegrees))
    }
}

/// Recent swings' tempo as small bars, newest on the right. Unclear swings are short grey stubs.
struct TempoStrip: View {
    let tempos: [Double?]
    var target: Double?

    var body: some View {
        Canvas { context, size in
            let shown = tempos.suffix(20)
            let slot = size.width / 20
            let maxTempo = max(4.5, shown.compactMap { $0 }.max() ?? 0)
            for (i, tempo) in shown.enumerated() {
                let x = size.width - CGFloat(shown.count - i) * slot + slot * 0.2
                let h = tempo.map { size.height * CGFloat($0 / maxTempo) } ?? 3
                let bar = CGRect(x: x, y: size.height - h, width: slot * 0.6, height: h)
                let isLatest = i == shown.count - 1
                context.fill(Path(roundedRect: bar, cornerRadius: 2),
                             with: .color(tempo == nil ? .secondary.opacity(0.3) : (isLatest ? .accentColor : .secondary.opacity(0.5))))
            }
            if let target {
                let y = size.height * (1 - CGFloat(target / maxTempo))
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.green.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .frame(height: 36)
        .accessibilityHidden(true)
    }
}
