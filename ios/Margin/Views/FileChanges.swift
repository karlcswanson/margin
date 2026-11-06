import SwiftUI

/// One file's uncommitted changes, read-only: hunks with line numbers and
/// syntax colouring, the way code review shows them.
struct FileDiffView: View {
    let file: DiffFile

    var body: some View {
        let lang = Highlighter.language(forPath: file.path)
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if file.binary {
                    Text("Binary file changed").font(Theme.Fonts.caption).foregroundStyle(.secondary).padding(12)
                }
                ForEach(file.hunks) { h in
                    Text(h.header).font(Theme.Fonts.code).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.06))
                    let colored = Highlighter.hunk(h.lines.map { ($0.kind, $0.text) }, language: lang)
                    ForEach(Array(h.lines.enumerated()), id: \.element.id) { i, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text(line.old.map(String.init) ?? "").frame(width: 44, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(line.new.map(String.init) ?? "").frame(width: 44, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(String(line.kind == "+" ? "+" : line.kind == "-" ? "−" : " "))
                                .frame(width: 22)
                                .foregroundStyle(line.kind == "+" ? .green : line.kind == "-" ? .red : .secondary)
                            Text(colored[i])
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        .font(Theme.Fonts.code)
                        .padding(.vertical, 1)
                        .background(line.kind == "+" ? Color.green.opacity(0.12)
                                    : line.kind == "-" ? Color.red.opacity(0.12) : .clear)
                    }
                }
            }
            .frame(minWidth: 700, alignment: .leading)
            .padding(.vertical, 8)
        }
    }
}

/// Last commit and now, side by side, for things a text diff can't show:
/// renders, models, PDFs, schematics and boards.
struct BeforeAfter<Before: View, After: View>: View {
    let isNew: Bool
    @ViewBuilder let before: Before
    @ViewBuilder let after: After

    var body: some View {
        HStack(spacing: 1) {
            pane("Last commit") {
                if isNew {
                    ContentUnavailableView("New file", systemImage: "plus.square.dashed",
                                           description: Text("Not in the last commit."))
                } else {
                    before
                }
            }
            pane("Now") { after }
        }
        .background(Color(uiColor: .separator))
    }

    private func pane<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0) {
            Text(title).font(Theme.Fonts.meta.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(.bar)
            c().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }
}
