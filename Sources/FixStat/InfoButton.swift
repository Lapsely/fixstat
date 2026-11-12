import SwiftUI
import FixStatCore

/// A small ⓘ next to a term: a click shows what the value is and how to read it.
@available(macOS 14.0, *)
struct InfoButton: View {
    let term: Glossary.Term
    @State private var shown = false

    init(_ term: Glossary.Term) {
        self.term = term
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Explanation"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(verbatim: Glossary.explanation(term))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(14)
        }
    }
}

@available(macOS 14.0, *)
extension View {
    /// Puts an ⓘ for `term` after this view (nothing when `term` is nil).
    @ViewBuilder func info(_ term: Glossary.Term?) -> some View {
        if let term {
            HStack(spacing: 4) {
                self
                InfoButton(term)
            }
        } else {
            self
        }
    }
}
