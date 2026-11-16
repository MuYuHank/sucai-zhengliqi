public import Foundation

public enum Identifier {
    public static func identify(
        name: String,
        parentNames: [String],
        sniffPrefix: Data,
        sniffSuffix: Data,
        sidecarJSON: String?,
        sidecarText: String?,
        userRules: [UserRule]
    ) -> Identification {
        let kind = MediaKind.detect(name: name, prefix: sniffPrefix)
        var clues: [Clue] = []

        for rule in userRules where rule.enabled {
            let keyword = rule.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard keyword.count >= 2 else { continue }
            let hitName = name.range(of: keyword, options: .caseInsensitive) != nil
            let hitParent = parentNames.contains { $0.range(of: keyword, options: .caseInsensitive) != nil }
            if hitName || hitParent {
                let forcedKind = rule.kind ?? kind
                clues.append(Clue(
                    source: rule.source,
                    confidence: 0.99,
                    evidence: "用户规则「\(keyword)」",
                    priority: 0,
                    kind: forcedKind
                ))
            }
        }

        if let sidecarJSON, !sidecarJSON.isEmpty {
            if looksLikeComfyWorkflow(sidecarJSON) {
                clues.append(Clue(source: .comfyUI, confidence: 0.96, evidence: "旁路 JSON 含 ComfyUI 工作流", priority: 1, kind: nil))
            }
        }
        if let sidecarText, !sidecarText.isEmpty {
            if looksLikeAutomatic1111(sidecarText) {
                clues.append(Clue(source: .stableDiffusion, confidence: 0.95, evidence: "旁路文本含采样参数", priority: 1, kind: nil))
            }
        }

        clues.append(contentsOf: MetadataSniffer.clues(prefix: sniffPrefix, suffix: sniffSuffix).map {
            Clue(source: $0.source, confidence: $0.confidence, evidence: $0.evidence, priority: 1, kind: nil)
        })

        let loweredName = name.lowercased()
        for rule in filenameRules where containsToken(loweredName, rule.token.lowercased()) || (rule.literal && loweredName.contains(rule.token.lowercased())) {
            clues.append(Clue(source: rule.source, confidence: rule.confidence, evidence: "文件名带有来源标记 \(rule.source.displayName)", priority: 2, kind: nil))
        }

        let loweredParents = parentNames.map { $0.lowercased() }
        for rule in parentRules where loweredParents.contains(rule.name) {
            clues.append(Clue(source: rule.source, confidence: rule.confidence, evidence: "父文件夹名为 \(rule.source.displayName)", priority: 3, kind: nil))
        }

        guard let best = clues.max(by: { lhs, rhs in
            if abs(lhs.confidence - rhs.confidence) > 0.000_000_1 {
                return lhs.confidence < rhs.confidence
            }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return false
        }) else {
            let confidence = kind.isLooseMedia ? 0.35 : 0.05
            return Identification(
                source: .unknown,
                kind: kind,
                confidence: confidence,
                evidence: ["没有匹配的来源标记"]
            )
        }

        var evidence: [String] = []
        for clue in clues.sorted(by: { $0.confidence > $1.confidence }) {
            if !evidence.contains(clue.evidence) {
                evidence.append(clue.evidence)
            }
            if evidence.count == 6 { break }
        }
        return Identification(
            source: best.source,
            kind: best.kind ?? kind,
            confidence: best.confidence,
            evidence: evidence
        )
    }

    static func looksLikeComfyWorkflow(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard lowered.contains("\"nodes\"") || lowered.contains("class_type") else { return false }
        return lowered.contains("widgets_values") || lowered.contains("class_type") || lowered.contains("ksampler") || lowered.contains("comfy")
    }

    static func looksLikeAutomatic1111(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("steps:") && lowered.contains("sampler:")
    }
}

extension MediaKind {
    public static func detect(name: String, prefix: Data) -> MediaKind {
        let ext = PathKey.fileExtension(name)
        if let mapped = extensionMap[ext] { return mapped }
        return magicKind(prefix) ?? .other
    }

    private static let extensionMap: [String: MediaKind] = {
        var map: [String: MediaKind] = [:]
        let groups: [(MediaKind, [String])] = [
            (.image, ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp", "avif", "exr", "psd", "svg"]),
            (.video, ["mp4", "mov", "webm", "mkv", "avi", "m4v"]),
            (.audio, ["mp3", "wav", "flac", "m4a", "ogg", "aac", "aiff", "aif"]),
            (.document, ["pdf", "doc", "docx", "pages", "numbers", "key", "ppt", "pptx", "xls", "xlsx", "rtf"]),
            (.text, ["txt", "md", "markdown", "csv", "tsv", "json"]),
            (.code, ["swift", "py", "js", "ts", "tsx", "jsx", "css", "html", "sh", "go", "rs", "java", "kt", "c", "cpp", "h", "m", "mm"]),
            (.model, ["safetensors", "ckpt", "pt", "pth", "onnx", "gguf"]),
            (.subtitle, ["srt", "vtt", "ass"]),
            (.mesh, ["obj", "stl", "glb", "gltf", "fbx", "usdz", "blend"]),
            (.archive, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg"]),
        ]
        for (kind, extensions) in groups {
            for ext in extensions { map[ext] = kind }
        }
        return map
    }()

    private static func magicKind(_ prefix: Data) -> MediaKind? {
        let bytes = [UInt8](prefix.prefix(64))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .image }
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return .image
        }
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x41, 0x56, 0x45] {
            return .audio
        }
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return .video }
        if bytes.starts(with: Array("%PDF".utf8)) { return .document }
        if bytes.starts(with: Array("OggS".utf8)) { return .audio }
        if bytes.starts(with: Array("ID3".utf8)) { return .audio }
        return nil
    }
}

struct SniffClue: Equatable {
    var source: SourceTool
    var confidence: Double
    var evidence: String
}

enum MetadataSniffer {
    static func clues(prefix: Data, suffix: Data) -> [SniffClue] {
        var found: [SniffClue] = []
        let texts = pngTexts(prefix) + pngTexts(suffix)
        for text in texts {
            found.append(contentsOf: clues(in: text))
        }
        if found.isEmpty {
            let window = lossyString(prefix) + "\n" + lossyString(suffix)
            found.append(contentsOf: clues(in: window))
        }
        return found
    }

    static func pngTexts(_ data: Data) -> [String] {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes.prefix(8)) == signature else { return [] }
        var offset = 8
        var texts: [String] = []
        while offset + 12 <= bytes.count {
            let length = Int(be32(bytes, offset))
            let typeStart = offset + 4
            let dataStart = offset + 8
            let dataEnd = dataStart + length
            let crcEnd = dataEnd + 4
            if length < 0 || crcEnd > bytes.count { break }
            let type = String(bytes: bytes[typeStart..<dataStart], encoding: .ascii) ?? ""
            let chunk = Data(bytes[dataStart..<dataEnd])
            if type == "tEXt" || type == "iTXt" {
                texts.append(lossyString(chunk))
            }
            offset = crcEnd
            if type == "IEND" { break }
        }
        return texts
    }

    private static func clues(in text: String) -> [SniffClue] {
        var found: [SniffClue] = []
        let lowered = text.lowercased()
        if Identifier.looksLikeComfyWorkflow(text) || lowered.contains("comfyui") {
            found.append(SniffClue(source: .comfyUI, confidence: 0.93, evidence: "文件内含 ComfyUI 标记"))
        }
        if Identifier.looksLikeAutomatic1111(text) {
            found.append(SniffClue(source: .stableDiffusion, confidence: 0.93, evidence: "PNG 文本块含 Stable Diffusion 参数"))
        }
        if lowered.contains("midjourney") {
            found.append(SniffClue(source: .midjourney, confidence: 0.9, evidence: "文件内含 Midjourney 标记"))
        }
        if lowered.contains("novelai") {
            found.append(SniffClue(source: .novelAI, confidence: 0.9, evidence: "文件内含 NovelAI 标记"))
        }
        if lowered.contains("invokeai") {
            found.append(SniffClue(source: .invokeAI, confidence: 0.9, evidence: "文件内含 InvokeAI 标记"))
        }
        return found
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func lossyString(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

private struct Clue {
    var source: SourceTool
    var confidence: Double
    var evidence: String
    var priority: Int
    var kind: MediaKind?
}

private struct NameRule {
    var token: String
    var source: SourceTool
    var confidence: Double
    var literal: Bool = false
}

private let filenameRules: [NameRule] = [
    NameRule(token: "midjourney", source: .midjourney, confidence: 0.86),
    NameRule(token: "dall-e", source: .chatGPT, confidence: 0.88),
    NameRule(token: "dalle", source: .chatGPT, confidence: 0.86),
    NameRule(token: "gpt-image", source: .chatGPT, confidence: 0.9),
    NameRule(token: "chatgpt", source: .chatGPT, confidence: 0.84),
    NameRule(token: "comfyui", source: .comfyUI, confidence: 0.88),
    NameRule(token: "stable-diffusion", source: .stableDiffusion, confidence: 0.88),
    NameRule(token: "stablediffusion", source: .stableDiffusion, confidence: 0.86),
    NameRule(token: "sdxl", source: .stableDiffusion, confidence: 0.8),
    NameRule(token: "leonardo", source: .leonardo, confidence: 0.8),
    NameRule(token: "ideogram", source: .ideogram, confidence: 0.88),
    NameRule(token: "novelai", source: .novelAI, confidence: 0.9),
    NameRule(token: "nai-diffusion", source: .novelAI, confidence: 0.92),
    NameRule(token: "invokeai", source: .invokeAI, confidence: 0.9),
    NameRule(token: "可灵", source: .kling, confidence: 0.92, literal: true),
    NameRule(token: "kling", source: .kling, confidence: 0.82),
    NameRule(token: "runway", source: .runway, confidence: 0.8),
    NameRule(token: "dream-machine", source: .luma, confidence: 0.9),
    NameRule(token: "lumaai", source: .luma, confidence: 0.9),
    NameRule(token: "pika", source: .pika, confidence: 0.78),
    NameRule(token: "sora", source: .sora, confidence: 0.8),
    NameRule(token: "suno", source: .suno, confidence: 0.86),
    NameRule(token: "udio", source: .udio, confidence: 0.86),
    NameRule(token: "cursor-artifact", source: .cursor, confidence: 0.94),
    NameRule(token: "cursor_artifact", source: .cursor, confidence: 0.94),
    NameRule(token: "claude-artifact", source: .claude, confidence: 0.94),
    NameRule(token: "claude_artifact", source: .claude, confidence: 0.94),
    NameRule(token: "flux", source: .flux, confidence: 0.78),
]

private struct ParentRule {
    var name: String
    var source: SourceTool
    var confidence: Double
}

private let parentRules: [ParentRule] = [
    ParentRule(name: "comfyui", source: .comfyUI, confidence: 0.82),
    ParentRule(name: "comfy", source: .comfyUI, confidence: 0.74),
    ParentRule(name: "stable-diffusion-webui", source: .stableDiffusion, confidence: 0.88),
    ParentRule(name: "automatic1111", source: .stableDiffusion, confidence: 0.88),
    ParentRule(name: "stable-diffusion", source: .stableDiffusion, confidence: 0.82),
    ParentRule(name: "midjourney", source: .midjourney, confidence: 0.86),
    ParentRule(name: "chatgpt", source: .chatGPT, confidence: 0.8),
    ParentRule(name: "dall-e", source: .chatGPT, confidence: 0.86),
    ParentRule(name: "suno", source: .suno, confidence: 0.86),
    ParentRule(name: "udio", source: .udio, confidence: 0.86),
    ParentRule(name: "kling", source: .kling, confidence: 0.82),
    ParentRule(name: "runway", source: .runway, confidence: 0.8),
    ParentRule(name: "novelai", source: .novelAI, confidence: 0.88),
    ParentRule(name: "ideogram", source: .ideogram, confidence: 0.88),
    ParentRule(name: "leonardo", source: .leonardo, confidence: 0.78),
    ParentRule(name: "flux", source: .flux, confidence: 0.76),
    ParentRule(name: "sora", source: .sora, confidence: 0.82),
    ParentRule(name: "pika", source: .pika, confidence: 0.76),
    ParentRule(name: "luma", source: .luma, confidence: 0.74),
    ParentRule(name: "invokeai", source: .invokeAI, confidence: 0.88),
]

private func containsToken(_ haystack: String, _ token: String) -> Bool {
    guard !token.isEmpty else { return false }
    var search = haystack[...]
    while let range = search.range(of: token) {
        let beforeOK: Bool
        if range.lowerBound == haystack.startIndex {
            beforeOK = true
        } else {
            let before = haystack[haystack.index(before: range.lowerBound)]
            beforeOK = !before.isLetter && !before.isNumber
        }
        let afterOK: Bool
        if range.upperBound == haystack.endIndex {
            afterOK = true
        } else {
            let after = haystack[range.upperBound]
            afterOK = !after.isLetter && !after.isNumber
        }
        if beforeOK && afterOK { return true }
        if range.upperBound == search.endIndex { break }
        search = search[range.upperBound...]
    }
    return false
}
