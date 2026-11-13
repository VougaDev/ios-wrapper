import UIKit
import UniformTypeIdentifiers
import VisionKit
import VougaDevShell

/// THE `documents` EXTENSION: what Safari cannot hand a page. Its members of `window.VougaDevNative`:
///
/// ```
/// scanDocument() -> Promise<{ok: true, file: {name, type, size, data}} | {ok: false, error}>
/// sharedFiles()  -> Promise<{ok: true, files: [{name, type, size, data}]}>
/// ```
///
/// `scanDocument()` opens Apple's document camera (VisionKit: edges found, pages straightened, several pages) and gives
/// one PDF, `data` in base64; errors `cancelled`, `unavailable` (no camera), `too_large` or `busy`. `sharedFiles()` hands
/// over, once, the files another app opened in this one (the share sheet's "Open in", Files, Mail): the app declares
/// them in its `CFBundleDocumentTypes` (`LSSupportsOpeningDocumentsInPlace` false) and passes its scene's file URLs to
/// [receive], which keeps them and opens [DocumentsConfig.receivePath]. Needs `NSCameraUsageDescription`.
@MainActor
public final class DocumentsExtension: NSObject, ShellExtension {

    public let name = "documents"
    public let config: DocumentsConfig
    private var waiting: ((JSONObject) -> Void)?

    public init(config: DocumentsConfig) { self.config = config }

    public var requirements: ShellRequirements { ShellRequirements(purposeStrings: ["NSCameraUsageDescription"]) }

    public func bridgeMethods(host: ShellHost) -> [(String, NativeBridge.Method)] {
        [
            ("scanDocument", { [weak self, weak host] _, answer in
                guard let self, let host else { return answer(NativeBridge.refused(NativeShim.errorUnavailable)) }
                guard self.waiting == nil else { return answer(NativeBridge.refused("busy")) }
                guard VNDocumentCameraViewController.isSupported else { return answer(NativeBridge.refused("unavailable")) }
                self.waiting = answer
                let camera = VNDocumentCameraViewController()
                camera.delegate = self
                host.presenter.present(camera, animated: true)
            }),
            ("sharedFiles", { _, answer in
                var result = NativeBridge.ok()
                result["files"] = DocumentsInbox.take()
                answer(result)
            }),
        ]
    }

    /// The files another app opened in this one (the scene's `openURLContexts`, or its connection options at a cold
    /// start): kept for the page, then [DocumentsConfig.receivePath] opens - after the sign-in when there is none.
    public func receive(_ urls: [URL], shell: ShellViewController) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard DocumentsInbox.receive(files, config: config) > 0 else { return }
        shell.openWhenReady(shell.session.origin.baseURL + config.receivePath)
    }

    public func signOut() async { DocumentsInbox.forget() }

    private func finish(_ result: JSONObject, _ camera: VNDocumentCameraViewController) {
        let answer = waiting
        waiting = nil
        camera.dismiss(animated: true) { answer?(result) }
    }
}

extension DocumentsExtension: VNDocumentCameraViewControllerDelegate {
    public nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
        MainActor.assumeIsolated {
            let pdf = DocumentsInbox.pdf(pages)
            guard pdf.count <= self.config.maxBytes else { return self.finish(NativeBridge.refused("too_large"), controller) }
            let stamp = DocumentsInbox.stamp(Date())
            let name = String(format: ShellStrings.text("documents_scan_name", bundle: .module), stamp) + ".pdf"
            var result = NativeBridge.ok()
            result["file"] = DocumentsInbox.payload(name: name, type: "application/pdf", data: pdf)
            self.finish(result, controller)
        }
    }

    public nonisolated func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        MainActor.assumeIsolated { self.finish(NativeBridge.refused("cancelled"), controller) }
    }

    public nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.finish(NativeBridge.refused("unavailable"), controller) }
    }
}

/// The `documents` extension of one app.
///
/// - `receivePath`: the same-origin page opened for files another app shared; it takes them with `sharedFiles()`.
/// - `types`: the media types taken (the app's `CFBundleDocumentTypes` declare the same).
/// - `maxBytes`: the largest file taken, the site's own limit.
public struct DocumentsConfig {
    public var receivePath: String
    public var types: Set<String>
    public var maxBytes: Int

    public static let defaultTypes: Set<String> = [
        "application/pdf", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "image/jpeg", "image/png", "image/webp",
    ]

    public init(receivePath: String, types: Set<String> = DocumentsConfig.defaultTypes, maxBytes: Int = 30 * 1024 * 1024) {
        self.receivePath = receivePath
        self.types = types
        self.maxBytes = maxBytes
    }
}

/// The extension's resource bundle, for tests and tools.
public enum DocumentsResources {
    public static let bundle = Bundle.module
}
