import Foundation
#if canImport(XCTest)
import XCTest
#endif
@testable import OrganizerCore

final class HashAndSafetyTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testFileActionsNeverIncludeDelete() {
        let names = Set(FileAction.allCases.map(\.rawValue))
        XCTAssertEqual(names, ["wouldMove", "moved", "copiedSourceRetained", "skipped", "failed", "undone"])
        XCTAssertEqual(Set(RelocateKind.allCases.map(\.rawValue)), ["moved", "copiedSourceRetained"])
    }

    func testPathInsideDoesNotConfusePrefixes() {
        XCTAssertTrue(PathKey.isInsideOrEqual("/disk/lib/a", root: "/disk/lib"))
        XCTAssertTrue(PathKey.isInsideOrEqual("/disk/lib", root: "/disk/lib"))
        XCTAssertFalse(PathKey.isInsideOrEqual("/disk/library", root: "/disk/lib"))
        XCTAssertEqual(PathKey.normalize("/disk/../disk/./lib"), "/disk/lib")
        XCTAssertEqual(PathKey.joining("/disk/lib", "ComfyUI/图片/2026/11"), "/disk/lib/ComfyUI/图片/2026/11")
        XCTAssertEqual(PathKey.joining("/disk/lib", "../etc/passwd"), "/disk/lib/etc/passwd")
    }

    func testProtectedAndSanitizer() {
        XCTAssertTrue(Safety.isProtected("/"))
        XCTAssertTrue(Safety.isProtected("/usr/bin/swift"))
        XCTAssertFalse(Safety.isProtected("/disk/inbox/a.png"))
        XCTAssertEqual(Sanitizer.fileName("../etc/passwd"), "..etcpasswd")
        XCTAssertEqual(Sanitizer.fileName(".."), "未命名")
        XCTAssertEqual(Sanitizer.fileName(""), "未命名")
        let long = String(repeating: "a", count: 300) + ".png"
        XCTAssertLessThanOrEqual(Sanitizer.fileName(long).count, 180)
        XCTAssertTrue(Sanitizer.fileName(long).hasSuffix(".png"))
    }

    func testCopyIsChineseAndHonest() {
        XCTAssertTrue(Copy.firstRunNote.contains("演练"))
        XCTAssertTrue(Copy.firstRunNote.contains("未移动"))
        XCTAssertTrue(Copy.neverDeletes.contains("不会删除"))
        XCTAssertTrue(Copy.neverDeletes.contains("留在原处"))
        XCTAssertFalse(Copy.neverDeletes.contains("只复制"))
        XCTAssertTrue(Copy.appliedNote(moveOnly: false).contains("只复制"))
        XCTAssertTrue(Copy.neverDeletes(moveOnly: false).contains("只复制"))
        XCTAssertTrue(OrganizerError.confirmationRequired.description.contains("确认"))
    }
}

final class IdentifyTests: XCTestCase {
    func testFilenameSources() {
        let cases: [(String, SourceTool)] = [
            ("cat_midjourney_v6.png", .midjourney),
            ("dalle-3-city.png", .chatGPT),
            ("gpt-image-001.png", .chatGPT),
            ("comfyui_00012.png", .comfyUI),
            ("portrait_sdxl.png", .stableDiffusion),
            ("hero_flux.png", .flux),
            ("可灵_01.mp4", .kling),
            ("song_suno.mp3", .suno),
            ("clip_sora.mp4", .sora),
            ("cursor-artifact-note.swift", .cursor),
            ("claude-artifact.md", .claude),
            ("dream-machine-shot.mp4", .luma),
        ]
        for (name, source) in cases {
            let identification = Identifier.identify(name: name, parentNames: ["inbox"], sniffPrefix: Data(), sniffSuffix: Data(), sidecarJSON: nil, sidecarText: nil, userRules: [])
            XCTAssertEqual(identification.source, source, name)
            XCTAssertGreaterThanOrEqual(identification.confidence, 0.7, name)
        }
    }

    func testShortTokenDoesNotMatchInsideWords() {
        let identification = Identifier.identify(name: "sparkling.png", parentNames: [], sniffPrefix: Data(), sniffSuffix: Data(), sidecarJSON: nil, sidecarText: nil, userRules: [])
        XCTAssertEqual(identification.source, .unknown)
        let flux = Identifier.identify(name: "myflux.png", parentNames: [], sniffPrefix: Data(), sniffSuffix: Data(), sidecarJSON: nil, sidecarText: nil, userRules: [])
        XCTAssertEqual(flux.source, .unknown)
    }

    func testParentFolder() {
        let identification = Identifier.identify(name: "image.png", parentNames: ["Users", "me", "ComfyUI", "output"], sniffPrefix: Data(), sniffSuffix: Data(), sidecarJSON: nil, sidecarText: nil, userRules: [])
        XCTAssertEqual(identification.source, .comfyUI)
        XCTAssertEqual(identification.kind, .image)
        XCTAssertGreaterThanOrEqual(identification.confidence, 0.8)
    }

    func testPNGParametersAndSidecars() {
        let png = PNGFixture.png(chunks: [("parameters", "a cat\nSteps: 20, Sampler: Euler a, Seed: 1")])
        let fromPNG = Identifier.identify(name: "out.png", parentNames: ["Downloads"], sniffPrefix: png, sniffSuffix: Data(), sidecarJSON: nil, sidecarText: nil, userRules: [])
        XCTAssertEqual(fromPNG.source, .stableDiffusion)
        XCTAssertTrue(fromPNG.evidence.joined().contains("Stable Diffusion"))
        XCTAssertFalse(MetadataSniffer.pngTexts(png).isEmpty)

        let workflow = #"{"nodes":[{"type":"KSampler","widgets_values":[1]}],"version":0.4}"#
        let fromJSON = Identifier.identify(name: "frame.png", parentNames: ["out"], sniffPrefix: Data(), sniffSuffix: Data(), sidecarJSON: workflow, sidecarText: nil, userRules: [])
        XCTAssertEqual(fromJSON.source, .comfyUI)

        let text = "masterpiece\nSteps: 30, Sampler: DPM++ 2M, CFG scale: 7"
        let fromText = Identifier.identify(name: "frame.png", parentNames: ["out"], sniffPrefix: Data(), sniffSuffix: Data(), sidecarJSON: nil, sidecarText: text, userRules: [])
        XCTAssertEqual(fromText.source, .stableDiffusion)
    }

    func testMetadataBeatsWeakFilename() {
        let png = PNGFixture.png(chunks: [("parameters", "Steps: 10, Sampler: Euler")])
        let identification = Identifier.identify(name: "midjourney_but_local.png", parentNames: [], sniffPrefix: png, sniffSuffix: Data(), sidecarJSON: nil, sidecarText: nil, userRules: [])
        XCTAssertEqual(identification.source, .stableDiffusion)
        XCTAssertGreaterThan(identification.confidence, 0.9)
    }

    func testUserRuleOverridesAndIgnoresEmpty() {
        let rule = UserRule.make(id: "r1", keyword: "mybrand", source: .kling)
        let hit = Identifier.identify(name: "mybrand_01.png", parentNames: [], sniffPrefix: Data(), sniffSuffix: Data(), sidecarJSON: nil, sidecarText: nil, userRules: [rule])
        XCTAssertEqual(hit.source, .kling)
        XCTAssertEqual(hit.confidence, 0.99)
        let empty = UserRule.make(id: "r2", keyword: " ", source: .sora)
        let miss = Identifier.identify(name: "plain.png", parentNames: [], sniffPrefix: Data(), sniffSuffix: Data(), sidecarJSON: nil, sidecarText: nil, userRules: [empty, UserRule.make(id: "r3", keyword: "nope", source: .pika, enabled: false)])
        XCTAssertEqual(miss.source, .unknown)
    }

    func testMagicForExtensionlessPNG() {
        let png = PNGFixture.png(chunks: [])
        let kind = MediaKind.detect(name: "IMG0001", prefix: png)
        XCTAssertEqual(kind, .image)
        XCTAssertEqual(MediaKind.detect(name: "notes.txt", prefix: Data()), .text)
        XCTAssertEqual(MediaKind.detect(name: "weights.safetensors", prefix: Data()), .model)
    }

    func testPlanGate() {
        var state = LibraryState.fresh(now: Date(timeIntervalSince1970: 0))
        let known = Identification(source: .midjourney, kind: .image, confidence: 0.70, evidence: [])
        let low = Identification(source: .midjourney, kind: .image, confidence: 0.69, evidence: [])
        let unknownImage = Identification(source: .unknown, kind: .image, confidence: 0.35, evidence: [])
        let unknownCode = Identification(source: .unknown, kind: .code, confidence: 0.05, evidence: [])
        XCTAssertTrue(PlanGate.allows(known, state: state))
        XCTAssertFalse(PlanGate.allows(low, state: state))
        XCTAssertFalse(PlanGate.allows(unknownImage, state: state))
        state.includeUnidentifiedMedia = true
        XCTAssertTrue(PlanGate.allows(unknownImage, state: state))
        XCTAssertFalse(PlanGate.allows(unknownCode, state: state))
    }

    func testTruncatedPNGDoesNotThrow() {
        let broken = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
        XCTAssertTrue(MetadataSniffer.pngTexts(broken).isEmpty)
        _ = Identifier.identify(name: "x.png", parentNames: [], sniffPrefix: broken, sniffSuffix: Data("Steps: 1, Sampler: Euler".utf8), sidecarJSON: nil, sidecarText: nil, userRules: [])
    }
}

final class PipelineTests: XCTestCase {
    func testFullRehearsalApplyUndoAndSecondLibrary() throws {
        let disk = MemoryDisk()
        let when = shanghaiDate(year: 2026, month: 11, day: 16, hour: 9)
        try seedLibrary(disk, modified: when)
        let organizer = Organizer(store: disk)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/disk/lib"
        preferences.scanRoots = ["/disk/inbox"]
        var state = LibraryState.fresh(now: when)
        let plan = organizer.scanAndPlan(preferences: preferences, state: state, now: when)

        let names = Set(plan.proposed.map(\.fileName))
        XCTAssertTrue(names.contains("cat_midjourney.png"))
        XCTAssertTrue(names.contains("render.png"))
        XCTAssertTrue(names.contains("workflow.png"))
        XCTAssertFalse(names.contains("main.swift"))
        XCTAssertFalse(names.contains("midjourney_in_repo.png"))
        XCTAssertFalse(plan.items.contains { $0.fileName == "partial.png.crdownload" })
        XCTAssertFalse(plan.items.contains { $0.fileName == ".secret.png" })
        XCTAssertFalse(plan.items.contains { $0.fileName == "link.png" })
        XCTAssertFalse(plan.items.contains { $0.fileName == "empty_midjourney.png" })
        XCTAssertFalse(plan.items.contains { $0.fileName == "random.jpg" })
        XCTAssertTrue(plan.issues.contains { $0.message.contains("项目") })

        let midjourney = try XCTUnwrap(plan.proposed.first { $0.fileName == "cat_midjourney.png" })
        XCTAssertTrue(midjourney.destinationPath.contains("/Midjourney/图片/2026/11/"))
        let sd = try XCTUnwrap(plan.proposed.first { $0.fileName == "render.png" })
        XCTAssertEqual(sd.source, .stableDiffusion)
        let comfy = try XCTUnwrap(plan.proposed.first { $0.fileName == "workflow.png" })
        XCTAssertEqual(comfy.source, .comfyUI)
        XCTAssertTrue(plan.proposed.contains { $0.fileName == "repo_out_midjourney.png" })

        let sameName = plan.proposed.filter { $0.fileName.hasPrefix("dup") || $0.destinationPath.contains("dup") }
        XCTAssertEqual(plan.proposed.filter { $0.source == .suno }.count, 2)
        let sunoDestinations = Set(plan.proposed.filter { $0.source == .suno }.map(\.destinationPath))
        XCTAssertEqual(sunoDestinations.count, 2)
        XCTAssertTrue(sunoDestinations.contains { $0.hasSuffix("song_suno.mp3") })
        XCTAssertTrue(sunoDestinations.contains { $0.hasSuffix("song_suno (2).mp3") })
        _ = sameName

        try PlanStore.save(plan, store: disk)
        let loaded = try PlanStore.load(library: "/disk/lib", store: disk)
        XCTAssertEqual(loaded.fingerprint, plan.fingerprint)

        var tampered = loaded
        tampered.items[0].destinationPath = "/tmp/escaped.png"
        XCTAssertThrowsError(try PlanStore.save(tampered, store: disk))

        XCTAssertThrowsError(try organizer.execute(
            plan: plan,
            request: ExecuteRequest.make(confirmed: false, planFingerprint: plan.fingerprint, selectedIDs: Set(plan.proposed.map(\.id)), intendToApply: true),
            state: &state,
            now: when,
            runID: "run-dry"
        ))

        let rehearsal = try organizer.execute(
            plan: plan,
            request: ExecuteRequest.make(confirmed: true, planFingerprint: plan.fingerprint, selectedIDs: Set(plan.proposed.map(\.id)), intendToApply: true),
            state: &state,
            now: when,
            runID: "run-dry"
        )
        XCTAssertEqual(rehearsal.mode, .dryRun)
        XCTAssertTrue(rehearsal.note.contains("演练"))
        XCTAssertTrue(state.hasCompletedDryRun)
        XCTAssertNotNil(disk.storedData("/disk/inbox/cat_midjourney.png"))
        XCTAssertFalse(disk.exists("/disk/lib/Midjourney/图片/2026/11/cat_midjourney.png"))

        let other = LibraryState.fresh(now: when)
        XCTAssertFalse(other.hasCompletedDryRun)
        _ = other

        XCTAssertThrowsError(try organizer.execute(
            plan: plan,
            request: ExecuteRequest.make(confirmed: true, planFingerprint: "nope", selectedIDs: Set(plan.proposed.map(\.id)), intendToApply: true),
            state: &state,
            now: when,
            runID: "run-bad"
        ))
    }

    func testApplyUndoIndexAndCrossVolume() throws {
        let disk = MemoryDisk()
        let when = shanghaiDate(year: 2026, month: 1, day: 2, hour: 8)
        try disk.makeDirectory("/disk/inbox")
        try disk.makeDirectory("/other/inbox")
        try disk.writeFile("/disk/inbox/cat_midjourney.png", data: Data("png".utf8), modified: when)
        try disk.writeFile("/disk/inbox/locked_midjourney.png", data: Data("no".utf8), modified: when)
        try disk.writeFile("/other/inbox/remote_midjourney.png", data: Data("copy".utf8), modified: when)
        disk.pathsThatFailRelocate = ["/disk/inbox/locked_midjourney.png"]

        let organizer = Organizer(store: disk)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/disk/lib"
        preferences.scanRoots = ["/disk/inbox", "/other/inbox"]
        var state = LibraryState.fresh(now: when)
        state.hasCompletedDryRun = true
        let plan = organizer.scanAndPlan(preferences: preferences, state: state, now: when)
        XCTAssertEqual(plan.proposed.count, 3)
        XCTAssertTrue(plan.proposed.contains { $0.destinationPath.contains("/2026/01/") })

        let record = try organizer.execute(
            plan: plan,
            request: ExecuteRequest.make(confirmed: true, planFingerprint: plan.fingerprint, selectedIDs: Set(plan.proposed.map(\.id)), intendToApply: true),
            state: &state,
            now: when,
            runID: "run-apply"
        )
        XCTAssertEqual(record.mode, .applied)
        XCTAssertEqual(record.operations.filter { $0.action == .moved }.count, 1)
        XCTAssertEqual(record.operations.filter { $0.action == .copiedSourceRetained }.count, 1)
        XCTAssertEqual(record.operations.filter { $0.action == .failed }.count, 1)
        XCTAssertNil(disk.storedData("/disk/inbox/cat_midjourney.png"))
        XCTAssertNotNil(disk.storedData("/disk/lib/Midjourney/图片/2026/01/cat_midjourney.png"))
        XCTAssertEqual(disk.storedData("/other/inbox/remote_midjourney.png"), Data("copy".utf8))
        let remoteDest = try XCTUnwrap(plan.proposed.first { $0.fileName == "remote_midjourney.png" }?.destinationPath)
        XCTAssertTrue(disk.exists(remoteDest))

        let catalog = try IndexStore.load(library: "/disk/lib", store: disk)
        XCTAssertEqual(catalog.entries.count, 2)
        let found = IndexStore.search(catalog, query: "midjourney 图片")
        XCTAssertEqual(found.count, 2)
        let csv = IndexStore.csv(catalog)
        XCTAssertTrue(csv.contains("文件名,相对路径"))
        XCTAssertTrue(csv.contains("Midjourney"))

        let undo = try organizer.undo(runID: "run-apply", library: "/disk/lib", now: when, undoID: "run-undo")
        XCTAssertEqual(undo.mode, .undo)
        XCTAssertEqual(undo.undoOfRunID, "run-apply")
        XCTAssertEqual(disk.storedData("/disk/inbox/cat_midjourney.png"), Data("png".utf8))
        XCTAssertFalse(disk.exists("/disk/lib/Midjourney/图片/2026/01/cat_midjourney.png"))
        XCTAssertTrue(undo.operations.contains { $0.reason.contains("不会删除") || $0.reason.contains("副本") })
        XCTAssertEqual(disk.storedData("/other/inbox/remote_midjourney.png"), Data("copy".utf8))
        XCTAssertTrue(disk.exists(remoteDest))

        var after = try IndexStore.load(library: "/disk/lib", store: disk)
        IndexStore.reconcile(&after, library: "/disk/lib", store: disk)
        XCTAssertEqual(after.entries.count, 1)
        XCTAssertEqual(after.entries[0].fileName, "remote_midjourney.png")

        let second = try organizer.undo(runID: "run-apply", library: "/disk/lib", now: when, undoID: "run-undo-2")
        XCTAssertTrue(second.operations.contains { $0.action == .failed })
        XCTAssertEqual(disk.storedData("/disk/inbox/cat_midjourney.png"), Data("png".utf8))

        let undoOfUndo = try organizer.undo(runID: "run-undo", library: "/disk/lib", now: when, undoID: "run-undo-3")
        XCTAssertTrue(undoOfUndo.note.contains("没有可以撤销"))
        XCTAssertEqual(disk.storedData("/disk/inbox/cat_midjourney.png"), Data("png".utf8))
    }

    func testEmptySelectionDoesNotFinishFirstRunAndOptionalCanBeForced() throws {
        let disk = MemoryDisk()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try disk.makeDirectory("/disk/inbox")
        try disk.writeFile("/disk/inbox/maybe_sdxl.png", data: Data("x".utf8), modified: when)
        let organizer = Organizer(store: disk)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/disk/lib"
        preferences.scanRoots = ["/disk/inbox"]
        preferences.minimumConfidence = 0.95
        var state = LibraryState.fresh(now: when).applying(preferences)
        let plan = organizer.scanAndPlan(preferences: preferences, state: state, now: when)
        XCTAssertTrue(plan.proposed.isEmpty)
        XCTAssertEqual(plan.optionalItems.count, 1)

        let skipped = try organizer.execute(
            plan: plan,
            request: ExecuteRequest.make(confirmed: true, planFingerprint: plan.fingerprint, selectedIDs: [], intendToApply: true),
            state: &state,
            now: when,
            runID: "empty"
        )
        XCTAssertEqual(skipped.mode, .dryRun)
        XCTAssertFalse(state.hasCompletedDryRun)

        let rehearsed = try organizer.execute(
            plan: plan,
            request: ExecuteRequest.make(confirmed: true, planFingerprint: plan.fingerprint, selectedIDs: Set(plan.optionalItems.map(\.id)), intendToApply: false),
            state: &state,
            now: when,
            runID: "opt-dry"
        )
        XCTAssertEqual(rehearsed.operations.first?.action, .wouldMove)
        XCTAssertTrue(state.hasCompletedDryRun)
        XCTAssertTrue(disk.exists("/disk/inbox/maybe_sdxl.png"))

        let moved = try organizer.execute(
            plan: plan,
            request: ExecuteRequest.make(confirmed: true, planFingerprint: plan.fingerprint, selectedIDs: Set(plan.optionalItems.map(\.id)), intendToApply: true),
            state: &state,
            now: when,
            runID: "opt-apply"
        )
        XCTAssertEqual(moved.operations.first?.action, .moved)
        XCTAssertFalse(disk.exists("/disk/inbox/maybe_sdxl.png"))
    }

    func testUnknownMediaFlagProjectBoundaryAndProtectedRoot() throws {
        let disk = MemoryDisk()
        let when = shanghaiDate(year: 2026, month: 11, day: 16, hour: 1)
        try disk.makeDirectory("/disk/inbox")
        try disk.writeFile("/disk/inbox/random.jpg", data: Data("jpg".utf8), modified: when)
        try disk.writeFile("/usr/share/secret_midjourney.png", data: Data("no".utf8), modified: when)
        let organizer = Organizer(store: disk)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/disk/lib"
        preferences.scanRoots = ["/disk/inbox", "/usr"]
        var state = LibraryState.fresh(now: when)
        var plan = organizer.scanAndPlan(preferences: preferences, state: state, now: when)
        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue(plan.issues.contains { $0.path == "/usr" })

        preferences.includeUnidentifiedMedia = true
        state = state.applying(preferences)
        plan = organizer.scanAndPlan(preferences: preferences, state: state, now: when)
        XCTAssertEqual(plan.proposed.map(\.fileName), ["random.jpg"])
        XCTAssertEqual(plan.proposed[0].source, .unknown)
        XCTAssertTrue(plan.proposed[0].destinationPath.contains("/未识别/图片/2026/11/"))
    }

    func testSpecificFilesBlockedInsideLibraryAndWatchQueue() throws {
        let disk = MemoryDisk()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try disk.makeDirectory("/disk/lib/已在")
        try disk.writeFile("/disk/lib/已在/cat_midjourney.png", data: Data("in".utf8), modified: when)
        try disk.writeFile("/disk/inbox/new_midjourney.png", data: Data([0x89, 0x50, 0x4E, 0x47]), modified: when)
        let organizer = Organizer(store: disk)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/disk/lib"
        var state = LibraryState.fresh(now: when)
        state.hasCompletedDryRun = true
        let plan = organizer.planSpecificFiles(
            paths: ["/disk/lib/已在/cat_midjourney.png", "/disk/inbox/new_midjourney.png", "/disk/missing.png"],
            preferences: preferences,
            state: state,
            now: when
        )
        XCTAssertTrue(plan.blocked.contains { $0.reason.contains("素材库") })
        XCTAssertTrue(plan.proposed.contains { $0.fileName == "new_midjourney.png" })
        XCTAssertTrue(plan.issues.contains { $0.path == "/disk/missing.png" })

        var pending = PendingQueue.add(paths: ["/disk/inbox/a.png", "/disk/inbox/a.png", "/disk/inbox/b.png"], existing: [], limit: 2)
        XCTAssertEqual(pending, ["/disk/inbox/a.png", "/disk/inbox/b.png"])
        pending = PendingQueue.add(paths: ["/disk/inbox/c.png"], existing: pending, limit: 2)
        XCTAssertEqual(pending.count, 2)
        try PendingStore.save(paths: pending, library: "/disk/lib", store: disk)
        XCTAssertEqual(try PendingStore.load(library: "/disk/lib", store: disk), pending)

        var debouncer = WatchDebouncer(window: 0.8)
        debouncer.observe(path: "/disk/inbox/a.png", size: 10, at: when)
        debouncer.observe(path: "/disk/inbox/a.png", size: 12, at: when.addingTimeInterval(0.2))
        XCTAssertTrue(debouncer.settled(now: when.addingTimeInterval(0.5)).isEmpty)
        XCTAssertEqual(debouncer.settled(now: when.addingTimeInterval(1.1)), ["/disk/inbox/a.png"])
        XCTAssertEqual(debouncer.pendingCount, 0)
    }

    func testIndexSearchCSVAndPreferencesRoundTrip() throws {
        let disk = MemoryDisk()
        var catalog = Catalog.empty()
        let entry = IndexEntry(
            id: "1",
            relativePath: "ComfyUI/图片/2026/11/a \"b,c\".png",
            fileName: "a \"b,c\".png",
            source: .comfyUI,
            kind: .image,
            confidence: 0.9,
            bytes: 12,
            modifiedAt: Date(timeIntervalSince1970: 0),
            indexedAt: Date(timeIntervalSince1970: 0),
            originPath: "/in/a.png",
            evidence: ["旁路 JSON"]
        )
        IndexStore.upsert(&catalog, entry: entry)
        IndexStore.upsert(&catalog, entry: entry)
        XCTAssertEqual(catalog.entries.count, 1)
        try IndexStore.save(catalog, library: "/disk/lib", store: disk)
        let loaded = try IndexStore.load(library: "/disk/lib", store: disk)
        XCTAssertEqual(IndexStore.search(loaded, query: "comfy 图片").count, 1)
        XCTAssertTrue(IndexStore.search(loaded, query: "不存在").isEmpty)
        let csv = IndexStore.csv(loaded)
        XCTAssertTrue(csv.contains("\"a \"\"b,c\"\".png\""))
        var reconciled = loaded
        reconciled.entries.append(IndexEntry(id: "missing", relativePath: "no/such.png", fileName: "such.png", source: .unknown, kind: .image, confidence: 0.1, bytes: 1, modifiedAt: Date(timeIntervalSince1970: 0), indexedAt: Date(timeIntervalSince1970: 0), originPath: "/x", evidence: []))
        IndexStore.reconcile(&reconciled, library: "/disk/lib", store: disk)
        XCTAssertEqual(reconciled.entries.count, 0)

        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/disk/lib"
        preferences.scanRoots = ["/disk/inbox"]
        preferences.userRules = [UserRule.make(id: "rule", keyword: "品牌", source: .ideogram)]
        try PreferencesStore.save(preferences, home: "/home/me", store: disk)
        let roundTrip = try PreferencesStore.load(home: "/home/me", store: disk)
        XCTAssertEqual(roundTrip, preferences)

        let sealed = SealedPreferences.makeNew(installID: "install-1")
        let data = try sealed.encoded()
        XCTAssertEqual(try SealedPreferences.decode(data), sealed)
        let secure = FileSecureStore(directory: "/home/me/.chanwu/sealed", files: disk)
        try secure.write(account: "sealed", data: data)
        XCTAssertEqual(try secure.read(account: "sealed"), data)
        try secure.delete(account: "sealed")
        XCTAssertNil(try secure.read(account: "sealed"))
        XCTAssertNotNil(disk.storedData("/home/me/.chanwu/sealed/sealed.bin"))
    }

    func testLocalFileStoreMovesAndRestores() throws {
        // macOS 的临时目录在 /var/folders 下，属于受保护的系统路径，会被扫描跳过。
        // 有 /tmp 时用 /tmp，两个平台上都不在受保护列表里。
        let tempBase = FileManager.default.fileExists(atPath: "/tmp") ? URL(fileURLWithPath: "/tmp", isDirectory: true) : FileManager.default.temporaryDirectory
        let root = tempBase.appendingPathComponent("chanwu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        let library = root.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let source = inbox.appendingPathComponent("cat_midjourney.png")
        try Data("hello-chanwu".utf8).write(to: source)

        let store = LocalFileStore()
        let organizer = Organizer(store: store)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = library.path
        preferences.scanRoots = [inbox.path]
        var state = LibraryState.fresh()
        state.hasCompletedDryRun = true
        let plan = organizer.scanAndPlan(preferences: preferences, state: state)
        let item = try XCTUnwrap(plan.proposed.first)
        XCTAssertEqual(item.source, .midjourney)
        let record = try organizer.execute(
            plan: plan,
            request: ExecuteRequest.make(confirmed: true, planFingerprint: plan.fingerprint, selectedIDs: [item.id], intendToApply: true),
            state: &state,
            runID: "local-apply"
        )
        XCTAssertEqual(record.operations.first?.action, .moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.destinationPath))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: item.destinationPath)), Data("hello-chanwu".utf8))

        let undo = try organizer.undo(runID: "local-apply", library: library.path, undoID: "local-undo")
        XCTAssertEqual(undo.operations.first?.action, .undone)
        XCTAssertEqual(try Data(contentsOf: source), Data("hello-chanwu".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destinationPath))

        let link = inbox.appendingPathComponent("linked_midjourney.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let again = organizer.scanAndPlan(preferences: preferences, state: state)
        XCTAssertFalse(again.items.contains { $0.fileName == "linked_midjourney.png" })
    }

    func testCLIEndToEnd() throws {
        let disk = MemoryDisk()
        let when = shanghaiDate(year: 2026, month: 11, day: 16, hour: 12)
        try disk.makeDirectory("/disk/inbox/ComfyUI/output")
        try disk.writeFile("/disk/inbox/ComfyUI/output/shot.png", data: Data("shot".utf8), modified: when)
        let scan = CLIRunner.run(.scan(ScanFlags(roots: ["/disk/inbox"], library: "/disk/lib", json: false, minConfidence: nil, includeUnknown: nil, maxDepth: nil)), store: disk, now: when, runID: "cli")
        XCTAssertEqual(scan.exitCode, 0)
        XCTAssertTrue(scan.stdout.contains("可移动"))
        XCTAssertTrue(scan.stdout.contains("shot.png"))
        XCTAssertTrue(disk.exists("/disk/lib/.chanwu/last-plan.json"))

        let refused = CLIRunner.run(.apply(ApplyFlags(library: "/disk/lib", planPath: nil, confirm: false, dryRun: false, selectedIDs: nil)), store: disk, now: when, runID: "cli-no")
        XCTAssertEqual(refused.exitCode, 2)
        XCTAssertTrue(refused.stderr.contains("确认"))

        let dry = CLIRunner.run(.apply(ApplyFlags(library: "/disk/lib", planPath: nil, confirm: true, dryRun: false, selectedIDs: nil)), store: disk, now: when, runID: "cli-dry")
        XCTAssertEqual(dry.exitCode, 0)
        XCTAssertTrue(dry.stdout.contains("演练"))
        XCTAssertNotNil(disk.storedData("/disk/inbox/ComfyUI/output/shot.png"))

        let applied = CLIRunner.run(.apply(ApplyFlags(library: "/disk/lib", planPath: nil, confirm: true, dryRun: false, selectedIDs: nil)), store: disk, now: when, runID: "cli-apply")
        XCTAssertEqual(applied.exitCode, 0)
        XCTAssertTrue(applied.stdout.contains("已执行") || applied.stdout.contains("移动 1"))
        XCTAssertNil(disk.storedData("/disk/inbox/ComfyUI/output/shot.png"))

        let listed = CLIRunner.run(.index(IndexFlags(library: "/disk/lib", query: "comfy", csv: false)), store: disk, now: when)
        XCTAssertEqual(listed.exitCode, 0)
        XCTAssertTrue(listed.stdout.contains("shot.png"))

        let history = CLIRunner.run(.runs(RunsFlags(library: "/disk/lib")), store: disk, now: when)
        XCTAssertTrue(history.stdout.contains("cli-apply"))

        let undone = CLIRunner.run(.undo(UndoFlags(library: "/disk/lib", runID: "cli-apply")), store: disk, now: when, runID: "cli-undo")
        XCTAssertEqual(undone.exitCode, 0)
        XCTAssertNotNil(disk.storedData("/disk/inbox/ComfyUI/output/shot.png"))

        XCTAssertEqual(try CLIParser.parse(["version"]), .version)
        XCTAssertThrowsError(try CLIParser.parse([]))
        XCTAssertThrowsError(try CLIParser.parse(["scan", "--root", "/tmp"]))
        XCTAssertEqual(try CLIParser.parse(["help"]), .help)
        let parsed = try CLIParser.parse(["scan", "--root", "/a", "--root", "/b", "--library", "/lib", "--json", "--min-confidence", "0.8", "--include-unknown"])
        guard case .scan(let flags) = parsed else { return XCTFail() }
        XCTAssertEqual(flags.roots, ["/a", "/b"])
        XCTAssertEqual(flags.minConfidence, 0.8)
        XCTAssertEqual(flags.includeUnknown, true)
        XCTAssertTrue(flags.json)
    }

    func testMaxFilesAndDepthAndCorruptIndex() throws {
        let disk = MemoryDisk()
        let when = Date(timeIntervalSince1970: 10)
        try disk.makeDirectory("/disk/inbox/nested/deep")
        try disk.writeFile("/disk/inbox/a_midjourney.png", data: Data("a".utf8), modified: when)
        try disk.writeFile("/disk/inbox/nested/b_midjourney.png", data: Data("b".utf8), modified: when)
        try disk.writeFile("/disk/inbox/nested/deep/c_midjourney.png", data: Data("c".utf8), modified: when)
        let organizer = Organizer(store: disk)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/disk/lib"
        preferences.scanRoots = ["/disk/inbox"]
        preferences.maxDepth = 0
        let state = LibraryState.fresh(now: when).applying(preferences)
        let shallow = organizer.scanAndPlan(preferences: preferences, state: state, now: when)
        XCTAssertEqual(shallow.proposed.map(\.fileName), ["a_midjourney.png"])

        preferences.maxDepth = 8
        let deepState = LibraryState.fresh(now: when).applying(preferences)
        let capped = organizer.scanAndPlan(preferences: preferences, state: deepState, options: .make(maxFiles: 1), now: when)
        XCTAssertEqual(capped.proposed.count, 1)
        XCTAssertTrue(capped.issues.contains { $0.message.contains("上限") })

        try disk.writeFile("/disk/lib/.chanwu/index.json", data: Data("{".utf8), modified: when)
        XCTAssertThrowsError(try IndexStore.load(library: "/disk/lib", store: disk))
    }

    private func seedLibrary(_ disk: MemoryDisk, modified: Date) throws {
        try disk.makeDirectory("/disk/inbox/project")
        try disk.makeDirectory("/disk/inbox/project/output")
        try disk.makeDirectory("/disk/inbox/a")
        try disk.makeDirectory("/disk/inbox/b")
        try disk.writeFile("/disk/inbox/project/.git", data: Data("git".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/project/Package.swift", data: Data("pkg".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/project/midjourney_in_repo.png", data: Data("repo".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/project/main.swift", data: Data("swift".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/project/output/repo_out_midjourney.png", data: Data("out".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/cat_midjourney.png", data: Data("mj".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/random.jpg", data: Data("jpg".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/partial.png.crdownload", data: Data("part".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/.secret.png", data: Data("hide".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/empty_midjourney.png", data: Data(), modified: modified)
        try disk.makeSymlink("/disk/inbox/link.png")
        let png = PNGFixture.png(chunks: [("parameters", "cat\nSteps: 20, Sampler: Euler a")])
        try disk.writeFile("/disk/inbox/render.png", data: png, modified: modified)
        try disk.writeFile("/disk/inbox/render.json", data: Data("not comfy".utf8), modified: modified)
        let workflow = Data(#"{"nodes":[{"type":"KSampler","widgets_values":[1]}]}"#.utf8)
        try disk.writeFile("/disk/inbox/workflow.png", data: Data("PNG".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/workflow.json", data: workflow, modified: modified)
        try disk.writeFile("/disk/inbox/a/song_suno.mp3", data: Data("a".utf8), modified: modified)
        try disk.writeFile("/disk/inbox/b/song_suno.mp3", data: Data("b".utf8), modified: modified)
    }

    private func shanghaiDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        let calendar = Calendars.shanghai()
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date(timeIntervalSince1970: 0)
    }
}

enum PNGFixture {
    static func png(chunks: [(String, String)]) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(contentsOf: be32(1))
        ihdr.append(contentsOf: be32(1))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        data.append(chunk("IHDR", ihdr))
        for (key, value) in chunks {
            var payload = Data(key.utf8)
            payload.append(0)
            payload.append(Data(value.utf8))
            data.append(chunk("tEXt", payload))
        }
        data.append(chunk("IEND", Data()))
        return data
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var body = Data(type.utf8)
        body.append(payload)
        var data = Data()
        data.append(contentsOf: be32(UInt32(payload.count)))
        data.append(body)
        data.append(contentsOf: be32(crc32(body)))
        return data
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xedb8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xffff_ffff
    }
}
