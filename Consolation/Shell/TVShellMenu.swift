//
//  TVShellMenu.swift
//  Consolation
//
//  Apple TV's navigation, after Apple Music: collapsed, only a "‹ Home" header in the upper left says where you are
//  (the chevron matches the remote's Back button); Back opens the full menu over the dimmed content, where only up and
//  down move; Select switches to an item and closes the menu; Back in the open menu leaves the app. The focused item is
//  a plain white pill, with no lift or outer border.
//

#if os(tvOS)
import SwiftUI

/// The collapsed menu: where you are, never focusable.
struct TVMenuHeader<Item: PillItem>: View {
    let selection: Item

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Label {
                Text(selection.title).font(.body.weight(.semibold))
            } icon: {
                Image(systemName: selection.systemImage)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menu.header")
        .allowsHitTesting(false)
    }
}

/// The open menu: the app's name and the time, then every visible item; the current one has focus when it opens.
struct TVMenu<Item: PillItem>: View {
    let items: [Item]
    let selection: Item
    var badged: Set<Item> = []
    let focus: FocusState<Item?>.Binding
    /// Select on an item: the host switches to it and closes the menu.
    let onChoose: (Item) -> Void

    static var width: CGFloat { 360 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(AppIdentifier.name).font(.callout.weight(.semibold))
                Spacer()
                TimelineView(.everyMinute) { context in
                    Text(context.date, style: .time).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 12)
            ForEach(items) { item in
                Button {
                    onChoose(item)
                } label: {
                    TVMenuRow(item: item, isSelected: item == selection, isBadged: badged.contains(item))
                }
                .buttonStyle(TVMenuItemStyle())
                .focusEffectDisabled()
                .focused(focus, equals: item)
                .accessibilityIdentifier("pill.\(String(describing: item.id))")
                .accessibilityAddTraits(item == selection ? .isSelected : [])
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 40))
    }
}

private struct TVMenuRow<Item: PillItem>: View {
    let item: Item
    let isSelected: Bool
    let isBadged: Bool

    var body: some View {
        // Apple Music's sizes: body text, a small icon.
        HStack(spacing: 16) {
            Image(systemName: item.systemImage)
                .font(.system(size: 24, weight: .medium))
                .frame(width: 34)
            Text(item.title)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if isBadged {
                Circle().frame(width: 9, height: 9).accessibilityLabel("Playing")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// The focused row is a white pill with dark text; the others are plain.
private struct TVMenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVMenuItemBody(configuration: configuration)
    }
}

private struct TVMenuItemBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .background {
                if isFocused { Capsule().fill(.white) }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.15), value: isFocused)
    }
}
#endif
