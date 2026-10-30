//
//  PillSidebar.swift
//  Consolation
//
//  The narrow Liquid Glass pill of icons on the leading edge. Written app-agnostic (no app types) so it can move
//  into a shared UI package.
//

import SwiftUI

/// Where an item sits in the pill: the main group, or after the divider at the end (Settings).
enum PillPlacement: Sendable {
    case main
    case trailing
}

/// One item the pill can show.
protocol PillItem: Hashable, Identifiable, Sendable {
    var title: LocalizedStringResource { get }
    var systemImage: String { get }
    var placement: PillPlacement { get }
}

/// A vertical (or, in compact widths, horizontal) capsule of icon buttons with a sliding selection indicator.
struct PillSidebar<Item: PillItem>: View {
    /// How much wider the pill gets while it shows titles (the title column plus its spacing).
    static var titleWidth: CGFloat { 244 }

    let items: [Item]
    @Binding var selection: Item
    var axis: Axis = .vertical
    var badged: Set<Item> = []
    /// tvOS: which pill item has focus (the host moves focus here on Back). Selection follows focus.
    var focus: FocusState<Item?>.Binding?
    /// tvOS: while the pill has focus it shows each item's title beside its icon.
    var showsTitles = false
    /// tvOS: while content has focus the pill recedes to a dimmed icon strip.
    var isDimmed = false
    /// Mac: the pill as a whole has keyboard focus (the host's own focus target), so the selected item shows a
    /// focus ring.
    var showsFocusRing = false
    /// Select on the item that is already selected (on Apple TV, where selection follows focus, every Select in the
    /// pill): the host moves focus into the pane.
    var onReselect: (() -> Void)?

    @Namespace private var indicator
    @Environment(\.shellLayout) private var shellLayout

    private var layout: AnyLayout {
        axis == .vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
    }

    var body: some View {
        GlassEffectContainer {
            layout {
                ForEach(items.filter { $0.placement == .main }) { item in
                    button(for: item)
                }
                if items.contains(where: { $0.placement == .trailing }) {
                    divider
                    ForEach(items.filter { $0.placement == .trailing }) { item in
                        button(for: item)
                    }
                }
            }
            .padding(8)
            .glassEffect(.regular, in: showsTitles ? AnyShape(.rect(cornerRadius: 28)) : AnyShape(.capsule))
        }
        .opacity(isDimmed ? 0.6 : 1)
        .animation(.smooth(duration: 0.25), value: showsTitles)
        .animation(.smooth(duration: 0.25), value: isDimmed)
    }

    private var divider: some View {
        Capsule()
            .fill(.secondary.opacity(0.35))
            .frame(width: axis == .vertical ? 22 : 1, height: axis == .vertical ? 1 : 22)
            .padding(4)
    }

    private func button(for item: Item) -> some View {
        Button {
            if selection == item, let onReselect {
                onReselect()
            } else {
                withAnimation(.smooth(duration: 0.3)) { selection = item }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.systemImage)
                    .font(.system(size: shellLayout.pillIconSize, weight: .medium))
                    .frame(width: shellLayout.pillButtonSize, height: shellLayout.pillButtonSize)
                if showsTitles {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 240, alignment: .leading)
                }
            }
            // The selected item is marked by its tinted capsule; the icon stays primary (black or white) so it keeps
            // its contrast against the tint.
            .foregroundStyle(.primary)
            .background {
                if selection == item {
                    Capsule()
                        .fill(.tint.opacity(0.28))
                        .matchedGeometryEffect(id: "selection", in: indicator)
                }
            }
            .overlay {
                if showsFocusRing && selection == item {
                    Capsule().strokeBorder(.tint, lineWidth: 2.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if badged.contains(item) {
                    Circle().fill(.tint).frame(width: 7, height: 7).offset(x: -5, y: 5)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(PillFocus(focus: focus, item: item))
        .accessibilityIdentifier("pill.\(String(describing: item.id))")
        .help(Text(item.title))
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(selection == item ? .isSelected : [])
    }
}

/// Binds an item to the pill's focus state when the host provides one (tvOS).
private struct PillFocus<Item: Hashable>: ViewModifier {
    let focus: FocusState<Item?>.Binding?
    let item: Item

    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus, equals: item)
        } else {
            content
        }
    }
}
