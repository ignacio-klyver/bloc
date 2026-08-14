import SwiftUI

/// A crumpled ball of paper, drawn procedurally.
///
/// The reference for this moment is a rendered 3D ball. This is a facetted approximation:
/// an irregular silhouette with a handful of shaded planes, which reads correctly at the
/// 22 pt it is actually shown at. Each note gets its own deterministic shape from its id,
/// so two notes never crumple identically and a single note never flickers between frames.
struct CrumpledBall: View {
    let seed: UInt64
    var size: CGFloat = 22

    @Environment(\.colorScheme) private var colorScheme

    private var paper: Color { Theme.paper }
    /// Shading is black in light and white in dark, so the facets read on either ground.
    private var shadow: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        Canvas { context, canvasSize in
            var rng = SplitMix64(seed: seed)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = min(canvasSize.width, canvasSize.height) / 2

            // Irregular silhouette.
            let corners = 11
            var points: [CGPoint] = []
            for index in 0..<corners {
                let angle = (Double(index) / Double(corners)) * 2 * .pi
                let jitter = 0.74 + rng.nextDouble() * 0.26
                points.append(CGPoint(x: center.x + cos(angle) * radius * jitter,
                                      y: center.y + sin(angle) * radius * jitter))
            }

            var silhouette = Path()
            silhouette.addLines(points)
            silhouette.closeSubpath()
            // Paper colour from the palette, not a literal white: a white ball disappears on
            // the light surface and a black one disappears on the dark one.
            context.fill(silhouette, with: .color(paper))

            // Facets: wedges of slightly different value give the ball its volume.
            for index in 0..<corners {
                let a = points[index]
                let b = points[(index + 1) % corners]
                let pull = 0.30 + rng.nextDouble() * 0.45
                let inner = CGPoint(x: center.x + (a.x - center.x) * pull * 0.4,
                                    y: center.y + (a.y - center.y) * pull * 0.4)
                var facet = Path()
                facet.move(to: a)
                facet.addLine(to: b)
                facet.addLine(to: inner)
                facet.closeSubpath()
                let shade = 0.06 + rng.nextDouble() * 0.20
                context.fill(facet, with: .color(shadow.opacity(shade)))
            }

            // Creases.
            for _ in 0..<4 {
                let start = points[Int(rng.next() % UInt64(corners))]
                let end = points[Int(rng.next() % UInt64(corners))]
                var crease = Path()
                crease.move(to: start)
                crease.addQuadCurve(
                    to: end,
                    control: CGPoint(x: center.x + (rng.nextDouble() - 0.5) * radius * 0.6,
                                     y: center.y + (rng.nextDouble() - 0.5) * radius * 0.6))
                context.stroke(crease, with: .color(shadow.opacity(0.14)), lineWidth: 0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A row mid-deletion: the paper shrinks and turns while the ball takes its place, then falls.
struct CrumplingRow: View {
    let note: Note
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0
    @State private var fall: Double = 0
    @State private var finished = false

    private var seed: UInt64 {
        var hasher = Hasher()
        hasher.combine(note.id)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(note.text)
                .font(.system(size: Theme.Size.note))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                // Pixel-identical geometry to NoteRow's text column, so the row swap is
                // invisible and the crumple is the only visible change. rowBleed alone left
                // the text teleporting 50 pt left the instant the delete began.
                .padding(.leading, Theme.Metric.rowBleed + Theme.Metric.gutter)
                .padding(.trailing, Theme.Metric.rowBleed)
                // Under reduced motion nothing scales, turns or blurs: only opacity moves.
                .scaleEffect(reduceMotion ? 1 : 1 - progress * 0.85, anchor: .leading)
                .rotationEffect(.degrees(reduceMotion ? 0 : progress * 18))
                .blur(radius: reduceMotion ? 0 : progress * 3)
                .opacity(1 - progress)

            if !reduceMotion {
                CrumpledBall(seed: seed)
                    // The ball takes the checkbox's place in the leading column.
                    .padding(.leading, Theme.Metric.rowBleed + 4)
                    .scaleEffect(progress)
                    .opacity(progress * (1 - fall))
                    .offset(x: fall * 26, y: fall * 30)
                    .rotationEffect(.degrees(fall * 140))
            }
        }
        // Same vertical envelope as NoteRow, so the rows below do not shift when the
        // swap happens.
        .padding(.vertical, 8)
        .frame(minHeight: 40, alignment: .leading)
        .onAppear(perform: play)
        // If the popover closes mid-flight the view goes away; commit the delete anyway so
        // the animation and the data never disagree, and do it exactly once.
        .onDisappear { finishOnce() }
    }

    /// The delete is committed by the animation finishing, not by a timer running in parallel
    /// with it. A loose asyncAfter kept firing against a closed window and left the undo
    /// banner armed for a deletion the user never saw complete.
    private func play() {
        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.15), completionCriteria: .removed) {
                progress = 1
            } completion: {
                finishOnce()
            }
            return
        }
        withAnimation(.easeOut(duration: 0.22)) { progress = 1 }
        withAnimation(.easeIn(duration: 0.24).delay(0.20), completionCriteria: .removed) {
            fall = 1
        } completion: {
            finishOnce()
        }
    }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}

/// Small deterministic generator so a note's crumple is stable across redraws.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
