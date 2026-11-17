import AppKit
import Foundation
import OrganizerCore
import PDFKit
import Vision

struct RecognitionJob: Sendable {
    var path: String
    var fileName: String
    var contentClass: String
    var kind: String
    var projectTag: String
    var tags: [String]
}

enum MacTextExtractor {
    /// 只读这个文件本身。不读 OpenClaw 的配置，也不把密钥样子的路径送出去。
    static func extract(path: String) -> String {
        let name = PathKey.name(path)
        guard RecognitionKind.accepts(name: name, path: path) else { return "" }
        let ext = PathKey.fileExtension(name)
        switch ext {
        case "txt", "md", "markdown":
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
            return DocumentText.plain(data)
        case "docx":
            guard let data = unzipData(archive: path, entry: "word/document.xml"),
                  let xml = String(data: data, encoding: .utf8) else { return "" }
            return DocumentText.fromDocumentXML(xml)
        case "pdf":
            return pdfText(url: URL(fileURLWithPath: path))
        case "pages":
            return pagesText(path)
        default:
            if RecognitionKind.imageExtensions.contains(ext) {
                return ocr(url: URL(fileURLWithPath: path))
            }
            return ""
        }
    }

    private static func pagesText(_ path: String) -> String {
        let package = URL(fileURLWithPath: path)
        let preview = package.appendingPathComponent("QuickLook/Preview.pdf")
        if FileManager.default.fileExists(atPath: preview.path) {
            return pdfText(url: preview)
        }
        guard let data = unzipData(archive: path, entry: "QuickLook/Preview.pdf") else { return "" }
        return pdfText(data: data)
    }

    private static func pdfText(url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        return document.string ?? ""
    }

    private static func pdfText(data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return document.string ?? ""
    }

    private static func ocr(url: URL) -> String {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func unzipData(archive: String, entry: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive, entry]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
