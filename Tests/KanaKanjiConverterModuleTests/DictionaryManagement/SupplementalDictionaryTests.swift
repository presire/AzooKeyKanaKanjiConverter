@testable import KanaKanjiConverterModule
import SwiftUtils
import XCTest

/// 読み取り専用の補助LOUDS辞書のテストをまとめる
///
/// 補助辞書は住所辞書や工学用語辞書が利用し、システム辞書とcharID.chidとcbとmm.binaryを共有する
///
/// loudsだけを別ディレクトリに持ち、名前空間付き識別子で分離する
final class SupplementalDictionaryTests: XCTestCase {
    /// 辞書模擬のURLを返す
    private var dictionaryMockURL: URL {
        Bundle.module.resourceURL!.standardizedFileURL.appendingPathComponent("DictionaryMock", isDirectory: true)
    }

    /// 生成した一時ディレクトリの一覧を保つ
    ///
    /// tearDownでまとめて削除し、作業域に残さない
    private var createdDirectories: [URL] = []

    /// 生成した一時ディレクトリを削除する
    ///
    /// 他のテストへ作業域が漏れないようにする
    override func tearDown() {
        for url in self.createdDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        self.createdDirectories = []
        super.tearDown()
    }

    /// 照合スタンプの原文を読む
    ///
    /// - Returns: DictionaryMockのcharID.chidの内容
    private func systemCharIDText() throws -> String {
        try String(
            contentsOf: self.dictionaryMockURL.appendingPathComponent("louds/charID.chid", isDirectory: false),
            encoding: .utf8
        )
    }

    /// 文字からIDへの照合表を作る
    ///
    /// - Returns: DictionaryMockと同一順序の文字ID対応
    private func systemCharIDs() throws -> [Character: UInt8] {
        let text = try self.systemCharIDText()
        return [Character: UInt8](uniqueKeysWithValues: text.enumerated().map { ($0.element, UInt8($0.offset)) })
    }

    /// 読みを文字ID列に変える
    ///
    /// 照合表に無い文字は落とす
    ///
    /// - Parameters:
    ///   - ruby: 変える対象の読み
    ///   - map: 文字からIDへの照合表
    /// - Returns: 変換できた文字ID列
    private func charIDs(_ ruby: String, _ map: [Character: UInt8]) -> [UInt8] {
        ruby.compactMap { map[$0] }
    }

    /// 先頭カナ別破片のLOUDS辞書を一時ディレクトリに生成する
    ///
    /// DictionaryMockは識別子を逃避しない旧命名 (シ.louds) のため、DicdataStore経由の検索には使えない
    ///
    /// テスト用のシステム辞書もここで生成する
    ///
    /// - Parameters:
    ///   - entries: 書き込む辞書要素列
    ///   - name: 辞書の基底名
    ///   - charIDText: loudsのcharID.chidに書き込む照合用スタンプ、既定はDictionaryMockと同一
    /// - Returns: 生成した辞書のURL
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

    /// 旧単一API用の補助辞書を作る
    ///
    /// - Parameter entries: 書き込む辞書要素列
    /// - Returns: 生成した補助辞書のURL
    private func makeSupplementalDictionary(
        entries: [DicdataElement],
        charIDText: String? = nil
    ) throws -> URL {
        try self.makeShardedDictionary(entries: entries, name: "SupplementalDictionary", charIDText: charIDText)
    }

    /// 検証用のシステム辞書語を返す
    ///
    /// 同じ読みシオを持つ潮と塩の2語で、補助語との混同を検出する
    ///
    /// - Returns: 検証語の辞書要素列
    private func systemEntries() -> [DicdataElement] {
        [
            DicdataElement(word: "潮", ruby: "シオ", lcid: 1288, rcid: 1288, mid: 501, value: -6),
            DicdataElement(word: "塩", ruby: "シオ", lcid: 1288, rcid: 1288, mid: 501, value: -6)
        ]
    }

    /// 検証用のシステム辞書を作る
    ///
    /// - Returns: 生成したシステム辞書のURL
    private func makeSystemDictionary() throws -> URL {
        try self.makeShardedDictionary(entries: self.systemEntries(), name: "SystemDictionary")
    }

    /// 検証用の住所辞書語を返す
    ///
    /// 一ツ家と上伊那郡辰野町の2語で、地名一般の品詞と低い点数を持つ
    ///
    /// - Returns: 検証語の辞書要素列
    private func addressEntries() -> [DicdataElement] {
        [
            DicdataElement(word: "一ツ家", ruby: "ヒトツヤ", lcid: 1293, rcid: 1293, mid: 501, value: -15.5),
            DicdataElement(word: "上伊那郡辰野町", ruby: "カミイナグンタツノマチ", lcid: 1293, rcid: 1293, mid: 501, value: -15.5)
        ]
    }

    /// 名前空間付き識別子で完全一致検索した表記集合を返す
    ///
    /// - Parameters:
    ///   - store: 検索対象の辞書保管
    ///   - state: 辞書状態
    ///   - ruby: 完全一致させる読み
    ///   - sourceID: 補助辞書の出所ID
    ///   - map: 文字からIDへの照合表
    /// - Returns: 当たった語の表記集合
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

    /// 読みのラティス検索で得た辞書要素列を返す
    ///
    /// - Parameters:
    ///   - store: 検索対象の辞書保管
    ///   - state: 辞書状態
    ///   - reading: 変換対象の読み
    /// - Returns: ラティス節の辞書要素列
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

    /// 読みのラティス検索で得た表記集合を返す
    ///
    /// - Parameters:
    ///   - store: 検索対象の辞書保管
    ///   - state: 辞書状態
    ///   - reading: 変換対象の読み
    /// - Returns: ラティス節の表記集合
    private func latticeWords(_ store: DicdataStore, state: DicdataStoreState, reading: String) -> Set<String> {
        Set(self.latticeData(store, state: state, reading: reading).map { $0.word })
    }

    // MARK: - 収録と参加

    /// 補助語が名前空間付き識別子で読めることを検証する
    ///
    /// 補助辞書の語が自分の出所の木から正しく読める
    func testSupplementalEntryIsReadableThroughNamespacedIdentifier() throws {
        let map = try self.systemCharIDs()
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        XCTAssertTrue(store.hasSupplementalDictionary)
        let state = store.prepareState()

        XCTAssertEqual(self.words(store, state: state, perfectMatch: "ヒトツヤ", map: map), ["一ツ家"])
        XCTAssertEqual(self.words(store, state: state, perfectMatch: "カミイナグンタツノマチ", map: map), ["上伊那郡辰野町"])
    }

    /// 補助語がラティス検索に参加することを検証する
    ///
    /// ひとつやの変換に一ツ家が現れる
    func testSupplementalEntryParticipatesInLatticeLookup() throws {
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()

        XCTAssertTrue(self.latticeWords(store, state: state, reading: "ひとつや").contains("一ツ家"))
    }

    /// 補助語が予測に出ることを検証する
    ///
    /// 前方一致の予測でも補助辞書の語を拾う
    func testSupplementalEntryParticipatesInPrediction() throws {
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        let state = store.prepareState()

        let predicted = Set(store.getPredictionLOUDSDicdata(key: "ヒトツ", state: state).map { $0.word })
        XCTAssertTrue(predicted.contains("一ツ家"), "prediction did not include the supplemental entry: \(predicted)")
    }

    /// 補助語が辞書由来の印を持たないことを検証する
    ///
    /// 補助辞書の語は利用者辞書でも学習語でもないため、付随情報は空のままである
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

    /// 無効化した補助辞書の語が出ないことを検証する
    ///
    /// 完全一致とラティスと予測の3経路とも補助語を出さない
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

    /// 補助辞書を再有効化できることを検証する
    ///
    /// 保管を作り直さずに旗の切り替えだけで反映される
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

    /// 補助辞書の欠落時に通常変換が保たれることを検証する
    ///
    /// 存在しない補助先では補助だけが無効になり、システム辞書の語は出続ける
    func testMissingSupplementalDirectoryDisablesOnlyTheSupplementalDictionary() throws {
        let systemURL = try self.makeSystemDictionary()
        let missingURL = URL(fileURLWithPath: "/nonexistent/hazkey-address-dictionary")
        let store = DicdataStore(dictionaryURL: systemURL, supplementalDictionaryURL: missingURL)
        XCTAssertFalse(store.hasSupplementalDictionary)
        let state = store.prepareState()

        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しお").isSuperset(of: ["潮", "塩"]))
    }

    /// 照合表の不一致時に通常変換が保たれることを検証する
    ///
    /// 照合用スタンプが合わない補助だけが無効になり、システム辞書の語は出続ける
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

    /// 照合表の欠落時に補助なしとして扱うことを検証する
    ///
    /// 照合用スタンプが無い補助辞書は読み込まず、通常変換に影響しない
    func testMissingCharIDStampDisablesOnlyTheSupplementalDictionary() throws {
        let supplementalURL = try self.makeSupplementalDictionary(entries: self.addressEntries())
        try FileManager.default.removeItem(
            at: supplementalURL.appendingPathComponent("louds/charID.chid", isDirectory: false)
        )
        let store = DicdataStore(dictionaryURL: self.dictionaryMockURL, supplementalDictionaryURL: supplementalURL)
        XCTAssertFalse(store.hasSupplementalDictionary)
    }

    /// 補助破片の破損時に通常変換が保たれることを検証する
    ///
    /// 中身を壊した補助破片は読まず、システム辞書の語は出続ける
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

    /// 補助破片の切り詰め時に通常変換が保たれることを検証する
    ///
    /// 途中で切れた補助破片は読まず、システム辞書の語は出続ける
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

    /// 同じ先頭文字の補助破片が本体破片を隠さないことを検証する
    ///
    /// 同じ先頭文字でも本体と補助は別の木を引き、互いの語を混ぜない
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

    /// 先読みした本体破片を補助照会に使わないことを検証する
    ///
    /// 辞書先読み時も補助照会は自分の出所の木を引き、本体の語と混ざらない
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

    /// 補助なしの保管が従来どおり動くことを検証する
    ///
    /// 補助先を与えない構築では補助照会が空になり、通常変換は変わらない
    func testStoreWithoutSupplementalURLBehavesExactlyAsBefore() throws {
        let systemURL = try self.makeSystemDictionary()
        let store = DicdataStore(dictionaryURL: systemURL)
        XCTAssertFalse(store.hasSupplementalDictionary)
        let state = store.prepareState()
        XCTAssertNil(store.loadLOUDS(query: DicdataStore.supplementalQuery("ヒ"), state: state))
        XCTAssertTrue(self.latticeWords(store, state: state, reading: "しお").isSuperset(of: ["潮", "塩"]))
    }

    // MARK: - KanaKanjiConverter 経由

    /// 旧単一APIの可用性と切り替えが動くことを検証する
    ///
    /// 変換器越しに補助の有無が分かり、旗の切り替えが反映される
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

    /// 住所出所の検証辞書を作る
    ///
    /// 汐入の1語で、地名一般の品詞を持つ
    ///
    /// - Returns: 生成した住所辞書のURL
    private func makeAddressDictionary() throws -> URL {
        try self.makeShardedDictionary(
            entries: [DicdataElement(word: "汐入", ruby: "シオイリ", lcid: 1293, rcid: 1293, mid: 501, value: -15.5)],
            name: "AddressDictionary"
        )
    }

    /// 工学辞書の検証語を作る
    ///
    /// 住所辞書と同じ先頭文字と木の形を持たせ、節番号が一致しても取り違えないことを検出する
    ///
    /// - Parameter charIDText: 照合用スタンプ、既定は本体と同一
    /// - Returns: 生成した工学辞書のURL
    private func makeEngineeringDictionary(charIDText: String? = nil) throws -> URL {
        try self.makeShardedDictionary(
            entries: [DicdataElement(word: "Shiokara", ruby: "シオカラ", lcid: 1288, rcid: 1288, mid: 501, value: -15.5)],
            name: "EngineeringDictionary",
            charIDText: charIDText
        )
    }

    /// 複数出所の辞書保管を作る
    ///
    /// 住所と工学の2出所を宣言順に登録する
    ///
    /// - Parameters:
    ///   - systemURL: 本体辞書のURL
    ///   - addressURL: 住所辞書のURL
    ///   - engineeringURL: 工学辞書のURL
    ///   - preloadDictionary: 辞書を先読みするかどうか
    /// - Returns: 複数出所の辞書保管
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

    /// 同じ先頭文字の出所が自分の木を引くことを検証する
    ///
    /// 節番号が一致しても出所を取り違えず、先読みの有無の両方で成り立つ
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

    /// 予測が全出所から集まることを検証する
    ///
    /// 前方一致の予測でも住所と工学の両方の語を拾う
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

    /// 出所ごとの切り替えが独立であることを検証する
    ///
    /// 片方を切っても他方は出続け、可用性の表示は切り替えと連動しない
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

    /// 切り替えが状態単位であることを検証する
    ///
    /// 有効旗は辞書状態ごとに持つため、同じ保管を分け合う別の状態には影響しない
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

    /// 照合表の不一致が出所単位で無効化することを検証する
    ///
    /// 合わない出所だけが無効になり、他の出所の語は出続ける
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

    /// 辞書置き場の欠落が出所単位で無効化することを検証する
    ///
    /// 存在しない出所だけが無効になり、他の出所の語は出続ける
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

    /// 片出所の切り詰め破片が他出所に及ばないことを検証する
    ///
    /// 切れた破片の出所だけが空になり、他の出所の語は出続ける
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

    /// 宣言順を変えても出所解決が変わらないことを検証する
    ///
    /// 出所IDと木の対応は宣言順に依存しない
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

    /// 旧切り替えが先頭出所を指すことを検証する
    ///
    /// 出所を指定しない旧窓口は宣言順の先頭だけを切り替える
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

    /// 複数出所の不正な構成を拒むことを検証する
    ///
    /// 空列と重複IDと不正IDを受け付けず、使える文字のIDは受け付ける
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

    /// 未知の出所IDを旗を作らずに拒むことを検証する
    ///
    /// 未登録IDの切り替えは失敗し、可用性も照会も空のままになる
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

    /// 同読み同表記の品詞違いを全出所分保つことを検証する
    ///
    /// 読みと表記が同じでも品詞が違えば別の語として残す
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

    /// 出所指定の可用性と切り替えが動くことを検証する
    ///
    /// 変換器越しに出所ごとの有無が分かり、出所指定の切り替えが反映される
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

    /// 検証用の変換要求を作る
    ///
    /// 学習を切って辞書由来の候補だけで判定する
    ///
    /// - Returns: 固定条件の変換要求
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

    /// 出所旗の変化時だけZenzaiの覚え書きを捨てることを検証する
    ///
    /// 同じ値の再設定や未知IDでは捨てず、実際に変わったときだけ辞書由来の受け皿を作り直す
    func testZenzaiMemoizationCacheIsPurgedOnlyWhenASourceFlagActuallyChanges() throws {
        let converter = try KanaKanjiConverter(
            dictionaryURL: self.dictionaryMockURL,
            supplementalDictionaries: [
                SupplementalDictionarySource(id: "address", directoryURL: try self.makeAddressDictionary()),
                SupplementalDictionarySource(id: "engineering", directoryURL: try self.makeEngineeringDictionary())
            ]
        )
        /// 評価文の覚え書きを種まきする
        func seed() {
            converter.zenzaiMemoizationCache.cacheEvaluationPromptTokens([1, 2, 3], for: "probe")
        }
        /// 評価文の覚え書きの有無を返す
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

    /// 切り替えがどの打ち合わせの進行中格子にも隠されないことを検証する
    ///
    /// 旗が変わると全打ち合わせの格子を作り直し、切った語はどの打ち合わせにも出ない
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
        /// 既定と別の打ち合わせの両方で一ツ家が出るかを返す
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
