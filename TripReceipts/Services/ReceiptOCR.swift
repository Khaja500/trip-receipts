import Foundation
import Vision
import PDFKit
import UIKit

/// Reads a receipt on-device and looks for its total. The result is a hint
/// only — it never changes the payment amount, because a misread total on a
/// claim is worse than no total at all.
enum ReceiptOCR {

    struct Reading {
        var text: String
        var total: Double?
    }

    static func read(data: Data, isPDF: Bool) async -> Reading {
        let images: [CGImage]
        if isPDF {
            images = pageImages(fromPDF: data, limit: 3)
        } else if let image = UIImage(data: data)?.cgImage {
            images = [image]
        } else {
            images = []
        }

        var lines: [String] = []
        for image in images {
            lines.append(contentsOf: await recognise(image))
        }
        let text = lines.joined(separator: "\n")
        return Reading(text: text, total: total(in: lines))
    }

    private static func recognise(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-IN", "en-US"]

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([request])

                let observations = request.results ?? []
                continuation.resume(returning: observations.compactMap {
                    $0.topCandidates(1).first?.string
                })
            }
        }
    }

    static func pageImages(fromPDF data: Data, limit: Int) -> [CGImage] {
        guard let document = PDFDocument(data: data) else { return [] }
        var images: [CGImage] = []
        for index in 0..<min(limit, document.pageCount) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.cgContext.translateBy(x: 0, y: size.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            if let cgImage = image.cgImage { images.append(cgImage) }
        }
        return images
    }

    /// Lives in `ReceiptTotalReader` so the rule can be checked on its own.
    static func total(in lines: [String]) -> Double? {
        ReceiptTotalReader.total(in: lines)
    }
}
