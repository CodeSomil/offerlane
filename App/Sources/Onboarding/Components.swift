import SwiftUI
import CoreImage.CIFilterBuiltins

/// A labelled text field with an inline error underneath.
struct FieldRow: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var error: String? = nil
    var secure = false
    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .frame(width: 190, alignment: .trailing).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if secure { SecureField(prompt, text: $text) } else { TextField(prompt, text: $text) }
                }
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}

/// Editable chips: type and press Return to add, click × to remove.
struct ChipsField: View {
    let title: String
    @Binding var items: [String]
    var prompt = "Add…"
    var normalize: (String) -> String = { $0 }
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 4) {
                        Text(item).lineLimit(1)
                        Button { items.removeAll { $0 == item } } label: { Image(systemName: "xmark").font(.caption2.bold()) }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(item)")
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                TextField(prompt, text: $draft)
                    .textFieldStyle(.plain).frame(minWidth: 140)
                    .onSubmit { add() }
                    .accessibilityLabel("Add to \(title)")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        }
    }
    private func add() {
        for part in draft.split(separator: ",") {
            let v = normalize(part.trimmingCharacters(in: .whitespaces))
            if !v.isEmpty && !items.contains(v) { items.append(v) }
        }
        draft = ""
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600; var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x + z.width > width && x > 0 { x = 0; y += row + spacing; row = 0 }
            x += z.width + spacing; row = max(row, z.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x + z.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z)); x += z.width + spacing; row = max(row, z.height)
        }
    }
}

enum QRCode {
    static func image(_ text: String, size: CGFloat = 180) -> NSImage? {
        let f = CIFilter.qrCodeGenerator(); f.message = Data(text.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: size / out.extent.width, y: size / out.extent.height))
        let rep = NSCIImageRep(ciImage: scaled); let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }
}
