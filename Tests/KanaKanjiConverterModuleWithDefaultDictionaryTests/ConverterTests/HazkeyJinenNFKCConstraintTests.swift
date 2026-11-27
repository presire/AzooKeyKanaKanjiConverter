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

    private func staticNode(word: String, ruby: String, start: Int, end: Int, value: PValue = -5) -> LatticeNode {
        LatticeNode(
            data: DicdataElement(
                word: word,
                ruby: ruby,
                cid: CIDData.一般名詞.cid,
                mid: MIDData.一般.mid,
                value: value,
                metadata: .empty
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
}
