// 只有 Command Line Tools、没有 Xcode 的 Mac 上没有 XCTest 模块。
// 这时把现有的 XCTest 风格测试接到 Swift Testing 上运行，断言语义保持一致。
#if !canImport(XCTest)
import Testing

class XCTestCase {
    required init() {}
}

private func xctRecord(_ what: String, _ message: String, _ file: StaticString, _ line: UInt) {
    let suffix = message.isEmpty ? "" : " - \(message)"
    Issue.record(Comment(rawValue: "\(what)\(suffix) (\(file):\(line))"))
}

func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    xctRecord("XCTFail", message, file, line)
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !expression() { xctRecord("XCTAssertTrue failed", message(), file, line) } }
    catch { xctRecord("XCTAssertTrue threw \(error)", message(), file, line) }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() { xctRecord("XCTAssertFalse failed", message(), file, line) } }
    catch { xctRecord("XCTAssertFalse threw \(error)", message(), file, line) }
}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x != y { xctRecord("XCTAssertEqual failed: (\(x)) is not equal to (\(y))", message(), file, line) } }
    catch { xctRecord("XCTAssertEqual threw \(error)", message(), file, line) }
}

func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x == y { xctRecord("XCTAssertNotEqual failed: (\(x)) is equal to (\(y))", message(), file, line) } }
    catch { xctRecord("XCTAssertNotEqual threw \(error)", message(), file, line) }
}

private func xctCompare<T: Comparable>(_ name: String, _ a: () throws -> T, _ b: () throws -> T, _ ok: (T, T) -> Bool, _ message: String, _ file: StaticString, _ line: UInt) {
    do { let x = try a(), y = try b(); if !ok(x, y) { xctRecord("\(name) failed: (\(x)) vs (\(y))", message, file, line) } }
    catch { xctRecord("\(name) threw \(error)", message, file, line) }
}

func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    xctCompare("XCTAssertGreaterThan", a, b, >, message(), file, line)
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    xctCompare("XCTAssertGreaterThanOrEqual", a, b, >=, message(), file, line)
}

func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    xctCompare("XCTAssertLessThan", a, b, <, message(), file, line)
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    xctCompare("XCTAssertLessThanOrEqual", a, b, <=, message(), file, line)
}

func XCTAssertNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if let v = try expression() { xctRecord("XCTAssertNil failed: \(v)", message(), file, line) } }
    catch { xctRecord("XCTAssertNil threw \(error)", message(), file, line) }
}

func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() == nil { xctRecord("XCTAssertNotNil failed", message(), file, line) } }
    catch { xctRecord("XCTAssertNotNil threw \(error)", message(), file, line) }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ errorHandler: (_ error: Error) -> Void = { _ in }) {
    do { _ = try expression(); xctRecord("XCTAssertThrowsError failed: did not throw", message(), file, line) }
    catch { errorHandler(error) }
}

struct XCTUnwrapError: Error, CustomStringConvertible {
    let where_: String
    var description: String { "XCTUnwrap found nil (\(where_))" }
}

func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    if let value = try expression() { return value }
    xctRecord("XCTUnwrap failed: nil", message(), file, line)
    throw XCTUnwrapError(where_: "\(file):\(line)")
}

// 每个 XCTest 方法对应一个 Swift Testing 用例。
@Test func HashAndSafetyTests_testSHA256KnownVectors() throws { HashAndSafetyTests().testSHA256KnownVectors() }
@Test func HashAndSafetyTests_testFileActionsNeverIncludeDelete() throws { HashAndSafetyTests().testFileActionsNeverIncludeDelete() }
@Test func HashAndSafetyTests_testPathInsideDoesNotConfusePrefixes() throws { HashAndSafetyTests().testPathInsideDoesNotConfusePrefixes() }
@Test func HashAndSafetyTests_testProtectedAndSanitizer() throws { HashAndSafetyTests().testProtectedAndSanitizer() }
@Test func HashAndSafetyTests_testCopyIsChineseAndHonest() throws { HashAndSafetyTests().testCopyIsChineseAndHonest() }
@Test func IdentifyTests_testFilenameSources() throws { IdentifyTests().testFilenameSources() }
@Test func IdentifyTests_testShortTokenDoesNotMatchInsideWords() throws { IdentifyTests().testShortTokenDoesNotMatchInsideWords() }
@Test func IdentifyTests_testParentFolder() throws { IdentifyTests().testParentFolder() }
@Test func IdentifyTests_testPNGParametersAndSidecars() throws { IdentifyTests().testPNGParametersAndSidecars() }
@Test func IdentifyTests_testMetadataBeatsWeakFilename() throws { IdentifyTests().testMetadataBeatsWeakFilename() }
@Test func IdentifyTests_testUserRuleOverridesAndIgnoresEmpty() throws { IdentifyTests().testUserRuleOverridesAndIgnoresEmpty() }
@Test func IdentifyTests_testMagicForExtensionlessPNG() throws { IdentifyTests().testMagicForExtensionlessPNG() }
@Test func IdentifyTests_testPlanGate() throws { IdentifyTests().testPlanGate() }
@Test func IdentifyTests_testTruncatedPNGDoesNotThrow() throws { IdentifyTests().testTruncatedPNGDoesNotThrow() }
@Test func PipelineTests_testFullRehearsalApplyUndoAndSecondLibrary() throws { try PipelineTests().testFullRehearsalApplyUndoAndSecondLibrary() }
@Test func PipelineTests_testApplyUndoIndexAndCrossVolume() throws { try PipelineTests().testApplyUndoIndexAndCrossVolume() }
@Test func PipelineTests_testEmptySelectionDoesNotFinishFirstRunAndOptionalCanBeForced() throws { try PipelineTests().testEmptySelectionDoesNotFinishFirstRunAndOptionalCanBeForced() }
@Test func PipelineTests_testUnknownMediaFlagProjectBoundaryAndProtectedRoot() throws { try PipelineTests().testUnknownMediaFlagProjectBoundaryAndProtectedRoot() }
@Test func PipelineTests_testSpecificFilesBlockedInsideLibraryAndWatchQueue() throws { try PipelineTests().testSpecificFilesBlockedInsideLibraryAndWatchQueue() }
@Test func PipelineTests_testIndexSearchCSVAndPreferencesRoundTrip() throws { try PipelineTests().testIndexSearchCSVAndPreferencesRoundTrip() }
@Test func PipelineTests_testLocalFileStoreMovesAndRestores() throws { try PipelineTests().testLocalFileStoreMovesAndRestores() }
@Test func PipelineTests_testCLIEndToEnd() throws { try PipelineTests().testCLIEndToEnd() }
@Test func PipelineTests_testMaxFilesAndDepthAndCorruptIndex() throws { try PipelineTests().testMaxFilesAndDepthAndCorruptIndex() }
@Test func SpecTests_testClassificationRoutesScreenshotsSecretsAndFrames() throws { SpecTests().testClassificationRoutesScreenshotsSecretsAndFrames() }
@Test func SpecTests_testVersionOrderAndHistoryRoll() throws { SpecTests().testVersionOrderAndHistoryRoll() }
@Test func SpecTests_testCollisionAppendsDateThenTime() throws { SpecTests().testCollisionAppendsDateThenTime() }
@Test func SpecTests_testMoveOnlyRefusesCrossVolumeAndUndoStillRestores() throws { try SpecTests().testMoveOnlyRefusesCrossVolumeAndUndoStillRestores() }
@Test func SpecTests_testPublishScoringImportAndParsers() throws { try SpecTests().testPublishScoringImportAndParsers() }
@Test func SpecTests_testRulesEvaluateInOrder() throws { SpecTests().testRulesEvaluateInOrder() }
@Test func SpecTests_testSQLiteSearchKeepsOriginalNameAndTag() throws { try SpecTests().testSQLiteSearchKeepsOriginalNameAndTag() }
@Test func SpecTests_testDeliveryManifestAndZipRoundTrip() throws { try SpecTests().testDeliveryManifestAndZipRoundTrip() }
@Test func SpecTests_testMessyNamesRenameAndKeepOriginal() throws { SpecTests().testMessyNamesRenameAndKeepOriginal() }
@Test func SpecTests_testWeeklyReportCountsAndSundayFile() throws { try SpecTests().testWeeklyReportCountsAndSundayFile() }
@Test func SpecTests_testLocalAIStaysOffUnlessEnabled() throws { SpecTests().testLocalAIStaysOffUnlessEnabled() }
@Test func SpecTests_testProjectTagsSkipGenericFoldersUnlessKnownOrRoot() throws { try SpecTests().testProjectTagsSkipGenericFoldersUnlessKnownOrRoot() }
@Test func SpecTests_testLowConfidenceStaysUnchecked() throws { try SpecTests().testLowConfidenceStaysUnchecked() }
@Test func SpecTests_testPackAndReportCommands() throws { try SpecTests().testPackAndReportCommands() }
#endif
