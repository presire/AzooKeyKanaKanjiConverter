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

        XCTAssertFalse(manager.save())

        let element = DicdataElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        manager.update(data: [element])
        XCTAssertTrue(manager.save())
        XCTAssertFalse(manager.save())
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
        manager.save()

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
        manager.save()

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
        state.learningMemoryManager.save()

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

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LearningMemoryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func persistElement(word: String, ruby: String, cid: Int, into state: DicdataStoreState) {
        let element = DicdataElement(word: word, ruby: ruby, cid: cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [element])
        state.learningMemoryManager.save()
    }

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
        persistElement(word: "藍", ruby: "アイ", cid: CIDData.一般名詞.cid, into: stateA)

        let stateB = dicdataStore.prepareState()
        stateB.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dirB))
        persistElement(word: "上", ruby: "ウエ", cid: CIDData.一般名詞.cid, into: stateB)

        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dirA))
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["アイ"]).map(\.word), ["藍"])

        // 学習のコミットを挟まずにディレクトリだけを切り替える
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dirB))
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["アイ"]), [])
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["ウエ"]).map(\.word), ["上"])
    }

    func testPersistedLearningMemoryKeysReturnsEveryCidVariant() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))

        persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)
        persistElement(word: "テスト", ruby: "テスト", cid: CIDData.固有名詞.cid, into: state)

        let keys = try state.persistedLearningMemoryKeys(exactReadings: ["テスト"])
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.allSatisfy { $0.reading == "テスト" && $0.word == "テスト" })
        XCTAssertEqual(
            Set(keys.map(\.lcid)),
            [CIDData.一般名詞.cid, CIDData.固有名詞.cid]
        )
    }

    func testPersistedLearningMemoryKeysRejectsUnknownCharacterAndAbsentReading() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)

        // charID.chid に無い文字は trie に存在し得ないので、シャードを読まずに棄却される
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["🍣"]), [])
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["アイ"]), [])
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: []), [])
    }

    func testPersistedLearningMemoryKeysIgnoresUncommittedTemporalMemory() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)

        let pending = DicdataElement(word: "未確定", ruby: "ミカクテイ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [pending])

        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["ミカクテイ"]), [])
        XCTAssertEqual(try state.persistedLearningMemoryKeys(exactReadings: ["テスト"]).map(\.word), ["テスト"])
    }

    func testPersistedLearningMemoryKeysThrowsOnPausedSnapshot() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        persistElement(word: "テスト", ruby: "テスト", cid: CIDData.一般名詞.cid, into: state)

        let pauseURL = dir.appendingPathComponent(".pause", isDirectory: false)
        FileManager.default.createFile(atPath: pauseURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: pauseURL) }

        XCTAssertThrowsError(try state.persistedLearningMemoryKeys(exactReadings: ["テスト"])) { error in
            XCTAssertEqual(error as? LearningMemoryEnumerationError, .pausedSnapshot)
        }
    }

    func testSinglePassEnumerationHonorsLimitWithoutClamping() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dicdataStore = DicdataStore(dictionaryURL: Self.resourceURL)
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(self.getConfigForMemoryTest(memoryURL: dir))
        for ruby in ["アイ", "ウエ", "オカ"] {
            persistElement(word: ruby, ruby: ruby, cid: CIDData.一般名詞.cid, into: state)
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
        state.learningMemoryManager.save()

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
}
