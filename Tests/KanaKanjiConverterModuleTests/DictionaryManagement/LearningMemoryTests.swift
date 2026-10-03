@testable import KanaKanjiConverterModule
import XCTest

final class LearningMemoryTests: XCTestCase {
    static let resourceURL = Bundle.module.resourceURL!.appendingPathComponent("DictionaryMock", isDirectory: true)

    private func getConfigForMemoryTest(memoryURL: URL) -> LearningConfig {
        .init(learningType: .inputAndOutput, maxMemoryCount: 32, memoryURL: memoryURL)
    }

    func testSaveSkipsWhenNoPendingMemory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = LearningManager(dictionaryURL: Self.resourceURL)
        _ = manager.updateConfig(self.getConfigForMemoryTest(memoryURL: dir))

        XCTAssertFalse(try manager.save())

        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        manager.update(data: [element])
        XCTAssertTrue(try manager.save())
        XCTAssertFalse(try manager.save())
    }

    func testPauseFileIsClearedOnInit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let manager = LearningManager(dictionaryURL: Self.resourceURL)
        _ = manager.updateConfig(config)

        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        manager.update(data: [element])
        try manager.save()

        // ポーズファイルを設置
        let pauseURL = dir.appendingPathComponent(".pause", isDirectory: false)
        FileManager.default.createFile(atPath: pauseURL.path, contents: Data())
        XCTAssertTrue(LongTermLearningMemory.memoryCollapsed(directoryURL: dir))

        // ここで副作用が発生
        _ = manager.updateConfig(config)

        // 学習の破壊状態が回復されていることを確認
        XCTAssertFalse(LongTermLearningMemory.memoryCollapsed(directoryURL: dir))
        try? FileManager.default.removeItem(at: pauseURL)
    }

    func testMemoryFilesCreateAndRemove() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let manager = LearningManager(dictionaryURL: Self.resourceURL)
        _ = manager.updateConfig(config)

        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        manager.update(data: [element])
        try manager.save()

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "memory.louds" })
        XCTAssertTrue(files.contains { $0.lastPathComponent == "memory.loudschars2" })
        XCTAssertTrue(files.contains { $0.lastPathComponent == "memory.memorymetadata" })
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasSuffix(".loudstxt3") })

        manager.resetMemory()
        let filesAfter = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(filesAfter.isEmpty)
    }

    func testForgetMemory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningManagerPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)

        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let state = dicdataStore.prepareState()
        _ = state.learningMemoryManager.updateConfig(config)
        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])
        try state.learningMemoryManager.save()

        let charIDs = "テスト".map { dicdataStore.character2charId($0) }
        let indices = dicdataStore.perfectMatchingSearch(query: "memory", charIDs: charIDs, state: state)
        let dicdata = dicdataStore.getDicdataFromLoudstxt3(identifier: "memory", indices: indices, state: state)
        XCTAssertFalse(dicdata.isEmpty)
        XCTAssertTrue(dicdata.contains { $0.word == element.word && $0.ruby == element.ruby })

        state.forgetMemory(
            Candidate(
                text: element.word,
                value: element.value(),
                composingCount: .inputCount(3),
                lastMid: element.mid,
                data: [element]
            )
        )
        let indices2 = dicdataStore.perfectMatchingSearch(query: "memory", charIDs: charIDs, state: state)
        let dicdata2 = dicdataStore.getDicdataFromLoudstxt3(identifier: "memory", indices: indices2, state: state)
        XCTAssertFalse(dicdata2.contains { $0.word == element.word && $0.ruby == element.ruby })
    }

    /// 検証用の一時学習ディレクトリを作る
    ///
    /// 呼び出し側が使い終わったら削除する
    ///
    /// - Returns: 作成した空ディレクトリのURL
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1語だけを永続化した状態を作る
    ///
    /// 未確定のまま残さず保存まで行い、照会系の前提条件を整える
    ///
    /// - Parameters:
    ///   - word: 表記
    ///   - ruby: 読み
    ///   - cid: 品詞ID
    ///   - state: 学習設定済みの辞書状態
    private func persistElement(word: String, ruby: String, cid: Int, into state: DicdataStoreState) throws {
        let element = DicdataElement(word: word, ruby: ruby, cid: cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])
        try state.learningMemoryManager.save()
    }

    /// 設定更新が記憶URL変更時のみ再読み込みを報告することを検証する
    ///
    /// 同じ記憶先の再設定では無駄な読み直しをせず、記憶先が変わったときと学習無効化のときだけ再読み込みする
    func testUpdateConfigReportsCacheResetOnlyWhenMemoryURLChanges() throws {
        let dirA = try makeTemporaryDirectory()
        let dirB = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let manager = LearningManager(dictionaryURL: Self.resourceURL)

        XCTAssertTrue(manager.updateConfig(self.getConfigForMemoryTest(memoryURL: dirA)))
        XCTAssertFalse(manager.updateConfig(self.getConfigForMemoryTest(memoryURL: dirA)))
        XCTAssertTrue(manager.updateConfig(self.getConfigForMemoryTest(memoryURL: dirB)))
        XCTAssertTrue(manager.updateConfig(.init(learningType: .nothing, maxMemoryCount: 32, memoryURL: dirB)))
    }

    /// 記憶先の切り替えで古い記憶の読み出しが混ざらないことを検証する
    ///
    /// 別ディレクトリの学習語が前の記憶先の照会に現れず、切り替え先の語だけが当たる
    func testMemoryURLChangeInvalidatesCachedMemoryLOUDS() throws {
        let dirA = try makeTemporaryDirectory()
        let dirB = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)

        let stateA = dicdataStore.prepareState()
        stateA.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dirA))
        try persistElement(word: "藍", ruby: "アイ", cid: CIDData.一般名詞.cid, into: stateA)

        let stateB = dicdataStore.prepareState()
        stateB.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dirB))
        try persistElement(word: "上", ruby: "ウエ", cid: CIDData.一般名詞.cid, into: stateB)

        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dirA))
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["アイ"]).map(\.word), ["藍"])

        // 学習のコミットを挟まずにディレクトリだけを切り替える
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dirB))
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["アイ"]), [])
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["ウエ"]).map(\.word), ["上"])
    }

    /// 同一読み表記の品詞違いを全て返すことを検証する
    ///
    /// 候補注釈と削除は品詞違いも区別するため、点照会で変種を落とさない
    func testPersistedLearningMemoryKeysReturnsEveryCidVariant() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))

        try persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)
        try persistElement(word: "テスト", ruby: "テスト", cid: CIDData.固有名詞.cid, into: state)

        let keys = try state.persistedLearningMemoryKeys(exactReadings: ["テスト"])
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.allSatisfy { $0.reading == "テスト" && $0.word == "テスト" })
        XCTAssertEqual(
            Set(keys.map(\.lcid)),
            [CIDData.一般名詞.cid, CIDData.固有名詞.cid]
        )
    }

    /// 未知文字と未登録読みを空で返すことを検証する
    ///
    /// 照合表に無い文字は読み出し前に棄却し、未登録の読みも空になる
    func testPersistedLearningMemoryKeysRejectsUnknownCharacterAndAbsentReading() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        try persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)

        // charID.chidに無い文字はtrieに存在し得ないので、シャードを読まずに棄却される
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["🍣"]), [])
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["アイ"]), [])
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: []), [])
    }

    /// 未確定の一時記憶を照会対象外にすることを検証する
    ///
    /// 点照会は永続化済みだけを見て、保存前の学習語を注釈や削除に使わない
    func testPersistedLearningMemoryKeysIgnoresUncommittedTemporalMemory() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        try persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)

        let pending = DicdataElement(word: "未確定", ruby: "ミカクテイ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [pending])

        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["ミカクテイ"]), [])
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["テスト"]).map(\.word), ["テスト"])
    }

    /// 中断中の写しへの照会が失敗することを検証する
    ///
    /// pause中の不完全な永続記憶を読まず、一時停止を示す失敗で知らせる
    func testPersistedLearningMemoryKeysThrowsOnPausedSnapshot() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        try persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)

        let pauseURL = dir.appendingPathComponent(".pause", isDirectory: false)
        FileManager.default.createFile(atPath: pauseURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: pauseURL) }

        XCTAssertThrowsError(try state.persistedLearningMemoryKeys(exactReadings: ["テスト"])) { error in
            XCTAssertEqual(error as? LearningMemoryEnumerationError, .pausedSnapshot)
        }
    }

    /// 単一走査の列挙が上限と全体件数を正しく返すことを検証する
    ///
    /// 上限内の要求は全件と次位置なしを返し、上限超過では切り詰め件数と次位置を返す
    func testSinglePassEnumerationHonorsLimitWithoutClamping() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        for ruby in ["アイ", "ウエ", "オカ"] {
            try persistElement(word: ruby, ruby: ruby, cid: CIDData.一般名詞.cid, into: state)
        }

        let all = try state.learningMemoryEntriesSinglePass(limit: 65_536)
        XCTAssertEqual(all.entries.count, 3)
        XCTAssertEqual(all.totalCount, 3)
        XCTAssertNil(all.nextOffset)

        let truncated = try state.learningMemoryEntriesSinglePass(limit: 2)
        XCTAssertEqual(truncated.entries.count, 2)
        XCTAssertEqual(truncated.totalCount, 3)
        XCTAssertEqual(truncated.nextOffset, 2)
    }

    func testCoarseForgetMemory() throws {
        // ForgetMemoryは「粗い」チェックを行うため、品詞が異なっていても同時に忘却される
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningManagerPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)

        let config = self.getConfigForMemoryTest(memoryURL: dir)
        let state = dicdataStore.prepareState()
        _ = state.learningMemoryManager.updateConfig(config)
        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])
        let differentCidElement = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [differentCidElement])
        try state.learningMemoryManager.save()

        let charIDs = "テスト".map { dicdataStore.character2charId($0) }
        let indices = dicdataStore.perfectMatchingSearch(query: "memory", charIDs: charIDs, state: state)
        let dicdata = dicdataStore.getDicdataFromLoudstxt3(identifier: "memory", indices: indices, state: state)
        XCTAssertFalse(dicdata.isEmpty)
        XCTAssertEqual(dicdata.count { $0.word == element.word && $0.ruby == element.ruby }, 2)

        state.forgetMemory(
            Candidate(
                text: element.word,
                value: element.value(),
                composingCount: .inputCount(3),
                lastMid: element.mid,
                data: [element]
            )
        )

        let indices2 = dicdataStore.perfectMatchingSearch(query: "memory", charIDs: charIDs, state: state)
        let dicdata2 = dicdataStore.getDicdataFromLoudstxt3(identifier: "memory", indices: indices2, state: state)
        XCTAssertFalse(dicdata2.contains { $0.word == element.word && $0.ruby == element.ruby })
    }

    /// 保存失敗を伝えて未保存の学習を保つことを検証する
    ///
    /// 書き込みに失敗しても成功扱いにせず、保留中の学習を捨てずに次回の保存で書き出す
    func testSavePropagatesWriteFailureAndRetainsPendingMemory() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))

        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])

        // 書き込み失敗を起こすため、メモリディレクトリを同パスの通常ファイルに置き換える (ENOTDIR)
        try FileManager.default.removeItem(at: dir)
        FileManager.default.createFile(atPath: dir.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        XCTAssertThrowsError(try state.learningMemoryManager.save())

        // ディレクトリを復旧し、同じマネージャで再保存すると成功する (pending が保持されていた証明)
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(try state.learningMemoryManager.save())

        let keys = try state.persistedLearningMemoryKeys(exactReadings: ["テスト"])
        XCTAssertFalse(keys.isEmpty)
        XCTAssertTrue(keys.contains { $0.word == "テスト" })
    }

    /// 中断後失敗の再試行で保留分を二重加算しないことを検証する
    ///
    /// pause作成後の失敗では書き出し済みの内容が次回に復元されるため、保留分を捨てて二重加算を防ぐ
    func testSaveFailureAfterPauseDoesNotDoubleCountPendingMemoryOnRetry() throws {
        let dir = try makeTemporaryDirectory()
        let loudsURL = dir.appendingPathComponent("memory.louds", isDirectory: false)
        let lockedURL = loudsURL.appendingPathComponent("locked", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedURL.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        try persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)

        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])

        // pauseの書き出し後に最後に上書きされるmemory.loudsを、削除できないディレクトリに置き換える
        try FileManager.default.removeItem(at: loudsURL)
        try FileManager.default.createDirectory(at: lockedURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lockedURL.appendingPathComponent("file").path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedURL.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: lockedURL.path), "root ignores the permission used to inject the failure")

        XCTAssertThrowsError(try state.learningMemoryManager.save())
        XCTAssertTrue(LongTermLearningMemory.memoryCollapsed(directoryURL: dir))

        // 置き換えを可能に戻して再試行すると、接尾辞2のファイルの復元によって保留分が1回分だけ反映される
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedURL.path)
        try FileManager.default.removeItem(at: loudsURL)
        XCTAssertTrue(try state.learningMemoryManager.save())
        XCTAssertFalse(LongTermLearningMemory.memoryCollapsed(directoryURL: dir))

        let entries = try state.learningMemoryEntriesSinglePass(limit: 65_536).entries
        XCTAssertEqual(entries.filter { $0.data.word == "テスト" }.map(\.count), [2])
    }

    /// 欠けた破片への点照会が失敗することを検証する
    ///
    /// 存在しない破片を読もうとせず、破損を示す失敗で知らせる
    func testPersistedLearningMemoryKeysThrowsMalformedShardWhenShardIsMissing() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        try persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)

        // memory0.loudstxt3 のみ削除し、他ファイルは残す
        try FileManager.default.removeItem(at: dir.appendingPathComponent("memory0.loudstxt3", isDirectory: false))

        // LOUDS をディスクから読み直すため、新しい state で照会する
        let freshState = dicdataStore.prepareState()
        freshState.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        XCTAssertThrowsError(try freshState.persistedLearningMemoryKeys(exactReadings: ["テスト"])) { error in
            XCTAssertEqual(error as? LearningMemoryEnumerationError, .malformedShard)
        }
    }

    /// 現在のプロセスの仮想メモリの最大値をKiB単位で返す
    ///
    /// 読めない環境ではnilを返す
    ///
    /// - Returns: VmPeakの値、読めない環境ではnil
    private static func peakVirtualMemoryKiB() -> Int? {
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else {
            return nil
        }
        for line in status.split(separator: "\n") where line.hasPrefix("VmPeak:") {
            return Int(line.split(whereSeparator: { $0 == " " || $0 == "\t" })[1])
        }
        return nil
    }

    /// 巨大な件数を持つ壊れた付随情報を確保前に拒むことを検証する
    ///
    /// 件数どおりに確保すると数十GB級の仮想記憶を要求するため、読み出し前に検証して失敗する
    func testEnumerationRejectsHugeMetadataNodeCountBeforeAllocating() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))

        // 先頭4byteのノード数だけが壊れたメタデータ (実際のノードは1つ)
        var metadata = Data([0xFF, 0xFF, 0xFF, 0xFF])
        metadata.append(0)
        try metadata.write(to: dir.appendingPathComponent("memory.memorymetadata", isDirectory: false))

        let peakBefore = Self.peakVirtualMemoryKiB()
        XCTAssertThrowsError(try state.learningMemoryEntriesSinglePass(limit: 65_536)) { error in
            XCTAssertEqual(error as? LearningMemoryEnumerationError, .malformedMetadata)
        }
        // ノード数どおりに確保すると数十GBの仮想メモリを要求する
        if let peakBefore, let peakAfter = Self.peakVirtualMemoryKiB() {
            XCTAssertLessThan(peakAfter - peakBefore, 1 << 20, "VmPeak grew by \(peakAfter - peakBefore) KiB")
        }
    }

    /// 長期記憶を持つ学習ディレクトリを作り、ファイルを壊してから新しい学習を保存する
    ///
    /// 壊れた破片は捨てて新しい学習だけを保存し、破壊状態に陥らない
    ///
    /// - Parameter corrupt: 学習ディレクトリ内のファイルを壊す処理
    /// - Returns: 保存成否と保存後の表記集合と破壊状態の有無
    private func saveAfterCorrupting(_ corrupt: (URL) throws -> Void) throws -> (saved: Bool, words: Set<String>, collapsed: Bool) {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        try persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)
        try persistElement(word: "藍", ruby: "アイ", cid: CIDData.一般名詞.cid, into: state)

        try corrupt(dir)

        let freshState = dicdataStore.prepareState()
        freshState.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        freshState.learningMemoryManager.update(data: [
            DicdataElement(word: "上", ruby: "ウエ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        ])
        let saved = try freshState.learningMemoryManager.save()
        let words = Set(try freshState.learningMemoryEntriesSinglePass(limit: 65_536).entries.map(\.data.word))
        return (saved, words, LongTermLearningMemory.memoryCollapsed(directoryURL: dir))
    }

    /// 切り詰められた破片を読み飛ばして保存することを検証する
    ///
    /// 壊れた破片があっても捕捉不能な落ち方をせず、新しい学習だけを保存する
    func testSaveSkipsTruncatedShardInsteadOfTrapping() throws {
        let result = try saveAfterCorrupting { dir in
            let shardURL = dir.appendingPathComponent("memory0.loudstxt3", isDirectory: false)
            try Data(contentsOf: shardURL).prefix(1).write(to: shardURL)
        }
        XCTAssertTrue(result.saved)
        XCTAssertFalse(result.collapsed)
        XCTAssertEqual(result.words, ["上"])
    }

    /// 索引表が途切れた破片を読み飛ばして保存することを検証する
    ///
    /// 索引表が短い破片があっても捕捉不能な落ち方をせず、新しい学習だけを保存する
    func testSaveSkipsShardWhoseIndexTableIsCutShort() throws {
        let result = try saveAfterCorrupting { dir in
            let shardURL = dir.appendingPathComponent("memory0.loudstxt3", isDirectory: false)
            try Data(contentsOf: shardURL).prefix(4).write(to: shardURL)
        }
        XCTAssertTrue(result.saved)
        XCTAssertFalse(result.collapsed)
        XCTAssertEqual(result.words, ["上"])
    }

    /// 途切れた付随情報で止まって保存することを検証する
    ///
    /// 付随情報が途中で切れていても捕捉不能な落ち方をせず、読める範囲で新しい学習を保存する
    func testSaveStopsAtTruncatedMetadataInsteadOfTrapping() throws {
        let result = try saveAfterCorrupting { dir in
            let metadataURL = dir.appendingPathComponent("memory.memorymetadata", isDirectory: false)
            let metadata = try Data(contentsOf: metadataURL)
            try metadata.prefix(metadata.count - 1).write(to: metadataURL)
        }
        XCTAssertTrue(result.saved)
        XCTAssertFalse(result.collapsed)
        XCTAssertTrue(result.words.contains("上"))
    }

    /// 表題より短い付随情報を空として扱うことを検証する
    ///
    /// 件数すら読めない付随情報は記憶なしとみなし、新しい学習を保存する
    func testSaveTreatsMetadataShorterThanHeaderAsEmpty() throws {
        let result = try saveAfterCorrupting { dir in
            let metadataURL = dir.appendingPathComponent("memory.memorymetadata", isDirectory: false)
            try Data([0x02, 0x00]).write(to: metadataURL)
        }
        XCTAssertTrue(result.saved)
        XCTAssertFalse(result.collapsed)
        XCTAssertEqual(result.words, ["上"])
    }

    /// 読めない破片を捨てても付随情報の対応を保つことを検証する
    ///
    /// 残った破片の学習回数は変わらず、新しい学習も正しく加わる
    func testSaveKeepsMetadataAlignedAfterSkippingUnreadableShard() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let config = LearningConfig(learningType: .inputAndOutput, maxMemoryCount: 10_000, memoryURL: dir)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(config)

        // 2文字の読み 50 x 50 件で、ノード数 (ダミー2 + 1文字目50 + 2文字目2500) を2シャードに分ける
        let kana = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンガギグゲ")
        XCTAssertEqual(kana.count, 50)
        let rubies = kana.flatMap { first in kana.map { String([first, $0]) } }
        // 1語ずつ渡す (まとめて渡すと文節bigramも学習される)
        for ruby in rubies {
            state.learningMemoryManager.update(data: [
                DicdataElement(word: ruby, ruby: ruby, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
            ])
        }
        XCTAssertTrue(try state.learningMemoryManager.save())
        XCTAssertEqual(try state.learningMemoryEntriesSinglePass(limit: 65_536).totalCount, rubies.count)
        let secondShardURL = dir.appendingPathComponent("memory1.loudstxt3", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondShardURL.path))

        try FileManager.default.removeItem(at: dir.appendingPathComponent("memory0.loudstxt3", isDirectory: false))
        let freshState = dicdataStore.prepareState()
        freshState.updateLearningConfig(config)
        freshState.learningMemoryManager.update(data: [
            DicdataElement(word: "上", ruby: "ウエ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)
        ])
        XCTAssertTrue(try freshState.learningMemoryManager.save())

        // 1つ目のシャードの2文字目のノード (2048 - ダミー2 - 1文字目50 = 1996件) だけが失われ、2つ目のシャードの学習は残る
        let entries = try freshState.learningMemoryEntriesSinglePass(limit: 65_536).entries
        XCTAssertEqual(entries.count, rubies.count - 1996 + 1)
        XCTAssertTrue(entries.contains { $0.data.word == "上" })
    }

    /// 件数欄が壊れた破片を捨てて保存することを検証する
    ///
    /// 件数だけが壊れた破片は索引表が読めても捨て、残りの破片の学習回数を保つ
    func testSaveSkipsShardWhoseNodeCountFieldIsCorrupted() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let config = LearningConfig(learningType: .inputAndOutput, maxMemoryCount: 10_000, memoryURL: dir)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(config)

        // 2文字の読み 50 x 50 件を2シャードに分け、2文字目が「ア」の語だけ2回学習して、メタデータの対応のずれを回数で見分けられるようにする
        let kana = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンガギグゲ")
        let rubies = kana.flatMap { first in kana.map { String([first, $0]) } }
        let learnedTwice = { (ruby: String) in ruby.last == "ア" }
        for ruby in rubies {
            for _ in 0 ..< (learnedTwice(ruby) ? 2 : 1) {
                state.learningMemoryManager.update(data: [
                    DicdataElement(word: ruby, ruby: ruby, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
                ])
            }
        }
        XCTAssertTrue(try state.learningMemoryManager.save())
        let saved = try state.learningMemoryEntriesSinglePass(limit: 65_536).entries
        XCTAssertEqual(saved.count, rubies.count)
        XCTAssertEqual(saved.filter { $0.count == 2 }.count, kana.count)

        // 1つ目のシャードの件数 (2048) だけを1減らす
        // 索引表はファイルに収まったまま読める
        let firstShardURL = dir.appendingPathComponent("memory0.loudstxt3", isDirectory: false)
        var firstShard = try Data(contentsOf: firstShardURL)
        XCTAssertEqual(Array(firstShard.prefix(2)), [0x00, 0x08])
        firstShard.replaceSubrange(firstShard.startIndex ..< firstShard.startIndex + 2, with: [0xFF, 0x07])
        try firstShard.write(to: firstShardURL)

        let freshState = dicdataStore.prepareState()
        freshState.updateLearningConfig(config)
        freshState.learningMemoryManager.update(data: [
            DicdataElement(word: "上", ruby: "ウエ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)
        ])
        XCTAssertTrue(try freshState.learningMemoryManager.save())

        // 1つ目のシャードだけを捨て、2つ目のシャードの語は自身の回数を保つ
        let entries = try freshState.learningMemoryEntriesSinglePass(limit: 65_536).entries
        XCTAssertEqual(entries.count, rubies.count - 1996 + 1)
        XCTAssertTrue(entries.contains { $0.data.word == "上" })
        for entry in entries where entry.data.word != "上" {
            XCTAssertEqual(entry.count, learnedTwice(entry.data.ruby) ? 2 : 1, entry.data.ruby)
        }
    }
}
