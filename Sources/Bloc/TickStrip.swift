import SwiftUI

/// Day navigation drawn as a density strip: one tick per day, height by note count,
/// accent tint when the day still holds unprocessed notes.
///
/// The whole strip is a single control, not one target per tick. A tick is 3 pt wide, far
/// under the 24 pt minimum target, and adjacent ticks would have overlapping hit areas. So the
/// strip exposes itself as one adjustable element driven by the arrow keys, and the two step
/// buttons beside it provide full-size pointer targets.
struct TickStrip: View {
    @ObservedObject var store: Store
    @Binding var selection: DayKey
    var onHover: (DayKey?) -> Void

    private let windowSize = 30
    private let tickWidth: CGFloat = 4
    private let tickGap: CGFloat = 3
    private let minTick: CGFloat = 4
    private let maxTick: CGFloat = 20

    /// A continuous run of calendar days ending today, so gaps read as gaps.
    private var days: [DayKey] {
        let calendar = Calendar.current
        let today = Date()
        return (0..<windowSize).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { DayKey($0) }
        }
    }

    private var busiest: Int {
        max(days.map { store.count(on: $0) }.max() ?? 1, 1)
    }

    private var pitch: CGFloat { tickWidth + tickGap }
    private var stripWidth: CGFloat {
        CGFloat(windowSize) * pitch - tickGap
    }

    private func day(atX x: CGFloat) -> DayKey? {
        let list = days
        let index = Int((x / pitch).rounded(.down))
        return list.indices.contains(index) ? list[index] : nil
    }

    private func height(for day: DayKey) -> CGFloat {
        let count = store.count(on: day)
        // The selected day always shows a substantial bar, even when it holds nothing.
        guard count > 0 else { return day == selection ? 12 : minTick }
        let ratio = CGFloat(count) / CGFloat(busiest)
        return max(minTick + (maxTick - minTick) * ratio, day == selection ? 12 : minTick)
    }

    var body: some View {
        HStack(spacing: 8) {
            stepButton(symbol: "chevron.left", label: "Día anterior", delta: -1)

            // Ticks share one bottom baseline and grow upward, so height reads as quantity
            // the way a bar chart does. Centering them turned the row into noise.
            //
            // The strip takes an exact width from the day count rather than a GeometryReader,
            // which is greedy inside an HStack and was pushing the trailing step button
            // off the edge of the popover.
            HStack(alignment: .bottom, spacing: tickGap) {
                ForEach(days) { day in
                    tick(for: day)
                }
            }
            .frame(width: stripWidth, height: 28, alignment: .bottomLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    onHover(day(atX: point.x))
                case .ended:
                    onHover(nil)
                }
            }
            .onTapGesture { point in
                if let day = day(atX: point.x) { selection = day }
            }

            stepButton(symbol: "chevron.right", label: "Día siguiente", delta: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Navegación por día")
        .accessibilityValue(DayFormat.long(selection))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func tick(for day: DayKey) -> some View {
        let isSelected = day == selection
        let pending = store.hasPending(on: day)
        let empty = store.count(on: day) == 0

        // Selection speaks the strip's own language: a wider, full-ink bar. The detached
        // dot this replaced hung below the shared baseline and read as an exclamation
        // mark. The wider bar overflows its slot symmetrically so the tap math, which
        // assumes a uniform pitch, stays exact.
        RoundedRectangle(cornerRadius: tickWidth / 2, style: .continuous)
            .fill(isSelected ? Theme.ink : (pending ? Theme.accent : Theme.inkTertiary))
            .opacity(isSelected ? 1 : (pending ? 0.9 : (empty ? 0.22 : 0.45)))
            .frame(width: isSelected ? 6 : tickWidth, height: height(for: day))
            .frame(width: tickWidth)
    }

    private func stepButton(symbol: String, label: String, delta: Int) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 26, height: 26)
                // Vertical only: sideways would collide with the strip's own hit area.
                .contentShape(Rectangle().size(width: 26, height: 30).offset(y: -2))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
        .help(label)
    }

    private func step(_ delta: Int) {
        guard let date = selection.date,
              let moved = Calendar.current.date(byAdding: .day, value: delta, to: date)
        else { return }
        // Never walk into the future.
        let next = DayKey(moved)
        if next <= .today { selection = next }
    }
}

// MARK: - Day naming

enum DayFormat {
    private static let weekdaysLong = ["domingo", "lunes", "martes", "miércoles",
                                       "jueves", "viernes", "sábado"]
    private static let months = ["ene", "feb", "mar", "abr", "may", "jun",
                                 "jul", "ago", "sep", "oct", "nov", "dic"]

    private static func weekdayIndex(_ day: DayKey) -> Int? {
        guard let date = day.date else { return nil }
        return Calendar.current.component(.weekday, from: date) - 1
    }

    /// `Hoy · lunes 10` · `Ayer · domingo 9` · `Viernes 8 ago`
    /// One grammar and one capitalisation across the three cases: weekday, then day number.
    static func long(_ day: DayKey) -> String {
        let today = DayKey.today
        let yesterday = Calendar.current
            .date(byAdding: .day, value: -1, to: Date())
            .map { DayKey($0) }

        if day == today {
            if let index = weekdayIndex(day) {
                return "Hoy · \(weekdaysLong[index]) \(day.day)"
            }
            return "Hoy"
        }
        if day == yesterday {
            if let index = weekdayIndex(day) {
                return "Ayer · \(weekdaysLong[index]) \(day.day)"
            }
            return "Ayer"
        }
        let name = weekdayIndex(day).map { weekdaysLong[$0].capitalized } ?? ""
        return "\(name) \(day.day) \(months[max(0, min(11, day.month - 1))])"
    }

    /// `ago 2026`
    static func monthYear(_ day: DayKey) -> String {
        "\(months[max(0, min(11, day.month - 1))]) \(day.year)"
    }
}
