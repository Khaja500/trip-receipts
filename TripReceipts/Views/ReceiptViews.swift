import SwiftUI
import VisionKit
import PDFKit
import QuickLook

/// The iOS document camera — edge detection and auto-crop come for free, which
/// is what makes scanning a crumpled bill in a cab actually work.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        let dismiss: () -> Void

        init(onFinish: @escaping ([UIImage]) -> Void, dismiss: @escaping () -> Void) {
            self.onFinish = onFinish
            self.dismiss = dismiss
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            onFinish(images)
            dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            dismiss()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            dismiss()
        }
    }
}

struct ReceiptRow: View {
    let receipt: ReceiptFile
    let payment: Payment
    @State private var showViewer = false

    var body: some View {
        Button {
            showViewer = true
        } label: {
            HStack(spacing: 12) {
                thumbnail
                    .frame(width: 44, height: 56)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                VStack(alignment: .leading, spacing: 3) {
                    Text(receipt.filename)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(receipt.addedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    matchLabel
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showViewer) {
            ReceiptViewer(receipt: receipt)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if receipt.isPDF {
            if let page = ReceiptOCR.pageImages(fromPDF: receipt.data, limit: 1).first {
                Image(uiImage: UIImage(cgImage: page)).resizable().scaledToFill()
            } else {
                Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary)
            }
        } else if let image = UIImage(data: receipt.data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }

    /// The read total is a hint, never a correction — so it says what it saw
    /// and leaves the amount alone.
    @ViewBuilder
    private var matchLabel: some View {
        if let ocrTotal = receipt.ocrTotal {
            let matches = receipt.matchesPaymentTotal == true
            Label(
                matches
                    ? "Total \(Money.string(ocrTotal, currency: payment.currency)) — matches"
                    : "Total read as \(Money.string(ocrTotal, currency: payment.currency))",
                systemImage: matches ? "checkmark.circle.fill" : "questionmark.circle"
            )
            .font(.caption2)
            .foregroundStyle(matches ? .green : .orange)
        } else if receipt.ocrText?.isEmpty == false {
            Text("No total found on the receipt")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ReceiptViewer: View {
    let receipt: ReceiptFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if receipt.isPDF {
                    PDFKitView(data: receipt.data)
                } else if let image = UIImage(data: receipt.data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                } else {
                    ContentUnavailableView("Cannot show this file", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle(receipt.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(data: data)
        view.autoScales = true
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document == nil { view.document = PDFDocument(data: data) }
    }
}
