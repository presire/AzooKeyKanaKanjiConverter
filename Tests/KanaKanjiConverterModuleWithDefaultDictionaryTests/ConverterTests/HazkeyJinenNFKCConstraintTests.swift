import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [Hazkey Community Patch]
final class HazkeyJinenNFKCConstraintTests: XCTestCase {
    private func composingText(_ reading: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(reading, inputStyle: .direct)
        return c
    }

    private func makePlainState() -> (DicdataStore, DicdataStoreState, Kana2Kanji) {
        let dicdataStore = DicdataStore.withDefaultDictionary()
        let state = dicdataStore.prepareState()
        let kanaKanji = Kana2Kanji(dicdataStore: dicdataStore)
        return (dicdataStore, state, kanaKanji)
    }

    private func makeCustomLattice(nodesByPosition: [[LatticeNode]], surfaceCount: Int) -> Lattice {
        Lattice(
            inputCount: surfaceCount,
            surfaceCount: surfaceCount,
            rawNodes: nodesByPosition
        )
    }

    private func staticNode(word: String, ruby: String, start: Int, end: Int, value: PValue = -5, metadata: DicdataElementMetadata = .empty) -> LatticeNode {
        LatticeNode(
            data: DicdataElement(
                word: word,
                ruby: ruby,
                cid: CIDData.一般名詞.cid,
                mid: MIDData.一般.mid,
                value: value,
                metadata: metadata
            ),
            range: .input(from: start, to: end)
        )
    }

    private func constrainedCandidates(
        _ kanaKanji: Kana2Kanji,
        reading: String,
        constraint: Kana2Kanji.PrefixConstraint,
        nBest: Int,
        preprocessedLattice: Lattice? = nil,
        state: DicdataStoreState
    ) -> [Candidate] {
        let result = kanaKanji.kana2lattice_all_with_prefix_constraint(
            self.composingText(reading),
            N_best: nBest,
            constraint: constraint,
            preprocessedLattice: preprocessedLattice,
            dicdataStoreState: state
        )
        return result.result.getCandidateData().map(kanaKanji.processClauseCandidate)
    }

    func testJinenNFKCConstraintMatchesFullwidthLatticeCandidate() {
        let (_, state, kanaKanji) = self.makePlainState()
        let input = "えー"
        let lattice = self.makeCustomLattice(
            nodesByPosition: [
                [self.staticNode(word: "Ａ", ruby: "エー", start: 0, end: 2)],
                [],
            ],
            surfaceCount: 2
        )
        let constraint = Kana2Kanji.PrefixConstraint(
            Array("A".utf8),
            hasEOS: false,
            normalizesUnfixedConstraintForJinen: true
        )

        for nBest in [1, 3] {
            lattice.resetNodeStates()
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: input,
                constraint: constraint,
                nBest: nBest,
                preprocessedLattice: lattice,
                state: state
            )
            XCTAssertEqual(
                candidates.first?.text, "Ａ",
                "N_best=\(nBest): Jinen NFKC制約 A で全角ラティス候補 Ａ が一致すべき"
            )
        }
    }

    func testZenzRawConstraintStillRejectsFullwidthMismatch() {
        let (_, state, kanaKanji) = self.makePlainState()
        let input = "えー"
        let lattice = self.makeCustomLattice(
            nodesByPosition: [
                [self.staticNode(word: "Ａ", ruby: "エー", start: 0, end: 2)],
                [],
            ],
            surfaceCount: 2
        )
        let constraint = Kana2Kanji.PrefixConstraint(
            Array("A".utf8),
            hasEOS: false,
            normalizesUnfixedConstraintForJinen: false
        )

        for nBest in [1, 3] {
            lattice.resetNodeStates()
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: input,
                constraint: constraint,
                nBest: nBest,
                preprocessedLattice: lattice,
                state: state
            )
            XCTAssertTrue(
                candidates.isEmpty,
                "N_best=\(nBest): Zenz生制約 A は全角 Ａ を弾くべき"
            )
        }
    }

    func testJinenNFKCConstraintPreservesRawFixedPrefix() {
        let (_, state, kanaKanji) = self.makePlainState()
        let input = "あい"
        let lattice = self.makeCustomLattice(
            nodesByPosition: [
                [
                    self.staticNode(word: "A", ruby: "ア", start: 0, end: 1, value: -1),
                    self.staticNode(word: "Ａ", ruby: "ア", start: 0, end: 1, value: -5),
                ],
                [
                    self.staticNode(word: "１", ruby: "イ", start: 1, end: 2, value: -5),
                ],
            ],
            surfaceCount: 2
        )
        let fixedBytes = Array("Ａ".utf8)
        let constraint = Kana2Kanji.PrefixConstraint(
            fixedBytes + Array("1".utf8),
            hasEOS: false,
            fixedPrefix: .init(byteCount: fixedBytes.count, rubyCount: 1),
            normalizesUnfixedConstraintForJinen: true
        )

        for nBest in [1, 3] {
            lattice.resetNodeStates()
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: input,
                constraint: constraint,
                nBest: nBest,
                preprocessedLattice: lattice,
                state: state
            )
            let texts = candidates.map(\.text)
            XCTAssertEqual(
                texts, ["Ａ１"],
                "N_best=\(nBest): fixedPrefix Ａ は生UTF-8で維持し半角 A を弾きつつ、後続の半角制約 1 は全角 １ とNFKC一致すべき"
            )
        }
    }

    func testJinenNFKCConstraintHasEOSMatchesExactEnd() {
        let (_, state, kanaKanji) = self.makePlainState()
        let input = "あい"
        let lattice = self.makeCustomLattice(
            nodesByPosition: [
                [self.staticNode(word: "Ａ", ruby: "ア", start: 0, end: 1)],
                [
                    self.staticNode(word: "１", ruby: "イ", start: 1, end: 2, value: -5),
                    self.staticNode(word: "１２", ruby: "イ", start: 1, end: 2, value: -1),
                ],
            ],
            surfaceCount: 2
        )
        let constraint = Kana2Kanji.PrefixConstraint(
            Array("A1".utf8),
            hasEOS: true,
            normalizesUnfixedConstraintForJinen: true
        )

        for nBest in [1, 3] {
            lattice.resetNodeStates()
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: input,
                constraint: constraint,
                nBest: nBest,
                preprocessedLattice: lattice,
                state: state
            )
            XCTAssertEqual(
                candidates.map(\.text), ["Ａ１"],
                "N_best=\(nBest): hasEOS=true かつ NFKC制約 A1 では終端一致する Ａ１ のみ残るべき"
            )
        }
    }

    func testJinenNFKCConstraintHandlesNodeStraddlingFixedPrefixBoundary() {
        let (_, state, kanaKanji) = self.makePlainState()
        let input = "あい"
        let lattice = self.makeCustomLattice(
            nodesByPosition: [
                [
                    self.staticNode(word: "Ａ１", ruby: "アイ", start: 0, end: 2, value: -5),
                    self.staticNode(word: "A１", ruby: "アイ", start: 0, end: 2, value: -1),
                ],
                [],
            ],
            surfaceCount: 2
        )
        let fixedBytes = Array("Ａ".utf8)
        let constraint = Kana2Kanji.PrefixConstraint(
            fixedBytes + Array("1".utf8),
            hasEOS: true,
            fixedPrefix: .init(byteCount: fixedBytes.count, rubyCount: 1),
            normalizesUnfixedConstraintForJinen: true
        )

        for nBest in [1, 3] {
            lattice.resetNodeStates()
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: input,
                constraint: constraint,
                nBest: nBest,
                preprocessedLattice: lattice,
                state: state
            )
            XCTAssertEqual(
                candidates.map(\.text), ["Ａ１"],
                "N_best=\(nBest): fixedPrefix境界をまたぐ単一ノードでも先頭は生UTF-8、残余はNFKCで照合されるべき"
            )
        }
    }

    func testCandidateSatisfiesUnifiesRawFixedPrefixAndNFKCRemainderForJinen() {
        let (_, _, kanaKanji) = self.makePlainState()
        let fixedBytes = Array("Ａ".utf8)
        let constraint = Kana2Kanji.PrefixConstraint(
            fixedBytes + Array("1".utf8),
            hasEOS: true,
            fixedPrefix: .init(byteCount: fixedBytes.count, rubyCount: 1),
            normalizesUnfixedConstraintForJinen: true
        )
        let fullwidthFixed = Candidate(text: "Ａ１", value: 0, composingCount: .inputCount(2), lastMid: 0, data: [])
        let halfwidthFixed = Candidate(text: "A１", value: 0, composingCount: .inputCount(2), lastMid: 0, data: [])

        XCTAssertTrue(kanaKanji.candidate(fullwidthFixed, satisfies: constraint, isJinen: true))
        XCTAssertFalse(kanaKanji.candidate(halfwidthFixed, satisfies: constraint, isJinen: true))
    }

    // 比較用の候補スナップショット
    //
    // 表記と語列はSwiftの文字列ではなく生UTF-8バイト列で保持する
    // 文字列の等値判定は正準等価を吸収するため、異なる生バイト列を持つ表記を同じものとして扱ってしまう
    private struct CandidateSnapshot {
        var textUTF8: [UInt8]
        var valueBitPattern: UInt32
        var wordsUTF8: [[UInt8]]
        var metadataBits: [UInt32]

        init(text: String, valueBits: UInt32, words: [String], metadataBits: [UInt32]) {
            self.textUTF8 = Array(text.utf8)
            self.valueBitPattern = valueBits
            self.wordsUTF8 = words.map { Array($0.utf8) }
            self.metadataBits = metadataBits
        }
    }

    private func snapshots(_ candidates: [Candidate]) -> [CandidateSnapshot] {
        candidates.map {
            CandidateSnapshot(
                text: $0.text,
                valueBits: UInt32($0.value.bitPattern),
                words: $0.data.map(\.word),
                metadataBits: $0.data.map(\.metadata.rawValue)
            )
        }
    }

    // [Hazkey Community Patch]
    /// 修正前に固定した候補列と実際の候補列を比較する
    ///
    /// 表記と語列は生UTF-8バイト列で比較し、Swiftの文字列等値判定が吸収する正準等価を混同しない
    ///
    /// 評価値のビット列は PValue が Float32 の環境だけで比較し、Float16 の環境では表記と語列と順序だけを比較する
    ///
    /// - Parameters:
    ///   - actual: 実際の候補列
    ///   - expected: 修正前に固定した候補列
    ///   - message: 失敗時に付ける説明
    ///   - file: 失敗箇所のファイル
    ///   - line: 失敗箇所の行
    private func assertMatchesLockedSnapshots(
        _ actual: [CandidateSnapshot],
        _ expected: [CandidateSnapshot],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(pair.0.textUTF8, pair.1.textUTF8, "\(message) 候補\(index)の表記", file: file, line: line)
            XCTAssertEqual(pair.0.wordsUTF8, pair.1.wordsUTF8, "\(message) 候補\(index)の語列", file: file, line: line)
            XCTAssertEqual(pair.0.metadataBits, pair.1.metadataBits, "\(message) 候補\(index)のメタ情報", file: file, line: line)
            #if !(os(iOS) || os(tvOS))
            XCTAssertEqual(pair.0.valueBitPattern, pair.1.valueBitPattern, "\(message) 候補\(index)の評価値", file: file, line: line)
            #endif
        }
    }

    private func makeSharedPrevTotalLattice() -> Lattice {
        self.makeCustomLattice(
            nodesByPosition: [
                [
                    self.staticNode(word: "Ａ", ruby: "ア", start: 0, end: 1, value: -5),
                    self.staticNode(word: "Ａｶﾞ", ruby: "アイ", start: 0, end: 2, value: -1),
                    self.staticNode(word: "Ａ①", ruby: "アイ", start: 0, end: 2, value: -3),
                ],
                [
                    self.staticNode(word: "ガ", ruby: "イ", start: 1, end: 2, value: -5),
                    self.staticNode(word: "ｶﾞ", ruby: "イ", start: 1, end: 2, value: -4),
                ],
                [
                    self.staticNode(word: "ｶﾞ", ruby: "ウ", start: 2, end: 3, value: -2),
                ],
            ],
            surfaceCount: 3
        )
    }

    private func makeUserDictionaryExemptionLattice() -> Lattice {
        self.makeCustomLattice(
            nodesByPosition: [
                [
                    self.staticNode(word: "Ａｶﾞ", ruby: "アイ", start: 0, end: 2, value: -1, metadata: .isFromUserDictionary),
                    self.staticNode(word: "Ａｶﾞ", ruby: "アイ", start: 0, end: 2, value: -2, metadata: .isLearned),
                    self.staticNode(word: "Ａガ", ruby: "アイ", start: 0, end: 2, value: -3),
                ],
            ],
            surfaceCount: 2
        )
    }

    func testJinenNFKCRealisticSentenceSnapshot() {
        let (_, state, kanaKanji) = self.makePlainState()
        let reading = "きのうのかいぎではでんげんかいろ"
        let surface = "昨日の会議では電源回路"
        let fixedSurface = "昨日の会議では"
        let constraint = Kana2Kanji.PrefixConstraint(
            Array(surface.utf8),
            hasEOS: false,
            fixedPrefix: .init(byteCount: fixedSurface.utf8.count, rubyCount: fixedSurface.count),
            normalizesUnfixedConstraintForJinen: true
        )
        let expectedByNBest: [Int: [CandidateSnapshot]] = [
            1: [
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3260715840, words: ["昨日の", "会議で", "は", "電源回路"], metadataBits: [0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3263384742, words: ["昨日の", "会議で", "は", "電源", "回路"], metadataBits: [0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3265154777, words: ["昨日の", "会議で", "は", "電源", "回", "路"], metadataBits: [0, 0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3266696040, words: ["昨日の", "会議で", "は", "電源", "回", "路"], metadataBits: [0, 0, 0, 0, 0, 0]),
            ],
            3: [
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3260715840, words: ["昨日の", "会議で", "は", "電源回路"], metadataBits: [0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3260793252, words: ["昨日", "の", "会議で", "は", "電源回路"], metadataBits: [0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3262142428, words: ["昨日の", "会議", "で", "は", "電源回路"], metadataBits: [0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3263384742, words: ["昨日の", "会議で", "は", "電源", "回路"], metadataBits: [0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3263423447, words: ["昨日", "の", "会議で", "は", "電源", "回路"], metadataBits: [0, 0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3264098035, words: ["昨日の", "会議", "で", "は", "電源", "回路"], metadataBits: [0, 0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3265154777, words: ["昨日の", "会議で", "は", "電源", "回", "路"], metadataBits: [0, 0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3265193483, words: ["昨日", "の", "会議で", "は", "電源", "回", "路"], metadataBits: [0, 0, 0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3264498068, words: ["昨日の", "会議で", "は", "電源", "回", "路"], metadataBits: [0, 0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3266696040, words: ["昨日の", "会議で", "は", "電源", "回", "路"], metadataBits: [0, 0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3266734746, words: ["昨日", "の", "会議で", "は", "電源", "回", "路"], metadataBits: [0, 0, 0, 0, 0, 0, 0]),
                CandidateSnapshot(text: "昨日の会議では電源回路", valueBits: 3265785692, words: ["昨日の", "会議で", "は", "電源", "回", "路"], metadataBits: [0, 0, 0, 0, 0, 0]),
            ],
        ]

        for nBest in [1, 3] {
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: reading,
                constraint: constraint,
                nBest: nBest,
                state: state
            )
            self.assertMatchesLockedSnapshots(
                self.snapshots(candidates),
                expectedByNBest[nBest] ?? [],
                "N_best=\(nBest): 既定辞書の複数文節文で修正前の候補列を固定する"
            )
        }
    }

    func testJinenNFKCSharedNodeDifferentPrevTotalsSnapshot() {
        let (_, state, kanaKanji) = self.makePlainState()
        let lattice = self.makeSharedPrevTotalLattice()
        let constraint = Kana2Kanji.PrefixConstraint(
            Array("Ａ".utf8),
            hasEOS: false,
            fixedPrefix: .init(byteCount: 3, rubyCount: 1),
            normalizesUnfixedConstraintForJinen: true
        )

        let expectedByNBest: [Int: [CandidateSnapshot]] = [
            1: [
                CandidateSnapshot(text: "Ａｶﾞｶﾞ", valueBits: 3238633407, words: ["Ａｶﾞ", "ｶﾞ"], metadataBits: [0, 0]),
            ],
            3: [
                CandidateSnapshot(text: "Ａｶﾞｶﾞ", valueBits: 3238633407, words: ["Ａｶﾞ", "ｶﾞ"], metadataBits: [0, 0]),
                CandidateSnapshot(text: "Ａ①ｶﾞ", valueBits: 3240730559, words: ["Ａ①", "ｶﾞ"], metadataBits: [0, 0]),
                CandidateSnapshot(text: "Ａｶﾞｶﾞ", valueBits: 3248913908, words: ["Ａ", "ｶﾞ", "ｶﾞ"], metadataBits: [0, 0, 0]),
            ],
        ]

        for nBest in [1, 3] {
            lattice.resetNodeStates()
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: "あいう",
                constraint: constraint,
                nBest: nBest,
                preprocessedLattice: lattice,
                state: state
            )
            self.assertMatchesLockedSnapshots(
                self.snapshots(candidates),
                expectedByNBest[nBest] ?? [],
                "N_best=\(nBest): fixedPrefix内外と共有ノードの異なるprevTotalで修正前の候補列を固定する"
            )
        }
    }

    func testJinenNFKCSameNodeStraddlingFixedPrefixAtTwoDifferentPrevTotals() {
        let (_, state, kanaKanji) = self.makePlainState()
        let sharedWord = "A①ｶﾞ"
        let lattice = self.makeCustomLattice(
            nodesByPosition: [
                [
                    self.staticNode(word: "ｶ", ruby: "ア", start: 0, end: 1, value: -5),
                    self.staticNode(word: "ｶﾞ", ruby: "ア", start: 0, end: 1, value: -4),
                ],
                [self.staticNode(word: sharedWord, ruby: "イ", start: 1, end: 2, value: -5)],
            ],
            surfaceCount: 2
        )
        let constraint = Kana2Kanji.PrefixConstraint(
            Array("ｶﾞA①ｶﾞ".utf8),
            hasEOS: true,
            fixedPrefix: .init(byteCount: 7, rubyCount: 1),
            normalizesUnfixedConstraintForJinen: true
        )

        // 同じノードでも直前の累積バイト数が違えば切り取り位置が変わる
        XCTAssertEqual(
            Kana2Kanji.normalizedComparisonSegment(prevTotal: 3, word: sharedWord, fixedByteCount: 7),
            Array("A①".utf8) + Array("ｶﾞ".precomposedStringWithCompatibilityMapping.utf8)
        )
        XCTAssertEqual(
            Kana2Kanji.normalizedComparisonSegment(prevTotal: 6, word: sharedWord, fixedByteCount: 7),
            Array("A".utf8) + Array("①ｶﾞ".precomposedStringWithCompatibilityMapping.utf8)
        )
        XCTAssertNotEqual(
            Kana2Kanji.normalizedComparisonSegment(prevTotal: 3, word: sharedWord, fixedByteCount: 7),
            Kana2Kanji.normalizedComparisonSegment(prevTotal: 6, word: sharedWord, fixedByteCount: 7)
        )

        let expected = [
            CandidateSnapshot(text: "ｶﾞA①ｶﾞ", valueBits: 3244924863, words: ["ｶﾞ", "A①ｶﾞ"], metadataBits: [0, 0]),
        ]

        for nBest in [1, 3] {
            lattice.resetNodeStates()
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: "あい",
                constraint: constraint,
                nBest: nBest,
                preprocessedLattice: lattice,
                state: state
            )
            self.assertMatchesLockedSnapshots(
                self.snapshots(candidates),
                expected,
                "N_best=\(nBest): 同じノードでも異なるprevTotalの切り取り位置を混同しない"
            )
        }
    }

    func testJinenNFKCCombiningKanaAcrossFixedPrefix() {
        let (_, state, kanaKanji) = self.makePlainState()
        let lattice = self.makeCustomLattice(
            nodesByPosition: [
                [self.staticNode(word: "ｶﾞ", ruby: "ガ", start: 0, end: 1)],
            ],
            surfaceCount: 1
        )
        let wholeNFKC = "ｶﾞ".precomposedStringWithCompatibilityMapping
        let wholeConstraint = Kana2Kanji.PrefixConstraint(
            Array("ｶﾞ".utf8),
            hasEOS: true,
            normalizesUnfixedConstraintForJinen: true
        )
        let splitConstraint = Kana2Kanji.PrefixConstraint(
            Array("ｶﾞ".utf8),
            hasEOS: true,
            fixedPrefix: .init(byteCount: 3, rubyCount: 1),
            normalizesUnfixedConstraintForJinen: true
        )
        let rawWholeConstraint = Kana2Kanji.PrefixConstraint(
            Array("ｶﾞ".utf8),
            hasEOS: true,
            fixedPrefix: .init(byteCount: 6, rubyCount: 1),
            normalizesUnfixedConstraintForJinen: true
        )

        // 境界がｶとﾞの間にある場合は文字クラスタの内側のため生バイトへフォールバックする
        XCTAssertEqual(
            Kana2Kanji.normalizedComparisonSegment(prevTotal: 0, word: "ｶﾞ", fixedByteCount: 3),
            Array("ｶﾞ".utf8)
        )
        XCTAssertNotEqual(
            Kana2Kanji.normalizedComparisonSegment(prevTotal: 0, word: "ｶﾞ", fixedByteCount: 3),
            Array(wholeNFKC.utf8)
        )
        XCTAssertNotEqual(
            Kana2Kanji.normalizedComparisonSegment(prevTotal: 0, word: "ｶﾞ", fixedByteCount: 3),
            Array("ガ".utf8)
        )

        // 境界の外にある場合は単一適用のNFKC結果になる
        XCTAssertEqual(
            Kana2Kanji.normalizedComparisonSegment(prevTotal: 0, word: "ｶﾞ", fixedByteCount: 0),
            Array(wholeNFKC.utf8)
        )

        // 境界が文字クラスタの間にある場合は後半だけがNFKCで変換される
        let boundaryWord = "Ａｷﾞ"
        let boundaryPrefix = Array("Ａ".utf8)
        let boundaryRemainderNFKC = Array("ｷﾞ".precomposedStringWithCompatibilityMapping.utf8)
        let boundaryExpected = boundaryPrefix + boundaryRemainderNFKC
        let boundarySegment = Kana2Kanji.normalizedComparisonSegment(prevTotal: 0, word: boundaryWord, fixedByteCount: 3)
        XCTAssertEqual(boundarySegment, boundaryExpected)
        XCTAssertEqual(
            Array(boundarySegment.prefix(boundaryPrefix.count)),
            boundaryPrefix,
            "fixedByteCountの内側は生UTF-8のまま保持する"
        )
        XCTAssertEqual(
            Array(boundarySegment.dropFirst(boundaryPrefix.count)),
            boundaryRemainderNFKC,
            "fixedByteCountより後ろだけを現在のプラットフォームのNFKCで正規化する"
        )
        let wholeBoundaryNFKC = Array(boundaryWord.precomposedStringWithCompatibilityMapping.utf8)
        if wholeBoundaryNFKC != boundaryExpected {
            XCTAssertNotEqual(
                boundarySegment,
                wholeBoundaryNFKC,
                "fixedByteCountをまたいだ文字の合成は行わない"
            )
        }
        let boundaryLattice = self.makeCustomLattice(
            nodesByPosition: [
                [self.staticNode(word: boundaryWord, ruby: "アイ", start: 0, end: 1)],
            ],
            surfaceCount: 1
        )
        let boundaryConstraint = Kana2Kanji.PrefixConstraint(
            Array(boundaryWord.utf8),
            hasEOS: true,
            fixedPrefix: .init(byteCount: 3, rubyCount: 1),
            normalizesUnfixedConstraintForJinen: true
        )

        for nBest in [1, 3] {
            lattice.resetNodeStates()
            XCTAssertEqual(
                self.constrainedCandidates(kanaKanji, reading: "あ", constraint: wholeConstraint, nBest: nBest, preprocessedLattice: lattice, state: state).map(\.text),
                ["ｶﾞ"],
                "N_best=\(nBest): fixedPrefixの外ではｶとﾞがNFKCで変換される"
            )
            lattice.resetNodeStates()
            XCTAssertEqual(
                self.constrainedCandidates(kanaKanji, reading: "あ", constraint: splitConstraint, nBest: nBest, preprocessedLattice: lattice, state: state).map(\.text),
                [],
                "N_best=\(nBest): 文字クラスタの内側で切れる境界は生バイトのままなのでNFKCの濁点には一致しない"
            )
            lattice.resetNodeStates()
            XCTAssertEqual(
                self.constrainedCandidates(kanaKanji, reading: "あ", constraint: rawWholeConstraint, nBest: nBest, preprocessedLattice: lattice, state: state).map(\.text),
                ["ｶﾞ"],
                "N_best=\(nBest): ノード全体がfixedPrefixの中なら生UTF-8のまま一致する"
            )
            boundaryLattice.resetNodeStates()
            XCTAssertEqual(
                self.constrainedCandidates(kanaKanji, reading: "あ", constraint: boundaryConstraint, nBest: nBest, preprocessedLattice: boundaryLattice, state: state).map(\.text),
                [boundaryWord],
                "N_best=\(nBest): 文字クラスタの間で切れる境界は前半が生UTF-8、後半がNFKCになる"
            )
        }
    }

    func testJinenNFKCNonInvariantWordsAfterFixedPrefix() {
        let (_, state, kanaKanji) = self.makePlainState()
        let cases: [(raw: String, normalized: String)] = [
            ("ゟ", "より"),
            ("ヿ", "コト"),
            ("神", "神"),
        ]
        for (raw, normalized) in cases {
            let lattice = self.makeCustomLattice(
                nodesByPosition: [
                    [self.staticNode(word: raw, ruby: "ア", start: 0, end: 1)],
                ],
                surfaceCount: 1
            )
            let constraint = Kana2Kanji.PrefixConstraint(
                Array(normalized.utf8),
                hasEOS: true,
                normalizesUnfixedConstraintForJinen: true
            )
            for nBest in [1, 3] {
                lattice.resetNodeStates()
                XCTAssertEqual(
                    self.constrainedCandidates(kanaKanji, reading: "あ", constraint: constraint, nBest: nBest, preprocessedLattice: lattice, state: state).map(\.text),
                    [raw],
                    "N_best=\(nBest): fixedPrefixの外では \(raw) がNFKCで \(normalized) に一致する"
                )
            }

            // fixedPrefixの後ろに置いた場合も同じ結果になる
            let prefixedLattice = self.makeCustomLattice(
                nodesByPosition: [
                    [self.staticNode(word: "Ａ", ruby: "ア", start: 0, end: 1)],
                    [self.staticNode(word: raw, ruby: "イ", start: 1, end: 2)],
                ],
                surfaceCount: 2
            )
            let prefixedConstraint = Kana2Kanji.PrefixConstraint(
                Array("Ａ".utf8) + Array(normalized.utf8),
                hasEOS: true,
                fixedPrefix: .init(byteCount: 3, rubyCount: 1),
                normalizesUnfixedConstraintForJinen: true
            )
            for nBest in [1, 3] {
                prefixedLattice.resetNodeStates()
                XCTAssertEqual(
                    self.constrainedCandidates(kanaKanji, reading: "あい", constraint: prefixedConstraint, nBest: nBest, preprocessedLattice: prefixedLattice, state: state).map(\.text),
                    ["Ａ" + raw],
                    "N_best=\(nBest): fixedPrefixの直後でも \(raw) がNFKCで \(normalized) に一致する"
                )
            }
        }
    }

    func testJinenNFKCNonInvariantWordsInsideFixedPrefixStayRaw() {
        let (_, state, kanaKanji) = self.makePlainState()
        let cases: [(raw: String, normalized: String)] = [
            ("ゟ", "より"),
            ("ヿ", "コト"),
            ("神", "神"),
        ]
        for (raw, normalized) in cases {
            let lattice = self.makeCustomLattice(
                nodesByPosition: [
                    [self.staticNode(word: raw, ruby: "ア", start: 0, end: 1)],
                ],
                surfaceCount: 1
            )
            let constraint = Kana2Kanji.PrefixConstraint(
                Array(normalized.utf8),
                hasEOS: true,
                fixedPrefix: .init(byteCount: raw.utf8.count, rubyCount: 1),
                normalizesUnfixedConstraintForJinen: true
            )
            for nBest in [1, 3] {
                lattice.resetNodeStates()
                XCTAssertEqual(
                    self.constrainedCandidates(kanaKanji, reading: "あ", constraint: constraint, nBest: nBest, preprocessedLattice: lattice, state: state).map(\.text),
                    [],
                    "N_best=\(nBest): fixedPrefixの中では \(raw) を生UTF-8のまま比較する"
                )
            }
        }
    }

    func testZenzRawConstraintRejectsNonInvariantWords() {
        let (_, state, kanaKanji) = self.makePlainState()
        let cases: [(raw: String, normalized: String)] = [
            ("ゟ", "より"),
            ("ヿ", "コト"),
            ("神", "神"),
        ]
        for (raw, normalized) in cases {
            let lattice = self.makeCustomLattice(
                nodesByPosition: [
                    [self.staticNode(word: raw, ruby: "ア", start: 0, end: 1)],
                ],
                surfaceCount: 1
            )
            let constraint = Kana2Kanji.PrefixConstraint(
                Array(normalized.utf8),
                hasEOS: true,
                normalizesUnfixedConstraintForJinen: false
            )
            for nBest in [1, 3] {
                lattice.resetNodeStates()
                XCTAssertEqual(
                    self.constrainedCandidates(kanaKanji, reading: "あ", constraint: constraint, nBest: nBest, preprocessedLattice: lattice, state: state).map(\.text),
                    [],
                    "N_best=\(nBest): Zenzは \(raw) をNFKCせず生UTF-8で比較する"
                )
            }
        }
    }

    func testJinenNFKCUserDictionaryAndLearnedExemptionSnapshot() {
        let (_, state, kanaKanji) = self.makePlainState()
        let lattice = self.makeUserDictionaryExemptionLattice()
        let exemptExpected = [
            CandidateSnapshot(text: "Ａｶﾞ", valueBits: 3222867542, words: ["Ａｶﾞ"], metadataBits: [2]),
            CandidateSnapshot(text: "Ａｶﾞ", valueBits: 3227061846, words: ["Ａｶﾞ"], metadataBits: [1]),
        ]
        let constrainedExpected = [
            CandidateSnapshot(text: "Ａｶﾞ", valueBits: 3222867542, words: ["Ａｶﾞ"], metadataBits: [2]),
        ]

        for normalizesForJinen in [true, false] {
            for ignoreMemoryAndUserDictionary in [false, true] {
                let constraint = Kana2Kanji.PrefixConstraint(
                    Array("ＡX".utf8),
                    hasEOS: true,
                    ignoreMemoryAndUserDictionary: ignoreMemoryAndUserDictionary,
                    fixedPrefix: .init(byteCount: 3, rubyCount: 1),
                    normalizesUnfixedConstraintForJinen: normalizesForJinen
                )
                let expected = ignoreMemoryAndUserDictionary ? constrainedExpected : exemptExpected
                for nBest in [1, 3] {
                    lattice.resetNodeStates()
                    let candidates = self.constrainedCandidates(
                        kanaKanji,
                        reading: "あい",
                        constraint: constraint,
                        nBest: nBest,
                        preprocessedLattice: lattice,
                        state: state
                    )
                    let label = "ud-exempt-jinen-\(normalizesForJinen)-ignore-\(ignoreMemoryAndUserDictionary)-n\(nBest)"
                    self.assertMatchesLockedSnapshots(
                        self.snapshots(candidates),
                        expected,
                        "\(label): ユーザ辞書と学習語の制約免除を修正前の候補列で固定する"
                    )
                }
            }
        }
    }

    func testJinenNFKCRepeatedInvocationHasNoStateLeakage() {
        let (_, state, kanaKanji) = self.makePlainState()
        let lattice = self.makeSharedPrevTotalLattice()
        let jinenConstraint = Kana2Kanji.PrefixConstraint(
            Array("Ａ".utf8),
            hasEOS: false,
            fixedPrefix: .init(byteCount: 3, rubyCount: 1),
            normalizesUnfixedConstraintForJinen: true
        )
        let zenzConstraint = Kana2Kanji.PrefixConstraint(
            Array("Ａｶﾞ".utf8),
            hasEOS: false,
            normalizesUnfixedConstraintForJinen: false
        )

        lattice.resetNodeStates()
        let firstCandidates = self.constrainedCandidates(kanaKanji, reading: "あいう", constraint: jinenConstraint, nBest: 3, preprocessedLattice: lattice, state: state)
        let first = self.snapshots(firstCandidates)
        lattice.resetNodeStates()
        let second = self.snapshots(
            self.constrainedCandidates(kanaKanji, reading: "あいう", constraint: jinenConstraint, nBest: 3, preprocessedLattice: lattice, state: state)
        )
        lattice.resetNodeStates()
        let zenzCandidates = self.constrainedCandidates(kanaKanji, reading: "あいう", constraint: zenzConstraint, nBest: 3, preprocessedLattice: lattice, state: state)
        let zenz = self.snapshots(zenzCandidates)
        lattice.resetNodeStates()
        let third = self.snapshots(
            self.constrainedCandidates(kanaKanji, reading: "あいう", constraint: jinenConstraint, nBest: 3, preprocessedLattice: lattice, state: state)
        )

        let expectedJinen = [
            CandidateSnapshot(text: "Ａｶﾞｶﾞ", valueBits: 3238633407, words: ["Ａｶﾞ", "ｶﾞ"], metadataBits: [0, 0]),
            CandidateSnapshot(text: "Ａ①ｶﾞ", valueBits: 3240730559, words: ["Ａ①", "ｶﾞ"], metadataBits: [0, 0]),
            CandidateSnapshot(text: "Ａｶﾞｶﾞ", valueBits: 3248913908, words: ["Ａ", "ｶﾞ", "ｶﾞ"], metadataBits: [0, 0, 0]),
        ]
        let expectedZenz = [
            CandidateSnapshot(text: "Ａｶﾞｶﾞ", valueBits: 3238633407, words: ["Ａｶﾞ", "ｶﾞ"], metadataBits: [0, 0]),
            CandidateSnapshot(text: "Ａｶﾞｶﾞ", valueBits: 3248913908, words: ["Ａ", "ｶﾞ", "ｶﾞ"], metadataBits: [0, 0, 0]),
        ]

        self.assertMatchesLockedSnapshots(first, expectedJinen, "1回目のJinenの結果を固定する")
        self.assertMatchesLockedSnapshots(second, expectedJinen, "同じラティスと同じ制約の2回目は1回目と一致する")
        self.assertMatchesLockedSnapshots(third, expectedJinen, "Jinenの後にZenzを挟んでもJinenの結果は変わらない")
        self.assertMatchesLockedSnapshots(zenz, expectedZenz, "Zenzの生UTF-8制約の結果を固定する")
    }

    // [Hazkey Community Patch]
    /// 一致済みの制約の後ろへNFKCで長さの変わる表記を置いた場合を固定する
    ///
    /// 一致数が制約長へ達した後の照合打ち切りが、終端一致を持たない制約の候補を変えないことを確かめる
    ///
    /// 打ち切りは累積長へ生バイト長を加えるため、NFKC後の長さが異なる表記でも
    /// 一致数を増やさない限り候補の成否は同じになる
    func testJinenNFKCAlreadyMatchedFollowedByNonInvariantWord() {
        let (_, state, kanaKanji) = self.makePlainState()
        let constraint = Kana2Kanji.PrefixConstraint(
            Array("A".utf8),
            hasEOS: false,
            normalizesUnfixedConstraintForJinen: true
        )
        for suffix in ["ゟ", "ヿ", "神", "ｶﾞ"] {
            let lattice = self.makeCustomLattice(
                nodesByPosition: [
                    [self.staticNode(word: "A", ruby: "ア", start: 0, end: 1)],
                    [self.staticNode(word: suffix, ruby: "イ", start: 1, end: 2)],
                ],
                surfaceCount: 2
            )
            for nBest in [1, 3] {
                lattice.resetNodeStates()
                XCTAssertEqual(
                    self.constrainedCandidates(
                        kanaKanji,
                        reading: "あい",
                        constraint: constraint,
                        nBest: nBest,
                        preprocessedLattice: lattice,
                        state: state
                    ).map(\.text),
                    ["A" + suffix],
                    "N_best=\(nBest): 一致済み制約 A の後ろの \(suffix) は打ち切り後も候補に残る"
                )
            }
        }
    }

    // [Hazkey Community Patch]
    /// 一致済みの制約に終端一致を求めた場合の末尾表記の境界を固定する
    ///
    /// 一致数と累積長が制約長に等しい状態では、空表記の末尾だけが終端一致を満たす
    ///
    /// 照合打ち切りが累積長へ加える生バイト長でも、空表記と非空表記の区別は変わらない
    func testJinenNFKCAlreadyMatchedHasEOSDistinguishesEmptyTail() {
        let (_, state, kanaKanji) = self.makePlainState()
        let constraint = Kana2Kanji.PrefixConstraint(
            Array("A".utf8),
            hasEOS: true,
            normalizesUnfixedConstraintForJinen: true
        )
        let emptyTailLattice = self.makeCustomLattice(
            nodesByPosition: [
                [self.staticNode(word: "A", ruby: "ア", start: 0, end: 1)],
                [self.staticNode(word: "", ruby: "", start: 1, end: 2)],
            ],
            surfaceCount: 2
        )
        let nonEmptyTailLattice = self.makeCustomLattice(
            nodesByPosition: [
                [self.staticNode(word: "A", ruby: "ア", start: 0, end: 1)],
                [self.staticNode(word: "①", ruby: "イ", start: 1, end: 2)],
            ],
            surfaceCount: 2
        )
        for nBest in [1, 3] {
            emptyTailLattice.resetNodeStates()
            XCTAssertEqual(
                self.constrainedCandidates(
                    kanaKanji,
                    reading: "あい",
                    constraint: constraint,
                    nBest: nBest,
                    preprocessedLattice: emptyTailLattice,
                    state: state
                ).map(\.text),
                ["A"],
                "N_best=\(nBest): 空表記の末尾は累積長を変えず終端一致を満たす"
            )
            nonEmptyTailLattice.resetNodeStates()
            XCTAssertEqual(
                self.constrainedCandidates(
                    kanaKanji,
                    reading: "あい",
                    constraint: constraint,
                    nBest: nBest,
                    preprocessedLattice: nonEmptyTailLattice,
                    state: state
                ).map(\.text),
                [],
                "N_best=\(nBest): 非空表記の末尾は累積長を増やし終端一致を満たさない"
            )
        }
    }

    // [Hazkey Community Patch]
    /// 正準等価だがFoundationのNFKC出力が異なる表記を混同しないことを確かめる
    ///
    /// Swiftの文字列等値判定では同じ文字列になる2表記でも、生UTF-8バイト列が異なりNFKCの結果も異なる場合がある
    ///
    /// 表記のキャッシュを文字列で共有すると、異なるバイト列の候補が同じ比較セグメントへ統合されてしまう
    ///
    /// 期待する残存候補は現在のプラットフォームの normalizedComparisonSegment から求め、挿入順とN_bestの全組み合わせで一致を確かめる
    func testJinenNFKCCanonicallyEqualStringsWithDistinctFoundationNFKCDoNotCollide() {
        let (_, state, kanaKanji) = self.makePlainState()
        let composed = "\u{0CCB}"
        let decomposed = "\u{0CCA}\u{0CD5}"
        XCTAssertEqual(composed, decomposed, "この2表記はSwiftの文字列等値判定では一致する")
        func normalized(_ word: String) -> [UInt8] {
            Kana2Kanji.normalizedComparisonSegment(prevTotal: 0, word: word, fixedByteCount: 0)
        }
        let normalizedComposed = normalized(composed)
        let normalizedDecomposed = normalized(decomposed)
        let normalizationsDiffer = normalizedComposed != normalizedDecomposed
        #if os(Linux)
        XCTAssertTrue(normalizationsDiffer, "LinuxのFoundationは正準等価な2表記を異なるNFKCバイト列へ写す")
        #endif
        let constraint = Kana2Kanji.PrefixConstraint(
            normalizedComposed,
            hasEOS: true,
            normalizesUnfixedConstraintForJinen: true
        )
        var resultsByOrder: [[[UInt8]]] = []
        for insertion in [[composed, decomposed], [decomposed, composed]] {
            let lattice = self.makeCustomLattice(
                nodesByPosition: [
                    insertion.map { self.staticNode(word: $0, ruby: "ア", start: 0, end: 1) },
                ],
                surfaceCount: 1
            )
            let expected = insertion
                .filter { normalized($0) == normalizedComposed }
                .map { Array($0.utf8) }
                .sorted { $0.lexicographicallyPrecedes($1) }
            for nBest in [1, 3] {
                lattice.resetNodeStates()
                let actual = self.constrainedCandidates(
                    kanaKanji,
                    reading: "あ",
                    constraint: constraint,
                    nBest: nBest,
                    preprocessedLattice: lattice,
                    state: state
                )
                    .map { Array($0.text.utf8) }
                    .sorted { $0.lexicographicallyPrecedes($1) }
                XCTAssertEqual(
                    actual,
                    expected,
                    "N_best=\(nBest): 挿入順 \(insertion.map { Array($0.utf8) }) でNFKCが一致する表記だけが残る"
                )
                resultsByOrder.append(actual)
            }
        }
        if normalizationsDiffer {
            XCTAssertEqual(
                resultsByOrder,
                Array(repeating: [Array(composed.utf8)], count: resultsByOrder.count),
                "NFKCが異なる環境では両方の挿入順とN_bestで composed だけが残り順序依存がない"
            )
        }
    }

    // [Hazkey Community Patch]
    /// セグメント表の容量拡張をまたいでも全ノードの範囲を引き当てられることを確かめる
    ///
    /// 最初の容量を超える件数を登録して再配置を起こし、格納範囲と比較用バイト列が
    /// 毎回の正規化結果と一致することを確認する
    func testJinenComparisonSegmentCacheKeepsEntriesAcrossGrowth() {
        var cache = Kana2Kanji.JinenComparisonSegmentCache()
        let count = 2500
        var nodes: [LatticeNode] = []
        var words: [String] = []
        nodes.reserveCapacity(count)
        words.reserveCapacity(count)
        for index in 0 ..< count {
            let word = "語\(index)ｶﾞ"
            words.append(word)
            nodes.append(self.staticNode(word: word, ruby: "ゴ", start: 0, end: 1))
        }
        var firstRanges: [Range<Int>] = []
        firstRanges.reserveCapacity(count)
        for (index, node) in nodes.enumerated() {
            guard let range = cache.segmentRange(for: node, prevTotal: 0, fixedByteCount: 0) else {
                return XCTFail("\(index) 件目: 全体セグメントの範囲が返らない")
            }
            firstRanges.append(range)
            XCTAssertEqual(
                Array(cache.bytes(in: range)),
                Kana2Kanji.normalizedComparisonSegment(prevTotal: 0, word: words[index], fixedByteCount: 0),
                "\(index) 件目: 登録したセグメントが正規化結果と一致する"
            )
        }
        for (index, node) in nodes.enumerated() {
            XCTAssertTrue(
                cache.containsFullRangeNode(node),
                "\(index) 件目: 再配置後も全体セグメントの表がノードを保持する"
            )
            guard let range = cache.segmentRange(for: node, prevTotal: 0, fixedByteCount: 0) else {
                return XCTFail("\(index) 件目: 再配置後に範囲が返らない")
            }
            XCTAssertEqual(range, firstRanges[index], "\(index) 件目: 再配置後も格納範囲が変わらない")
            XCTAssertEqual(
                Array(cache.bytes(in: range)),
                Kana2Kanji.normalizedComparisonSegment(prevTotal: 0, word: words[index], fixedByteCount: 0),
                "\(index) 件目: 再配置後もセグメントが正規化結果と一致する"
            )
        }
    }
}
