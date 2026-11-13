import SwiftUI
import AVFoundation
import VisionKit
import Vision
import ImageIO
import EntrixyCore

struct QRScannerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var problem: String?
    let onResult: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    EmptyScreen(image: "icon-key", title: "Камера недоступна", detail: "Вставьте ссылку или выберите фотографию QR-кода.")
                } else if permission == .authorized && DataScannerViewController.isAvailable {
                    ScannerView(onResult: onResult, onError: { problem = $0 })
                        .overlay(alignment: .bottom) {
                            Text(problem ?? "Наведите камеру на QR-код гостевого ключа")
                                .font(.subheadline).padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
                        }
                } else if permission == .authorized {
                    EmptyScreen(image: "icon-key", title: "Камера временно недоступна", detail: "Выберите фотографию QR-кода или вставьте ссылку.")
                } else if permission == .notDetermined {
                    ProgressView("Запрашиваем доступ к камере")
                } else {
                    VStack(spacing: 20) {
                        Text("Разрешите доступ к камере в настройках iPhone или выберите фотографию QR-кода.")
                            .multilineTextAlignment(.center)
                        Button("Открыть настройки") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(PrimaryActionStyle())
                    }.padding(32)
                }
            }
            .navigationTitle("Сканировать QR").navigationBarTitleDisplayMode(.inline)
            .sheetDismissFooter("Закрыть") { dismiss() }
            .onChange(of: phase) { value in
                if value == .active { permission = AVCaptureDevice.authorizationStatus(for: .video) }
            }
            .task {
                if DataScannerViewController.isSupported && permission == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    permission = AVCaptureDevice.authorizationStatus(for: .video)
                }
            }
        }.tint(Brand.primary)
    }
}

private struct ScannerView: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult, onError: onError) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
            isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        DispatchQueue.main.async {
            do { try scanner.startScanning() }
            catch { onError("Не удалось запустить камеру. Выберите фотографию QR-кода.") }
        }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onResult: (String) -> Void
        let onError: (String) -> Void
        var delivered = false
        init(onResult: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onResult = onResult
            self.onError = onError
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            accept(addedItems)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            accept(updatedItems)
        }
        private func accept(_ items: [RecognizedItem]) {
            guard !delivered else { return }
            for item in items {
                guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue else { continue }
                guard let text = try? AccessLink.incomingText(value) else {
                    onError("Этот QR-код не содержит поддерживаемый гостевой ключ Entrixy.")
                    continue
                }
                delivered = true
                onResult(text)
                return
            }
        }
    }
}

enum QRPhotoReader {
    enum Failure: Error { case noCode }
    static func read(_ bytes: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw Failure.noCode }
            // Older supported Vision revisions provide a fallback when a newer
            // image-processing implementation is unavailable on this OS/device.
            var lastError: Error?
            let revisions = [VNDetectBarcodesRequest.defaultRevision, 1]
            var attempted = Set<Int>()
            for revision in revisions where attempted.insert(revision).inserted && VNDetectBarcodesRequest.supportedRevisions.contains(revision) {
                let request = VNDetectBarcodesRequest()
                request.revision = revision
                request.symbologies = [.qr]
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    for result in request.results ?? [] {
                        if let value = result.payloadStringValue, let text = try? AccessLink.incomingText(value) { return text }
                    }
                } catch { lastError = error }
            }
            if let lastError { throw lastError }
            throw Failure.noCode
        }.value
    }
}
