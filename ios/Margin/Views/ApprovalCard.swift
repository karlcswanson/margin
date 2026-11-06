import SwiftUI

/// "Claude wants to run X" with Allow / Always / Deny (deny can carry a note,
/// typed or dictated, which Claude reads as feedback).
struct ApprovalCard: View {
    let ws: WorkspaceState
    let request: PermissionRequest
    @State private var busy = false
    @State private var showDenyNote = false
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.toolName, systemImage: icon).font(.headline)
            Text(request.summary)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(6)
                .textSelection(.enabled)
            if let d = request.description, !d.isEmpty, d != request.summary {
                Text(d).font(Theme.Fonts.caption).foregroundStyle(.secondary)
            }
            if showDenyNote {
                HStack {
                    TextField("Tell Claude what to do instead", text: $note, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    VoiceButton(text: $note)
                }
            }
            HStack {
                Button { decide(true) } label: { Label("Allow", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                if request.canAlwaysAllow == true {
                    Button("Always allow") { decide(true, always: true) }.buttonStyle(.bordered)
                }
                Spacer()
                if showDenyNote {
                    Button("Send", role: .destructive) { decide(false) }.buttonStyle(.bordered)
                } else {
                    Button("Deny…", role: .destructive) { showDenyNote = true }.buttonStyle(.bordered)
                }
            }
            .disabled(busy)
            if let error { Text(error).font(Theme.Fonts.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .background(Theme.needsYou.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner).stroke(Theme.needsYou.opacity(0.4)))
    }

    private var icon: String {
        switch request.toolName {
        case "Bash": return "terminal"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "pencil"
        case "WebFetch", "WebSearch": return "globe"
        default: return "hand.raised"
        }
    }

    private func decide(_ allow: Bool, always: Bool = false) {
        busy = true
        Task {
            do {
                try await ws.decide(request, allow: allow, always: always, message: allow ? nil : note)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
