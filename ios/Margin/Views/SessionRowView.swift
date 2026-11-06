import SwiftUI

struct SessionRowView: View {
    let ws: WorkspaceState
    let row: SessionRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: ws.status(of: row.sessionId)).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(MarkdownBlocks.title(row.title)).lineLimit(2)
                HStack(spacing: 6) {
                    if let b = row.gitBranch, !b.isEmpty, b != "HEAD" {
                        Label(b, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                    }
                    if let d = row.date {
                        TimelineView(.everyMinute) { _ in Text(Self.ago(d, now: .now)) }
                    }
                    if ws.status(of: row.sessionId) == "active_elsewhere" { Text("open at desk") }
                }
                .font(Theme.Fonts.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let n = ws.pending(for: row.sessionId).count
            if n > 0 { Image(systemName: "hand.raised.fill").foregroundStyle(Theme.needsYou) }
            if !(ws.shows[row.sessionId] ?? []).isEmpty {
                Image(systemName: "eye.circle.fill").foregroundStyle(.tint)
                    .accessibilityLabel("Something to look at")
            }
        }
    }

    /// When it last changed, as short as a list wants it: 5m, 3h, 2d, Oct 28.
    static func ago(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86400: return "\(Int(s / 3600))h"
        case ..<(7 * 86400): return "\(Int(s / 86400))d"
        default: return d.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
