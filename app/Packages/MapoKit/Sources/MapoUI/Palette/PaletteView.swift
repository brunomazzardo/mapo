import AppKit
import SwiftUI

/// The ⌘K palette's content (UX §10, D-28): the field row, then the sections and their rows.
struct PaletteView: View {
    let model: PaletteModel
    let field: NSTextField
    let onRun: (Int) -> Void

    static let fieldHeight: CGFloat = 44
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 24
    static let listPadding: CGFloat = 6
    static let emptyHeight: CGFloat = 76
    static let maximumHeight: CGFloat = 480

    /// The height that fits the content, up to 480.
    static func height(groups: Int, rows: Int, query: String) -> CGFloat {
        let list: CGFloat
        if rows == 0 {
            list = query.isEmpty ? 0 : emptyHeight
        } else {
            list = listPadding * 2 + CGFloat(groups) * headerHeight + CGFloat(rows) * rowHeight
        }
        return min(maximumHeight, fieldHeight + 1 + list)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(nsColor: Tokens.textSecondary))
                    .accessibilityHidden(true)
                PaletteFieldView(field: field)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.fieldHeight)
            Rectangle()
                .fill(Color(nsColor: Tokens.paneHairline))
                .frame(height: 1)
            if model.rows.isEmpty {
                if !model.query.isEmpty { empty }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No matches for \"\(model.query)\"")
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: Tokens.textBody))
            Text("Try a tab, workspace, recent file or command name.")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Tokens.textSecondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .frame(height: Self.emptyHeight)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups) { group in
                        Text(group.section.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(nsColor: Tokens.textSecondary))
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: Self.headerHeight, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.rows) { row in
                            PaletteRowView(row: row, selected: row.id == model.selection)
                                .id(row.id)
                                .onTapGesture { onRun(row.id) }
                        }
                    }
                }
                .padding(Self.listPadding)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, selection in
                proxy.scrollTo(selection)
            }
        }
    }
}

/// One row: icon, title with the matched characters in semibold accent, subtitle and trailing text.
private struct PaletteRowView: View {
    let row: PaletteRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.icon)
                .font(.system(size: 13))
                .frame(width: 16, height: 16)
                .foregroundStyle(Color(nsColor: selected ? Tokens.iconSelected : Tokens.icon))
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .layoutPriority(1)
            if !row.subtitle.isEmpty {
                Text(row.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(
                        Color(nsColor: selected ? Tokens.textSecondaryOnSelection : Tokens.textSecondary)
                    )
                    .lineLimit(1)
                    .truncationMode(row.section == .recentFiles ? .head : .tail)
            }
            Spacer(minLength: 8)
            if !row.trailing.isEmpty {
                Text(row.trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(
                        Color(nsColor: selected ? Tokens.textSecondaryOnSelection : Tokens.textSecondary)
                    )
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color(nsColor: Tokens.selection) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(AXID.paletteRow(row.id))
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var title: AttributedString {
        var result = AttributedString()
        let matched = Set(row.matched)
        for (offset, character) in row.title.enumerated() {
            var piece = AttributedString(String(character))
            piece.foregroundColor = Color(nsColor: Tokens.textBody)
            if matched.contains(offset) {
                piece.foregroundColor = Color(nsColor: Tokens.accent)
                piece.font = .system(size: 13, weight: .semibold)
            }
            result += piece
        }
        return result
    }
}

/// The AppKit field in the SwiftUI row, so it is a real first responder that `ui type` and `ui wait
/// --state focused` see (`palette.field`).
private struct PaletteFieldView: NSViewRepresentable {
    let field: NSTextField

    func makeNSView(context: Context) -> NSTextField {
        field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}
}
