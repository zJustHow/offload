import Foundation
import Vision

public enum OCR {
    /// Text recognized in an encoded image (JPEG/PNG), top to bottom, one line per row.
    public static func recognize(imageData: Data) throws -> String { try recognize(handler: VNImageRequestHandler(data: imageData)) }

    /// Text recognized in an image file.
    public static func recognize(url: URL) throws -> String { try recognize(handler: VNImageRequestHandler(url: url)) }

    private static func recognize(handler: VNImageRequestHandler) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try handler.perform([request])
        // Vision reports bottom-left-origin boxes; sort top-to-bottom so reading order is kept.
        let observations = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
