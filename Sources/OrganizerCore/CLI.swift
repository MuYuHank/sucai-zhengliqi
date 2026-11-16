public import Foundation

public enum CLIParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingCommand
    case unknownCommand(String)
    case missingValue(String)
    case missingRequired(String)
    case invalidNumber(String)

    public var description: String {
        switch self {
        case .missingCommand:
            return "请指定命令。可用：scan、apply、undo、index、runs、pack、report、version、help。"
        case .unknownCommand(let command):
            return "不认识命令 \(command)。可用：scan、apply、undo、index、runs、pack、report、version、help。"
        case .missingValue(let flag):
            return "参数 \(flag) 后面缺少值。"
        case .missingRequired(let name):
            return "缺少 \(name)。"
        case .invalidNumber(let raw):
            return "不是有效数字：\(raw)"
        }
    }
}

public struct ScanFlags: Equatable, Sendable {
    public var roots: [String]
    public var library: String
    public var json: Bool
    public var minConfidence: Double?
    public var includeUnknown: Bool?
    public var maxDepth: Int?
}

public struct ApplyFlags: Equatable, Sendable {
    public var library: String
    public var planPath: String?
    public var confirm: Bool
    public var dryRun: Bool
    public var selectedIDs: Set<String>?
}

public struct UndoFlags: Equatable, Sendable {
    public var library: String
    public var runID: String
}

public struct IndexFlags: Equatable, Sendable {
    public var library: String
    public var query: String
    public var csv: Bool
}

public struct RunsFlags: Equatable, Sendable {
    public var library: String
}

public struct PackFlags: Equatable, Sendable {
    public var library: String
    public var project: String
    public var output: String
}

public struct ReportFlags: Equatable, Sendable {
    public var library: String
    public var desktop: String?
    public var write: Bool
}

public enum CLICommand: Equatable, Sendable {
    case help
    case version
    case scan(ScanFlags)
    case apply(ApplyFlags)
    case undo(UndoFlags)
    case index(IndexFlags)
    case runs(RunsFlags)
    case pack(PackFlags)
    case report(ReportFlags)
}

public struct CLIResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first, !command.isEmpty else { throw CLIParseError.missingCommand }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "-h", "--help":
            return .help
        case "version", "--version":
            return .version
        case "scan":
            return .scan(try parseScan(rest))
        case "apply":
            return .apply(try parseApply(rest))
        case "undo":
            return .undo(try parseUndo(rest))
        case "index":
            return .index(try parseIndex(rest))
        case "runs":
            return .runs(try parseRuns(rest))
        case "pack":
            return .pack(try parsePack(rest))
        case "report":
            return .report(try parseReport(rest))
        default:
            throw CLIParseError.unknownCommand(command)
        }
    }

    public static let helpText = """
    \(organizerName) \(organizerVersion)
    找出、识别、分类并在确认后移动 AI 生成的产物。不会删除文件。每个产物库的第一次 apply 是演练。

    用法：
      chanwu scan --root 路径 [--root 路径] --library 产物库 [--json] [--min-confidence 0.7] [--include-unknown] [--max-depth 8]
      chanwu apply --library 产物库 [--plan 清单.json] --confirm [--dry-run] [--select id,id]
      chanwu undo --library 产物库 --run 记录ID
      chanwu index --library 产物库 [--query 关键词] [--csv]
      chanwu runs --library 产物库
      chanwu pack --library 产物库 --project 项目标签 --output 交付.zip
      chanwu report --library 产物库 [--desktop 桌面路径] [--write]
      chanwu version

    \(Copy.neverDeletes)
    """

    private static func parseScan(_ args: [String]) throws -> ScanFlags {
        var roots: [String] = []
        var library = ""
        var json = false
        var minConfidence: Double?
        var includeUnknown: Bool?
        var maxDepth: Int?
        var index = 0
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--root":
                roots.append(try value(args, &index, flag))
            case "--library":
                library = try value(args, &index, flag)
            case "--json":
                json = true
            case "--include-unknown":
                includeUnknown = true
            case "--min-confidence":
                minConfidence = try double(try value(args, &index, flag))
            case "--max-depth":
                maxDepth = try int(try value(args, &index, flag))
            default:
                throw CLIParseError.unknownCommand(flag)
            }
            index += 1
        }
        if roots.isEmpty { throw CLIParseError.missingRequired("至少一个 --root") }
        if library.isEmpty { throw CLIParseError.missingRequired("--library") }
        return ScanFlags(roots: roots, library: library, json: json, minConfidence: minConfidence, includeUnknown: includeUnknown, maxDepth: maxDepth)
    }

    private static func parseApply(_ args: [String]) throws -> ApplyFlags {
        var library = ""
        var planPath: String?
        var confirm = false
        var dryRun = false
        var selected: Set<String>?
        var index = 0
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--library":
                library = try value(args, &index, flag)
            case "--plan":
                planPath = try value(args, &index, flag)
            case "--confirm":
                confirm = true
            case "--dry-run":
                dryRun = true
            case "--select":
                let raw = try value(args, &index, flag)
                selected = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            default:
                throw CLIParseError.unknownCommand(flag)
            }
            index += 1
        }
        if library.isEmpty { throw CLIParseError.missingRequired("--library") }
        return ApplyFlags(library: library, planPath: planPath, confirm: confirm, dryRun: dryRun, selectedIDs: selected)
    }

    private static func parseUndo(_ args: [String]) throws -> UndoFlags {
        var library = ""
        var runID = ""
        var index = 0
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--library":
                library = try value(args, &index, flag)
            case "--run":
                runID = try value(args, &index, flag)
            default:
                throw CLIParseError.unknownCommand(flag)
            }
            index += 1
        }
        if library.isEmpty { throw CLIParseError.missingRequired("--library") }
        if runID.isEmpty { throw CLIParseError.missingRequired("--run") }
        return UndoFlags(library: library, runID: runID)
    }

    private static func parseIndex(_ args: [String]) throws -> IndexFlags {
        var library = ""
        var query = ""
        var csv = false
        var index = 0
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--library":
                library = try value(args, &index, flag)
            case "--query":
                query = try value(args, &index, flag)
            case "--csv":
                csv = true
            default:
                throw CLIParseError.unknownCommand(flag)
            }
            index += 1
        }
        if library.isEmpty { throw CLIParseError.missingRequired("--library") }
        return IndexFlags(library: library, query: query, csv: csv)
    }

    private static func parseRuns(_ args: [String]) throws -> RunsFlags {
        var library = ""
        var index = 0
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--library":
                library = try value(args, &index, flag)
            default:
                throw CLIParseError.unknownCommand(flag)
            }
            index += 1
        }
        if library.isEmpty { throw CLIParseError.missingRequired("--library") }
        return RunsFlags(library: library)
    }

    private static func parsePack(_ args: [String]) throws -> PackFlags {
        var library = ""
        var project = ""
        var output = ""
        var index = 0
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--library":
                library = try value(args, &index, flag)
            case "--project":
                project = try value(args, &index, flag)
            case "--output":
                output = try value(args, &index, flag)
            default:
                throw CLIParseError.unknownCommand(flag)
            }
            index += 1
        }
        if library.isEmpty { throw CLIParseError.missingRequired("--library") }
        if project.isEmpty { throw CLIParseError.missingRequired("--project") }
        if output.isEmpty { throw CLIParseError.missingRequired("--output") }
        return PackFlags(library: library, project: project, output: output)
    }

    private static func parseReport(_ args: [String]) throws -> ReportFlags {
        var library = ""
        var desktop: String?
        var write = false
        var index = 0
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--library":
                library = try value(args, &index, flag)
            case "--desktop":
                desktop = try value(args, &index, flag)
            case "--write":
                write = true
            default:
                throw CLIParseError.unknownCommand(flag)
            }
            index += 1
        }
        if library.isEmpty { throw CLIParseError.missingRequired("--library") }
        return ReportFlags(library: library, desktop: desktop, write: write)
    }

    private static func value(_ args: [String], _ index: inout Int, _ flag: String) throws -> String {
        let next = index + 1
        guard next < args.count else { throw CLIParseError.missingValue(flag) }
        index = next
        return args[next]
    }

    private static func double(_ raw: String) throws -> Double {
        guard let value = Double(raw) else { throw CLIParseError.invalidNumber(raw) }
        return value
    }

    private static func int(_ raw: String) throws -> Int {
        guard let value = Int(raw) else { throw CLIParseError.invalidNumber(raw) }
        return value
    }
}

public enum CLIRunner {
    public static func run(
        _ command: CLICommand,
        store: any FileStore,
        now: Date = Date(),
        runID: String = UUID().uuidString
    ) -> CLIResult {
        let organizer = Organizer(store: store)
        switch command {
        case .help:
            return CLIResult(exitCode: 0, stdout: CLIParser.helpText, stderr: "")
        case .version:
            return CLIResult(exitCode: 0, stdout: "\(organizerName) \(organizerVersion)", stderr: "")
        case .scan(let flags):
            return scan(flags, organizer: organizer, store: store, now: now)
        case .apply(let flags):
            return apply(flags, organizer: organizer, store: store, now: now, runID: runID)
        case .undo(let flags):
            return undo(flags, organizer: organizer, now: now, runID: runID)
        case .index(let flags):
            return index(flags, store: store)
        case .runs(let flags):
            return runs(flags, store: store)
        case .pack(let flags):
            return pack(flags, store: store, now: now)
        case .report(let flags):
            return report(flags, store: store, now: now)
        }
    }

    private static func scan(_ flags: ScanFlags, organizer: Organizer, store: any FileStore, now: Date) -> CLIResult {
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = flags.library
        preferences.scanRoots = flags.roots
        var state = (try? StateStore.load(library: flags.library, store: store, now: now)) ?? .fresh(now: now)
        if let value = flags.minConfidence { preferences.minimumConfidence = value }
        if let value = flags.includeUnknown { preferences.includeUnidentifiedMedia = value }
        if let value = flags.maxDepth { preferences.maxDepth = value }
        state = state.applying(preferences)
        let plan = organizer.scanAndPlan(preferences: preferences, state: state, now: now, desk: DeskConfig.standard())
        do {
            try PlanStore.save(plan, store: store)
        } catch {
            return CLIResult(exitCode: 3, stdout: "", stderr: String(describing: error))
        }
        if flags.json {
            let data = (try? JSONFiles.data(plan)) ?? Data()
            return CLIResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
        return CLIResult(exitCode: 0, stdout: ReportText.plan(plan), stderr: "")
    }

    private static func apply(_ flags: ApplyFlags, organizer: Organizer, store: any FileStore, now: Date, runID: String) -> CLIResult {
        guard flags.confirm else {
            return CLIResult(exitCode: 2, stdout: "", stderr: OrganizerError.confirmationRequired.description)
        }
        let plan: MovePlan
        do {
            plan = try PlanStore.load(library: flags.library, store: store, path: flags.planPath)
        } catch {
            return CLIResult(exitCode: 3, stdout: "", stderr: String(describing: error))
        }
        var state = (try? StateStore.load(library: plan.libraryRoot, store: store, now: now)) ?? .fresh(now: now)
        let selected = flags.selectedIDs ?? plan.preselectedIDs
        let request = ExecuteRequest.make(
            confirmed: true,
            planFingerprint: plan.fingerprint,
            selectedIDs: selected,
            intendToApply: !flags.dryRun,
            moveOnly: true
        )
        do {
            let record = try organizer.execute(plan: plan, request: request, state: &state, now: now, runID: runID)
            return CLIResult(exitCode: 0, stdout: ReportText.run(record), stderr: "")
        } catch {
            return CLIResult(exitCode: 4, stdout: "", stderr: String(describing: error))
        }
    }

    private static func undo(_ flags: UndoFlags, organizer: Organizer, now: Date, runID: String) -> CLIResult {
        do {
            let record = try organizer.undo(runID: flags.runID, library: flags.library, now: now, undoID: runID)
            return CLIResult(exitCode: 0, stdout: ReportText.run(record), stderr: "")
        } catch {
            return CLIResult(exitCode: 5, stdout: "", stderr: String(describing: error))
        }
    }

    private static func index(_ flags: IndexFlags, store: any FileStore) -> CLIResult {
        do {
            let catalog = try IndexStore.load(library: flags.library, store: store)
            if flags.csv {
                return CLIResult(exitCode: 0, stdout: IndexStore.csv(catalog), stderr: "")
            }
            let entries = IndexStore.search(catalog, query: flags.query)
            if entries.isEmpty { return CLIResult(exitCode: 0, stdout: "索引里没有匹配的文件。", stderr: "") }
            let lines = entries.map { "\($0.fileName)\t\($0.source.displayName)\t\($0.kind.displayName)\t\($0.relativePath)" }
            return CLIResult(exitCode: 0, stdout: lines.joined(separator: "\n"), stderr: "")
        } catch {
            return CLIResult(exitCode: 3, stdout: "", stderr: String(describing: error))
        }
    }

    private static func runs(_ flags: RunsFlags, store: any FileStore) -> CLIResult {
        do {
            let records = try RunArchive.loadAll(library: flags.library, store: store)
            return CLIResult(exitCode: 0, stdout: ReportText.runs(records), stderr: "")
        } catch {
            return CLIResult(exitCode: 3, stdout: "", stderr: String(describing: error))
        }
    }

    private static func pack(_ flags: PackFlags, store: any FileStore, now: Date) -> CLIResult {
        // 不覆盖已有文件：本工具承诺不删除任何东西，覆盖也算。
        if store.exists(flags.output) {
            return CLIResult(exitCode: 2, stdout: "", stderr: "\(flags.output) 已经存在，没有覆盖。请换一个 --output 路径。")
        }
        let catalog: Catalog
        do {
            catalog = try IndexStore.load(library: flags.library, store: store)
        } catch {
            return CLIResult(exitCode: 3, stdout: "", stderr: String(describing: error))
        }
        let matches = catalog.entries.filter { entry in
            let tag = entry.meta?.projectTag ?? ""
            guard !tag.isEmpty, sameProject(tag, flags.project) else { return false }
            return !entry.relativePath.contains("历史版本")
        }
        if matches.isEmpty {
            return CLIResult(exitCode: 2, stdout: "", stderr: "这个项目标签下没有可打包的归档文件。")
        }
        var files: [(relativePath: String, data: Data)] = []
        for entry in matches.sorted(by: { $0.relativePath < $1.relativePath }) {
            let path = PathKey.joining(flags.library, entry.relativePath)
            guard let data = try? store.readFile(path, maxBytes: Int.max) else { continue }
            files.append((entry.relativePath, data))
        }
        if files.isEmpty {
            return CLIResult(exitCode: 3, stdout: "", stderr: "文件读不出来，没有打包。")
        }
        let packed = DeliveryPack.make(project: flags.project, files: files, now: now)
        do {
            try store.writeFile(flags.output, data: packed.zip)
        } catch {
            return CLIResult(exitCode: 3, stdout: "", stderr: String(describing: error))
        }
        return CLIResult(exitCode: 0, stdout: "已打包 \(files.count) 个文件到 \(flags.output)。清单含 SHA256。", stderr: "")
    }

    private static func report(_ flags: ReportFlags, store: any FileStore, now: Date) -> CLIResult {
        let catalog: Catalog
        do {
            catalog = try IndexStore.load(library: flags.library, store: store)
        } catch {
            return CLIResult(exitCode: 3, stdout: "", stderr: String(describing: error))
        }
        let digest = WeeklyReports.digest(WeeklyReports.files(catalog: catalog, library: flags.library), now: now)
        if !flags.write {
            return CLIResult(exitCode: 0, stdout: digest.markdown, stderr: "")
        }
        let desktop = flags.desktop ?? flags.library
        do {
            let path = try WeeklyReports.write(digest, desktop: desktop, now: now, store: store)
            return CLIResult(exitCode: 0, stdout: digest.markdown + "\n\n已写入 \(path)", stderr: "")
        } catch {
            return CLIResult(exitCode: 3, stdout: digest.markdown, stderr: String(describing: error))
        }
    }

    private static func sameProject(_ stored: String, _ requested: String) -> Bool {
        stored.compare(requested, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }
}
