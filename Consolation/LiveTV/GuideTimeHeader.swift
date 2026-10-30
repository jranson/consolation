//
//  GuideTimeHeader.swift
//  Consolation
//
//  The guide grid's half-hour time header ("2:00 PM  2:30 PM  3:00 PM …") with a marker at the current time. It
//  is drawn before any guide data exists, so the grid area already reads as a guide.
//

import SwiftUI

/// The half-hour slots a header shows, starting with the one that contains `now`.
nonisolated enum GuideTimeSlots {
    static let slotLength: TimeInterval = 30 * 60

    static func slots(containing now: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        var start = parts
        start.minute = (parts.minute ?? 0) < 30 ? 0 : 30
        guard let first = calendar.date(from: start) else { return [] }
        return (0..<max(count, 0)).map { first.addingTimeInterval(Double($0) * slotLength) }
    }

    /// How far into the first slot `now` is, from 0 to 1.
    static func progress(of now: Date, in slot: Date) -> Double {
        min(max(now.timeIntervalSince(slot) / slotLength, 0), 1)
    }
}

struct GuideTimeHeader: View {
    @Environment(\.shellLayout) private var layout

    private var slotWidth: CGFloat { layout == .television ? 320 : 180 }

    var body: some View {
        TimelineView(.everyMinute) { context in
            GeometryReader { proxy in
                let count = Int((proxy.size.width / slotWidth).rounded(.up)) + 1
                let slots = GuideTimeSlots.slots(containing: context.date, count: count)
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(slots, id: \.self) { slot in
                            Text(slot, format: .dateTime.hour().minute())
                                .font(.callout.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                                .frame(width: slotWidth, alignment: .leading)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(.separator).frame(width: 1)
                                }
                        }
                    }
                    if let first = slots.first {
                        Capsule()
                            .fill(.tint)
                            .frame(width: 3)
                            .offset(x: slotWidth * GuideTimeSlots.progress(of: context.date, in: first))
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .clipped()
            }
        }
        .frame(height: layout == .television ? 52 : 34)
        .accessibilityElement(children: .combine)
    }
}
