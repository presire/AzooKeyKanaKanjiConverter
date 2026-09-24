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
        sourceID: String = DicdataStore.legacySupplementalSourceID,
        map: [Character: UInt8]
    ) -> Set<String> {
        let query = DicdataStore.supplementalQuery(String(ruby.first!), sourceID: sourceID)
        let indices = store.perfectMatchingSearch(query: query, charIDs: self.charIDs(ruby, map), state: state)
        guard !indices.isEmpty else { return [] }
        return Set(store.getDicdataFromLoudstxt3(identifier: query, indices: indices, state: state).map { $0.word })
    }

    private func latticeData(_ store: DicdataStore, state: DicdataStoreState, reading: String) -> [DicdataElement] {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)
        let nodes = store.lookupDicdata(
            composingText: composingText,
            surfaceRange: (startIndex: 0, endIndexRange: nil),
            needTypoCorrection: false,
            state: state
        )
        return nodes.map { $0.data }
    }

    private func latticeWords(_ store: DicdataStore, state: DicdataStoreState, reading: String) -> Set<String> {
        Set(self.latticeData(store, state: state, reading: reading).map { $0.word })
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

    func testPreloadedSystemShardCacheIsNotReadForSupplementalQueries() throws {
        let map = try self.systemCharIDs()
        let systemURL = try self.makeSystemDictionary()
        let supplementalURL = try self.makeSupplementalDictionary(entries: [
            DicdataElement(word: "汐入", ruby: "シオイリ", lcid: 1293, rcid: 1293, mid: 501, value: -15.5)
        ])
        let store = DicdataStore(dictionaryURL: systemURL, supplementalDictionaryURL: supplementalURL, preloadDictionary: true)
        let state = store.prepareState()

        XCTAssertEqual(self.words(store, state: state, perfectMatch: "シオイリ", map: map), ["汐入"])
        XCTAssertTrue(self.words(store, state: state, perfectMatch: "シオ", map: map).isEmpty)
        let systemIndices = store.perfectMatchingSearch(query: "シ", charIDs: self.charIDs("シオ", map), state: state)
        let systemWords = Set(store.getDicdataFromLoudstxt3(identifier: "シ", indices: systemIndices, state: state).map { $0.word })
        XCTAssertEqual(systemWords, ["潮", "塩"])
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しおいり").contains("汐入"))
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

    // MARK: - 複数ソース

    private func makeAddressDictionary() throws -> URL {
        try self.makeShardedDictionary(
            entries: [DicdataElement(word: "汐入", ruby: "シオイリ", lcid: 1293, rcid: 1293, mid: 501, value: -15.5)],
            name: "AddressDictionary"
        )
    }

    /// 住所辞書と同じ先頭文字・同じ木の形を持たせ、ノードindexが一致しても取り違えないことを検出する。
    private func makeEngineeringDictionary(charIDText: String? = nil) throws -> URL {
        try self.makeShardedDictionary(
            entries: [DicdataElement(word: "Shiokara", ruby: "シオカラ", lcid: 1288, rcid: 1288, mid: 501, value: -15.5)],
            name: "EngineeringDictionary",
            charIDText: charIDText
        )
    }

    private func makeMultiSourceStore(
        systemURL: URL,
        addressURL: URL?,
        engineeringURL: URL?,
        preloadDictionary: Bool = false
    ) throws -> DicdataStore {
        try DicdataStore(
            dictionaryURL: systemURL,
            supplementalDictionaries: [
                SupplementalDictionarySource(id: "address", directoryURL: addressURL),
                SupplementalDictionarySource(id: "engineering", directoryURL: engineeringURL)
            ],
            preloadDictionary: preloadDictionary
        )
    }

    func testSourcesSharingAFirstCharacterResolveToTheirOwnTrees() throws {
        let map = try self.systemCharIDs()
        let systemURL = try self.makeSystemDictionary()
        let addressURL = try self.makeAddressDictionary()
        let engineeringURL = try self.makeEngineeringDictionary()

        for preload in [false, true] {
            let store = try self.makeMultiSourceStore(
                systemURL: systemURL,
                addressURL: addressURL,
                engineeringURL: engineeringURL,
                preloadDictionary: preload
            )
            let state = store.prepareState()

            XCTAssertEqual(self.words(store, state: state, perfectMatch: "シオイリ", sourceID: "address", map: map), ["汐入"])
            XCTAssertEqual(self.words(store, state: state, perfectMatch: "シオカラ", sourceID: "engineering", map: map), ["Shiokara"])
            XCTAssertTrue(self.words(store, state: state, perfectMatch: "シオカラ", sourceID: "address", map: map).isEmpty)
            XCTAssertTrue(self.words(store, state: state, perfectMatch: "シオイリ", sourceID: "engineering", map: map).isEmpty)

            let iri = self.latticeWords(store, state: state, reading: "しおいり")
            XCTAssertTrue(iri.isSuperset(of: ["汐入", "潮", "塩"]), "preload=\(preload): \(iri)")
            XCTAssertFalse(iri.contains("Shiokara"))
            let kara = self.latticeWords(store, state: state, reading: "しおから")
            XCTAssertTrue(kara.isSuperset(of: ["Shiokara", "潮", "塩"]), "preload=\(preload): \(kara)")
            XCTAssertFalse(kara.contains("汐入"))

            let systemIndices = store.perfectMatchingSearch(query: "シ", charIDs: self.charIDs("シオ", map), state: state)
            let systemWords = Set(store.getDicdataFromLoudstxt3(identifier: "シ", indices: systemIndices, state: state).map { $0.word })
            XCTAssertEqual(systemWords, ["潮", "塩"])
        }
    }

    func testPredictionDrawsFromEverySource() throws {
        let store = try self.makeMultiSourceStore(
            systemURL: try self.makeSystemDictionary(),
            addressURL: try self.makeAddressDictionary(),
            engineeringURL: try self.makeEngineeringDictionary()
        )
        let state = store.prepareState()

        let predicted = Set(store.getPredictionLOUDSDicdata(key: "シオ", state: state).map { $0.word })
        XCTAssertTrue(predicted.isSuperset(of: ["汐入", "Shiokara"]), "\(predicted)")
    }

    func testEachSourceIsToggledIndependently() throws {
        let store = try self.makeMultiSourceStore(
            systemURL: try self.makeSystemDictionary(),
            addressURL: try self.makeAddressDictionary(),
            engineeringURL: try self.makeEngineeringDictionary()
        )
        let state = store.prepareState()

        XCTAssertTrue(state.updateSupplementalDictionaryEnabled(false, for: "engineering"))
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しおいり").contains("汐入"))
        XCTAssertFalse(self.latticeWords(store, state: state, reading: "しおから").contains("Shiokara"))
        let predictedWithoutEngineering = Set(store.getPredictionLOUDSDicdata(key: "シオ", state: state).map { $0.word })
        XCTAssertTrue(predictedWithoutEngineering.contains("汐入"))
        XCTAssertFalse(predictedWithoutEngineering.contains("Shiokara"))
        XCTAssertTrue(store.isSupplementalDictionaryAvailable(for: "engineering"))

        XCTAssertTrue(state.updateSupplementalDictionaryEnabled(false, for: "address"))
        XCTAssertTrue(state.updateSupplementalDictionaryEnabled(true, for: "engineering"))
        XCTAssertFalse(self.latticeWords(store, state: state, reading: "しおいり").contains("汐入"))
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しおから").contains("Shiokara"))
        XCTAssertTrue(store.isSupplementalDictionaryAvailable(for: "address"))
    }

    func testToggleOnOneStateDoesNotAffectAnotherStateSharingTheStore() throws {
        let store = try self.makeMultiSourceStore(
            systemURL: try self.makeSystemDictionary(),
            addressURL: try self.makeAddressDictionary(),
            engineeringURL: try self.makeEngineeringDictionary()
        )
        let disabled = store.prepareState()
        let enabled = store.prepareState()

        XCTAssertTrue(disabled.updateSupplementalDictionaryEnabled(false, for: "engineering"))
        XCTAssertFalse(self.latticeWords(store, state: disabled, reading: "しおから").contains("Shiokara"))
        XCTAssertTrue(self.latticeWords(store, state: enabled, reading: "しおから").contains("Shiokara"))
        XCTAssertFalse(self.latticeWords(store, state: disabled, reading: "しおから").contains("Shiokara"))
    }

    func testStampMismatchDisablesOnlyThatSource() throws {
        let mismatched = String(try self.systemCharIDText().dropLast(3))
        let store = try self.makeMultiSourceStore(
            systemURL: try self.makeSystemDictionary(),
            addressURL: try self.makeAddressDictionary(),
            engineeringURL: try self.makeEngineeringDictionary(charIDText: mismatched)
        )
        let state = store.prepareState()

        XCTAssertTrue(store.isSupplementalDictionaryAvailable(for: "address"))
        XCTAssertFalse(store.isSupplementalDictionaryAvailable(for: "engineering"))
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しおいり").isSuperset(of: ["汐入", "潮", "塩"]))
        XCTAssertFalse(self.latticeWords(store, state: state, reading: "しおから").contains("Shiokara"))
    }

    func testMissingDirectoryDisablesOnlyThatSource() throws {
        let map = try self.systemCharIDs()
        let systemURL = try self.makeSystemDictionary()
        let addressURL = try self.makeAddressDictionary()
        let engineeringURL = try self.makeEngineeringDictionary()
        let missingURL = URL(fileURLWithPath: "/nonexistent/hazkey-engineering-dictionary")

        for (address, engineering) in [(addressURL, nil), (addressURL, missingURL)] as [(URL?, URL?)] {
            let store = try self.makeMultiSourceStore(systemURL: systemURL, addressURL: address, engineeringURL: engineering)
            let state = store.prepareState()
            XCTAssertTrue(store.isSupplementalDictionaryAvailable(for: "address"))
            XCTAssertFalse(store.isSupplementalDictionaryAvailable(for: "engineering"))
            XCTAssertEqual(self.words(store, state: state, perfectMatch: "シオイリ", sourceID: "address", map: map), ["汐入"])
        }

        let store = try self.makeMultiSourceStore(systemURL: systemURL, addressURL: missingURL, engineeringURL: engineeringURL)
        let state = store.prepareState()
        XCTAssertFalse(store.isSupplementalDictionaryAvailable(for: "address"))
        XCTAssertFalse(store.hasSupplementalDictionary)
        XCTAssertTrue(store.isSupplementalDictionaryAvailable(for: "engineering"))
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しおから").isSuperset(of: ["Shiokara", "潮", "塩"]))
    }

    func testTruncatedShardInOneSourceLeavesTheOtherSourceIntact() throws {
        let map = try self.systemCharIDs()
        let engineeringURL = try self.makeEngineeringDictionary()
        let loudsDirectory = engineeringURL.appendingPathComponent("louds", isDirectory: true)
        for url in try FileManager.default.contentsOfDirectory(at: loudsDirectory, includingPropertiesForKeys: nil)
        where url.pathExtension == "loudstxt3" {
            let original = try Data(contentsOf: url)
            try original.prefix(original.count / 3).write(to: url)
        }
        let store = try self.makeMultiSourceStore(
            systemURL: try self.makeSystemDictionary(),
            addressURL: try self.makeAddressDictionary(),
            engineeringURL: engineeringURL
        )
        let state = store.prepareState()

        XCTAssertTrue(self.words(store, state: state, perfectMatch: "シオカラ", sourceID: "engineering", map: map).isEmpty)
        XCTAssertEqual(self.words(store, state: state, perfectMatch: "シオイリ", sourceID: "address", map: map), ["汐入"])
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しおいり").isSuperset(of: ["汐入", "潮", "塩"]))
    }

    func testDeclarationOrderDoesNotChangeTheTreeAnIDResolvesTo() throws {
        let map = try self.systemCharIDs()
        let systemURL = try self.makeSystemDictionary()
        let addressURL = try self.makeAddressDictionary()
        let engineeringURL = try self.makeEngineeringDictionary()
        let address = SupplementalDictionarySource(id: "address", directoryURL: addressURL)
        let engineering = SupplementalDictionarySource(id: "engineering", directoryURL: engineeringURL)

        for sources in [[address, engineering], [engineering, address]] {
            let store = try DicdataStore(dictionaryURL: systemURL, supplementalDictionaries: sources)
            let state = store.prepareState()
            XCTAssertEqual(self.words(store, state: state, perfectMatch: "シオイリ", sourceID: "address", map: map), ["汐入"])
            XCTAssertEqual(self.words(store, state: state, perfectMatch: "シオカラ", sourceID: "engineering", map: map), ["Shiokara"])
        }
    }

    func testLegacyToggleAddressesTheFirstDeclaredSource() throws {
        let reversed = try DicdataStore(
            dictionaryURL: try self.makeSystemDictionary(),
            supplementalDictionaries: [
                SupplementalDictionarySource(id: "engineering", directoryURL: try self.makeEngineeringDictionary()),
                SupplementalDictionarySource(id: "address", directoryURL: try self.makeAddressDictionary())
            ]
        )
        let state = reversed.prepareState()
        state.updateSupplementalDictionaryEnabled(false)
        XCTAssertFalse(self.latticeWords(reversed, state: state, reading: "しおから").contains("Shiokara"))
        XCTAssertTrue(self.latticeWords(reversed, state: state, reading: "しおいり").contains("汐入"))
    }

    func testMultiSourceInitRejectsInvalidConfigurations() throws {
        let url = self.dictionaryMockURL
        XCTAssertThrowsError(try DicdataStore(dictionaryURL: url, supplementalDictionaries: [])) {
            XCTAssertEqual($0 as? SupplementalDictionaryConfigurationError, .emptySources)
        }
        XCTAssertThrowsError(try DicdataStore(dictionaryURL: url, supplementalDictionaries: [
            SupplementalDictionarySource(id: "address", directoryURL: nil),
            SupplementalDictionarySource(id: "address", directoryURL: nil)
        ])) {
            XCTAssertEqual($0 as? SupplementalDictionaryConfigurationError, .duplicateID("address"))
        }
        for invalid in ["", "Address", "a:b", "住所", "a b", "a/b"] {
            XCTAssertThrowsError(
                try DicdataStore(dictionaryURL: url, supplementalDictionaries: [SupplementalDictionarySource(id: invalid, directoryURL: nil)])
            ) {
                XCTAssertEqual($0 as? SupplementalDictionaryConfigurationError, .invalidID(invalid))
            }
        }
        XCTAssertNoThrow(
            try DicdataStore(dictionaryURL: url, supplementalDictionaries: [SupplementalDictionarySource(id: "eng_dict-2", directoryURL: nil)])
        )
    }

    func testUnknownSourceIDIsRejectedWithoutCreatingAFlag() throws {
        let map = try self.systemCharIDs()
        let store = try DicdataStore(
            dictionaryURL: try self.makeSystemDictionary(),
            supplementalDictionaries: [SupplementalDictionarySource(id: "address", directoryURL: try self.makeAddressDictionary())]
        )
        let state = store.prepareState()

        XCTAssertFalse(state.updateSupplementalDictionaryEnabled(false, for: "engineering"))
        XCTAssertFalse(store.isSupplementalDictionaryAvailable(for: "engineering"))
        let unknownQuery = DicdataStore.supplementalQuery("シ", sourceID: "engineering")
        XCTAssertNil(store.loadLOUDS(query: unknownQuery, state: state))
        XCTAssertTrue(store.getDicdataFromLoudstxt3(identifier: unknownQuery, indices: [0, 1, 2], state: state).isEmpty)
        XCTAssertEqual(self.words(store, state: state, perfectMatch: "シオイリ", sourceID: "address", map: map), ["汐入"])
    }

    func testEntriesWithTheSameRubyAndSurfaceButDifferentCIDsAreKeptFromEverySource() throws {
        let addressURL = try self.makeAddressDictionary()
        let engineeringURL = try self.makeShardedDictionary(
            entries: [DicdataElement(word: "汐入", ruby: "シオイリ", lcid: 1285, rcid: 1285, mid: 501, value: -15.5)],
            name: "EngineeringDictionary"
        )
        let store = try self.makeMultiSourceStore(
            systemURL: try self.makeSystemDictionary(),
            addressURL: addressURL,
            engineeringURL: engineeringURL
        )
        let state = store.prepareState()

        let shioiri = self.latticeData(store, state: state, reading: "しおいり").filter { $0.word == "汐入" }
        XCTAssertEqual(Set(shioiri.map { $0.lcid }), [1293, 1285])
    }

    func testConverterExposesPerSourceAvailabilityAndToggle() throws {
        let converter = try KanaKanjiConverter(
            dictionaryURL: self.dictionaryMockURL,
            supplementalDictionaries: [
                SupplementalDictionarySource(id: "address", directoryURL: try self.makeAddressDictionary()),
                SupplementalDictionarySource(id: "engineering", directoryURL: URL(fileURLWithPath: "/nonexistent/hazkey-engineering-dictionary"))
            ]
        )
        XCTAssertTrue(converter.isSupplementalDictionaryAvailable(for: "address"))
        XCTAssertFalse(converter.isSupplementalDictionaryAvailable(for: "engineering"))
        XCTAssertFalse(converter.isSupplementalDictionaryAvailable(for: "unknown"))
        XCTAssertTrue(converter.isSupplementalDictionaryAvailable)

        XCTAssertTrue(converter.setSupplementalDictionaryEnabled(false, for: "address"))
        XCTAssertTrue(converter.isSupplementalDictionaryAvailable(for: "address"))
        XCTAssertTrue(converter.setSupplementalDictionaryEnabled(true, for: "engineering"))
        XCTAssertFalse(converter.setSupplementalDictionaryEnabled(false, for: "unknown"))

        XCTAssertThrowsError(try KanaKanjiConverter(dictionaryURL: self.dictionaryMockURL, supplementalDictionaries: []))
    }

    // MARK: - トグル変更時のキャッシュ無効化

    private func conversionOptions() -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 5,
            requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            learningType: .nothing,
            maxMemoryCount: 0,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: nil
        )
    }

    func testZenzaiMemoizationCacheIsPurgedOnlyWhenASourceFlagActuallyChanges() throws {
        let converter = try KanaKanjiConverter(
            dictionaryURL: self.dictionaryMockURL,
            supplementalDictionaries: [
                SupplementalDictionarySource(id: "address", directoryURL: try self.makeAddressDictionary()),
                SupplementalDictionarySource(id: "engineering", directoryURL: try self.makeEngineeringDictionary())
            ]
        )
        func seed() {
            converter.zenzaiMemoizationCache.cacheEvaluationPromptTokens([1, 2, 3], for: "probe")
        }
        func isCached() -> Bool {
            converter.zenzaiMemoizationCache.cachedEvaluationPromptTokens(for: "probe") != nil
        }

        seed()
        converter.setSupplementalDictionaryEnabled(true, for: "address")
        XCTAssertTrue(isCached(), "re-enabling an already enabled source must keep the cache")

        converter.setSupplementalDictionaryEnabled(false, for: "address")
        XCTAssertFalse(isCached())

        seed()
        converter.setSupplementalDictionaryEnabled(false, for: "address")
        XCTAssertTrue(isCached(), "re-applying the same value must keep the cache")
        converter.setSupplementalDictionaryEnabled(false, for: "unknown")
        XCTAssertTrue(isCached())

        converter.setSupplementalDictionaryEnabled(false, for: "engineering")
        XCTAssertFalse(isCached())

        seed()
        converter.setSupplementalDictionaryEnabled(false)
        XCTAssertTrue(isCached(), "the legacy toggle addresses the first source, which is already off")
        converter.setSupplementalDictionaryEnabled(true)
        XCTAssertFalse(isCached())
    }

    func testToggleIsNotMaskedByTheInFlightLatticeOfAnySession() throws {
        let converter = try KanaKanjiConverter(
            dictionaryURL: self.dictionaryMockURL,
            supplementalDictionaries: [
                SupplementalDictionarySource(
                    id: "address",
                    directoryURL: try self.makeSupplementalDictionary(entries: self.addressEntries())
                )
            ]
        )
        let otherSession = converter.createSession()
        var composingText = ComposingText()
        composingText.insertAtCursorPosition("ひとつや", inputStyle: .direct)
        func offersHitotsuya() throws -> (default: Bool, other: Bool) {
            let inDefault = converter.requestCandidates(composingText, options: self.conversionOptions())
                .mainResults.contains { $0.text == "一ツ家" }
            let inOther = try converter.withSession(otherSession) {
                converter.requestCandidates(composingText, options: self.conversionOptions())
                    .mainResults.contains { $0.text == "一ツ家" }
            }
            return (inDefault, inOther)
        }

        var offered = try offersHitotsuya()
        XCTAssertTrue(offered.default)
        XCTAssertTrue(offered.other)

        converter.setSupplementalDictionaryEnabled(false, for: "address")
        offered = try offersHitotsuya()
        XCTAssertFalse(offered.default, "the default session replayed a lattice built before the toggle")
        XCTAssertFalse(offered.other, "another session replayed a lattice built before the toggle")

        converter.setSupplementalDictionaryEnabled(true, for: "address")
        offered = try offersHitotsuya()
        XCTAssertTrue(offered.default)
        XCTAssertTrue(offered.other)
    }
}
