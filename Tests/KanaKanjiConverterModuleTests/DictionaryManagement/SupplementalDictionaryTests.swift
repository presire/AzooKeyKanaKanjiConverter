@testable import KanaKanjiConverterModule
import SwiftUtils
import XCTest

/// 読み取り専用の補助LOUDS辞書 (hazkey の住所辞書が利用する) のテスト。
///
/// 補助辞書はシステム辞書と `charID.chid` / `cb/` / `mm.binary` を共有し、
/// `louds/` だけを別ディレクトリに持つ。
final class SupplementalDictionaryTests: XCTestCase {
    private var dictionaryMockURL: URL {
        Bundle.module.resourceURL!.standardizedFileURL.appendingPathComponent("DictionaryMock", isDirectory: true)
    }

    private var createdDirectories: [URL] = []

    override func tearDown() {
        for url in self.createdDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        self.createdDirectories = []
        super.tearDown()
    }

    private func systemCharIDText() throws -> String {
        try String(
            contentsOf: self.dictionaryMockURL.appendingPathComponent("louds/charID.chid", isDirectory: false),
            encoding: .utf8
        )
    }

    private func systemCharIDs() throws -> [Character: UInt8] {
        let text = try self.systemCharIDText()
        return [Character: UInt8](uniqueKeysWithValues: text.enumerated().map { ($0.element, UInt8($0.offset)) })
    }

    private func charIDs(_ ruby: String, _ map: [Character: UInt8]) -> [UInt8] {
        ruby.compactMap { map[$0] }
    }

    /// 先頭カナ別シャードのLOUDS辞書を一時ディレクトリに生成する。
    ///
    /// `DictionaryMock` は識別子をエスケープしない旧命名 (`シ.louds`) のため、
    /// `DicdataStore` 経由のシステム辞書検索には使えない。テスト用のシステム辞書もここで生成する。
    /// - Parameter charIDText: `louds/charID.chid` に書き込む照合用スタンプ。既定は `DictionaryMock` と同一。
    private func makeShardedDictionary(
        entries: [DicdataElement],
        name: String,
        charIDText: String? = nil
    ) throws -> URL {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let base = workspace.appendingPathComponent("TestsTmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let loudsDirectory = root.appendingPathComponent("louds", isDirectory: true)
        try FileManager.default.createDirectory(at: loudsDirectory, withIntermediateDirectories: true)
        self.createdDirectories.append(root)

        try DictionaryBuilder.exportDictionary(
            entries: entries,
            to: loudsDirectory,
            baseName: name,
            shardByFirstCharacter: true,
            char2UInt8: try self.systemCharIDs()
        )
        try (charIDText ?? self.systemCharIDText()).write(
            to: loudsDirectory.appendingPathComponent("charID.chid", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try? FileManager.default.copyItem(
            at: self.dictionaryMockURL.appendingPathComponent("mm.binary", isDirectory: false),
            to: root.appendingPathComponent("mm.binary", isDirectory: false)
        )
        return root
    }

    private func makeSupplementalDictionary(
        entries: [DicdataElement],
        charIDText: String? = nil
    ) throws -> URL {
        try self.makeShardedDictionary(entries: entries, name: "SupplementalDictionary", charIDText: charIDText)
    }

    private func systemEntries() -> [DicdataElement] {
        [
            DicdataElement(word: "潮", ruby: "シオ", lcid: 1288, rcid: 1288, mid: 501, value: -6),
            DicdataElement(word: "塩", ruby: "シオ", lcid: 1288, rcid: 1288, mid: 501, value: -6)
        ]
    }

    private func makeSystemDictionary() throws -> URL {
        try self.makeShardedDictionary(entries: self.systemEntries(), name: "SystemDictionary")
    }

    private func addressEntries() -> [DicdataElement] {
        [
            DicdataElement(word: "一ツ家", ruby: "ヒトツヤ", lcid: 1293, rcid: 1293, mid: 501, value: -15.5),
            DicdataElement(word: "上伊那郡辰野町", ruby: "カミイナグンタツノマチ", lcid: 1293, rcid: 1293, mid: 501, value: -15.5)
        ]
    }

    private func words(
        _ store: DicdataStore,
        state: DicdataStoreState,
        perfectMatch ruby: String,
        map: [Character: UInt8]
    ) -> Set<String> {
        let query = DicdataStore.supplementalQuery(String(ruby.first!))
        let indices = store.perfectMatchingSearch(query: query, charIDs: self.charIDs(ruby, map), state: state)
        guard !indices.isEmpty else { return [] }
        return Set(store.getDicdataFromLoudstxt3(identifier: query, indices: indices, state: state).map { $0.word })
    }

    private func latticeWords(_ store: DicdataStore, state: DicdataStoreState, reading: String) -> Set<String> {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)
        let nodes = store.lookupDicdata(
            composingText: composingText,
            surfaceRange: (startIndex: 0, endIndexRange: nil),
            needTypoCorrection: false,
            state: state
        )
        return Set(nodes.map { $0.data.word })
    }

    // MARK: - 収録と参加

    func testSupplementalEntryIsReadableThroughNamespacedIdentifier() throws {
        let map = try self.systemCharIDs()
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        XCTAssertTrue(store.hasSupplementalDictionary)
        let state = store.prepareState()

        XCTAssertEqual(self.words(store, state: state, perfectMatch: "ヒトツヤ", map: map), ["一ツ家"])
        XCTAssertEqual(self.words(store, state: state, perfectMatch: "カミイナグンタツノマチ", map: map), ["上伊那郡辰野町"])
    }

    func testSupplementalEntryParticipatesInLatticeLookup() throws {
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()

        XCTAssertTrue(self.latticeWords(store, state: state, reading: "ひとつや").contains("一ツ家"))
    }

    func testSupplementalEntryParticipatesInPrediction() throws {
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()

        let predicted = Set(store.getPredictionLOUDSDicdata(key: "ヒトツ", state: state).map { $0.word })
        XCTAssertTrue(predicted.contains("一ツ家"), "prediction did not include the supplemental entry: \(predicted)")
    }

    func testSupplementalEntriesAreNotMarkedAsUserDictionaryOrLearned() throws {
        let map = try self.systemCharIDs()
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()

        let query = DicdataStore.supplementalQuery("ヒ")
        let indices = store.perfectMatchingSearch(query: query, charIDs: self.charIDs("ヒトツヤ", map), state: state)
        let data = store.getDicdataFromLoudstxt3(identifier: query, indices: indices, state: state)
        XCTAssertFalse(data.isEmpty)
        XCTAssertTrue(data.allSatisfy { $0.metadata == .empty })
    }

    // MARK: - トグル

    func testDisabledSupplementalDictionaryYieldsNoSupplementalEntry() throws {
        let map = try self.systemCharIDs()
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()
        state.updateSupplementalDictionaryEnabled(false)

        XCTAssertTrue(self.words(store, state: state, perfectMatch: "ヒトツヤ", map: map).isEmpty)
        XCTAssertFalse(self.latticeWords(store, state: state, reading: "ひとつや").contains("一ツ家"))
        XCTAssertFalse(Set(store.getPredictionLOUDSDicdata(key: "ヒトツ", state: state).map { $0.word }).contains("一ツ家"))
    }

    func testSupplementalDictionaryCanBeReEnabledWithoutRebuildingTheStore() throws {
        let map = try self.systemCharIDs()
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()

        state.updateSupplementalDictionaryEnabled(false)
        XCTAssertTrue(self.words(store, state: state, perfectMatch: "ヒトツヤ", map: map).isEmpty)
        state.updateSupplementalDictionaryEnabled(true)
        XCTAssertEqual(self.words(store, state: state, perfectMatch: "ヒトツヤ", map: map), ["一ツ家"])
    }

    // MARK: - 縮退

    func testMissingSupplementalDirectoryDisablesOnlyTheSupplementalDictionary() throws {
        let systemURL = try self.makeSystemDictionary()
        let missingURL = URL(fileURLWithPath: "/nonexistent/hazkey-address-dictionary")
        let store = DicdataStore(dictionaryURL: systemURL, supplementalDictionaryURL: missingURL)
        XCTAssertFalse(store.hasSupplementalDictionary)
        let state = store.prepareState()

        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しお").isSuperset(of: ["潮", "塩"]))
    }

    func testCharIDStampMismatchDisablesOnlyTheSupplementalDictionary() throws {
        let map = try self.systemCharIDs()
        let systemURL = try self.makeSystemDictionary()
        let mismatched = String(try self.systemCharIDText().dropLast(3))
        let supplementalURL = try self.makeSupplementalDictionary(
            entries: self.addressEntries(),
            charIDText: mismatched
        )
        let store = DicdataStore(dictionaryURL: systemURL, supplementalDictionaryURL: supplementalURL)
        XCTAssertFalse(store.hasSupplementalDictionary)
        let state = store.prepareState()

        XCTAssertTrue(self.words(store, state: state, perfectMatch: "ヒトツヤ", map: map).isEmpty)
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しお").isSuperset(of: ["潮", "塩"]))
    }

    func testMissingCharIDStampDisablesOnlyTheSupplementalDictionary() throws {
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        try FileManager.default.removeItem(
            at: supplementalURL.appendingPathComponent("louds/charID.chid", isDirectory: false)
        )
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        XCTAssertFalse(store.hasSupplementalDictionary)
    }

    func testCorruptedSupplementalShardLeavesSystemDictionaryIntact() throws {
        let map = try self.systemCharIDs()
        let systemURL = try self.makeSystemDictionary()
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let loudsDirectory = supplementalURL.appendingPathComponent("louds", isDirectory: true)
        for url in try FileManager.default.contentsOfDirectory(at: loudsDirectory, includingPropertiesForKeys: nil)
        where url.pathExtension == "loudstxt3" {
            try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        }
        let store = DicdataStore(dictionaryURL: systemURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()

        XCTAssertTrue(self.words(store, state: state, perfectMatch: "ヒトツヤ", map: map).isEmpty)
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しお").isSuperset(of: ["潮", "塩"]))
    }

    func testTruncatedSupplementalShardLeavesSystemDictionaryIntact() throws {
        let map = try self.systemCharIDs()
        let systemURL = try self.makeSystemDictionary()
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let loudsDirectory = supplementalURL.appendingPathComponent("louds", isDirectory: true)
        for url in try FileManager.default.contentsOfDirectory(at: loudsDirectory, includingPropertiesForKeys: nil)
        where url.pathExtension == "loudstxt3" {
            let original = try Data(contentsOf: url)
            try original.prefix(original.count / 3).write(to: url)
        }
        let store = DicdataStore(dictionaryURL: systemURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()

        XCTAssertTrue(self.words(store, state: state, perfectMatch: "ヒトツヤ", map: map).isEmpty)
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しお").isSuperset(of: ["潮", "塩"]))
    }

    // MARK: - システム辞書との分離

    func testSupplementalShardDoesNotShadowSystemShardOfTheSameFirstCharacter() throws {
        let map = try self.systemCharIDs()
        let systemURL = try self.makeSystemDictionary()
        // システム辞書と同じ先頭文字「シ」を補助辞書にも持たせ、シャードの取り違えを検出する
        let supplementalURL = try self.makeSupplementalDictionary(entries: [
            DicdataElement(word: "汐入", ruby: "シオイリ", lcid: 1293, rcid: 1293, mid: 501, value: -15.5)
        ])

        let store = DicdataStore(dictionaryURL: systemURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()
        XCTAssertTrue(store.hasSupplementalDictionary)

        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しお").isSuperset(of: ["潮", "塩"]))
        XCTAssertEqual(self.words(store, state: state, perfectMatch: "シオイリ", map: map), ["汐入"])

        let systemIndices = store.perfectMatchingSearch(query: "シ", charIDs: self.charIDs("シオ", map), state: state)
        let systemWords = Set(store.getDicdataFromLoudstxt3(identifier: "シ", indices: systemIndices, state: state).map { $0.word })
        XCTAssertTrue(systemWords.isSuperset(of: ["潮", "塩"]))
        XCTAssertFalse(systemWords.contains("汐入"))
    }

    func testStoreWithoutSupplementalURLBehavesExactlyAsBefore() throws {
        let systemURL = try self.makeSystemDictionary()
        let store = DicdataStore(dictionaryURL: systemURL)
        XCTAssertFalse(store.hasSupplementalDictionary)
        let state = store.prepareState()
        XCTAssertNil(store.loadLOUDS(query: DicdataStore.supplementalQuery("ヒ"), state: state))
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しお").isSuperset(of: ["潮", "塩"]))
    }

    // MARK: - KanaKanjiConverter 経由

    func testConverterExposesSupplementalDictionaryAvailabilityAndToggle() throws {
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let converter = KanaKanjiConverter(
            dictionaryURL: self.dictionaryMockURL,
            supplementalDictionaryURL: supplementalURL
        )
        XCTAssertTrue(converter.isSupplementalDictionaryAvailable)
        converter.setSupplementalDictionaryEnabled(false)
        converter.setSupplementalDictionaryEnabled(true)

        let missing = KanaKanjiConverter(
            dictionaryURL: self.dictionaryMockURL,
            supplementalDictionaryURL: URL(fileURLWithPath: "/nonexistent/hazkey-address-dictionary")
        )
        XCTAssertFalse(missing.isSupplementalDictionaryAvailable)
    }
}
