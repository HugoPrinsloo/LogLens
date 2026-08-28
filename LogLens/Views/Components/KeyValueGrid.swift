import SwiftUI

struct KeyValueGrid: View {
    let fields: [ParsedMessage.Field]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(fields) { f in
                GridRow {
                    Text(f.key.isEmpty ? "•" : f.key)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(minWidth: 70, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                    Text(f.value)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
