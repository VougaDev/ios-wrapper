import UIKit
import XCTest
@testable import VougaDevDocuments
@testable import VougaDevShell

final class DocumentsTests: XCTestCase {

    override func tearDown() { DocumentsInbox.forget() }

    func testANameKeepsNoPathNorControlCharacters() {
        XCTAssertEqual(DocumentsInbox.cleanName("/private/var/Inbox/contrat.pdf", fallback: "x"), "contrat.pdf")
        XCTAssertEqual(DocumentsInbox.cleanName("..\\a\u{0} b.pdf", fallback: "x"), "a b.pdf")
        XCTAssertEqual(DocumentsInbox.cleanName("  ", fallback: "document-1"), "document-1")
        XCTAssertEqual(DocumentsInbox.cleanName(String(repeating: "n", count: 500), fallback: "x").count, 200)
    }

    func testSharedFilesAreTakenOnceAndOnlyTheTypesAndSizesTheSiteTakes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("bail.pdf"), zip = dir.appendingPathComponent("x.zip"), big = dir.appendingPathComponent("big.png")
        try Data("%PDF-1.4 x".utf8).write(to: pdf)
        try Data("PK".utf8).write(to: zip)
        try Data(count: 2048).write(to: big)
        let config = DocumentsConfig(receivePath: "/assistant/receive/", maxBytes: 1024)
        XCTAssertEqual(DocumentsInbox.receive([pdf, zip, big], config: config), 1)
        let files = DocumentsInbox.take()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0]["name"] as? String, "bail.pdf")
        XCTAssertEqual(files[0]["type"] as? String, "application/pdf")
        XCTAssertEqual((files[0]["data"] as? String).flatMap { Data(base64Encoded: $0) }, Data("%PDF-1.4 x".utf8))
        XCTAssertTrue(DocumentsInbox.take().isEmpty)
    }

    func testScannedPagesMakeOnePDFWithAPageEach() {
        let page = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1100)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1100))
        }
        let data = DocumentsInbox.pdf([page, page])
        XCTAssertEqual(String(decoding: data.prefix(5), as: UTF8.self), "%PDF-")
        XCTAssertEqual(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages, 2)
        XCTAssertEqual(DocumentsInbox.stamp(Date(timeIntervalSince1970: 0)).count, "1970-01-01 00.00".count)
    }

    func testTheScanNameIsTranslated() {
        for (lang, expected) in [("en", "Scan %@"), ("fr", "Document scanné %@"), ("es", "Documento escaneado %@")] {
            let bundle = Bundle(path: DocumentsResources.bundle.path(forResource: lang, ofType: "lproj")!)!
            XCTAssertEqual(bundle.localizedString(forKey: "documents_scan_name", value: nil, table: nil), expected)
        }
    }
}
