import Foundation
import Vision
import ImageIO

// Read-only foreground proof for simulator PNGs. This tool is not bundled in the app.
func normalized(_ value: String) -> String {
    let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
    return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
}

guard CommandLine.arguments.count >= 3 else { exit(2) }
do {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(2) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ru-RU", "en-US"]
    request.usesLanguageCorrection = false
    request.usesCPUOnly = true
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let text = normalized((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
    let missing = CommandLine.arguments.dropFirst(2).filter { group in
        !group.split(separator: "|").contains { text.contains(normalized(String($0))) }
    }
    let result: [String: Any] = ["matched": missing.isEmpty, "missing": Array(missing)]
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
    exit(missing.isEmpty ? 0 : 1)
} catch {
    fputs("Capture text verification failed: \(error)\n", stderr)
    exit(2)
}
