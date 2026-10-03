import Foundation
import SwiftUtils

package final class DicdataStoreState {
    /// 辞書の置き場と補助辞書の一覧を持った状態を作る
    ///
    /// - Parameters:
    ///   - dictionaryURL: システム辞書の置き場
    ///   - supplementalSourceIDs: DicdataStoreへ登録した補助辞書のID (宣言順)
    /// 辞書の置き場と補助辞書の一覧を持った状態を作る
    ///
    /// - Parameters:
    ///   - dictionaryURL: システム辞書の置き場
    ///   - supplementalSourceIDs: DicdataStoreへ登録した補助辞書のID (宣言順)
    init(dictionaryURL: URL, supplementalSourceIDs: [String] = []) {
        self.learningMemoryManager = LearningManager(dictionaryURL: dictionaryURL)
        self.supplementalSourceIDs = supplementalSourceIDs
    }

    var keyboardLanguage: KeyboardLanguage = .ja_JP
    private(set) var dynamicUserDictionary: [DicdataElement] = []
    private(set) var dynamicUserShortcuts: [DicdataElement] = []
    var learningMemoryManager: LearningManager

    var userDictionaryURL: URL?
    var memoryURL: URL? {
        self.learningMemoryManager.config.memoryURL
    }

    private(set) var userDictionaryHasLoaded: Bool = false
    private(set) var userDictionaryLOUDS: LOUDS?

    // user_shortcuts 辞書
    private(set) var userShortcutsHasLoaded: Bool = false
    private(set) var userShortcutsLOUDS: LOUDS?

    private(set) var memoryHasLoaded: Bool = false
    private(set) var memoryLOUDS: LOUDS?
    /// DicdataStoreへ登録した補助辞書のIDを宣言順に持つ
    ///
    /// 実行時の有効無効はこの一覧を変えずにID別のフラグで切り替える
    private let supplementalSourceIDs: [String]
    /// 補助辞書ごとの有効フラグをID別に持つ
    ///
    /// 未設定のIDは有効として扱う
    private var supplementalDictionaryEnabledByID: [String: Bool] = [:]
    private var staticConversionCacheEligibility: Bool?

    /// 先頭の補助辞書のIDを返す
    ///
    /// 旧来の単一辞書用の互換窓口が操作対象を見つけるために使う
    ///
    /// - Returns: 先頭ソースのID、未登録の場合はnil
    var firstSupplementalSourceID: String? {
        self.supplementalSourceIDs.first
    }

    /// 指定した補助辞書が実行時に有効かを返す
    ///
    /// 検証を通過したかとは独立した判定で、未設定のIDは有効として扱う
    ///
    /// - Parameter id: 補助辞書のID
    /// - Returns: 有効な場合はtrue
    func isSupplementalDictionaryEnabled(_ id: String) -> Bool {
        self.supplementalDictionaryEnabledByID[id] ?? true
    }

    /// 登録済みのIDに限り有効フラグを更新する
    ///
    /// 未知のIDでは何も変えずにfalseを返すため、誤ったIDで新しい設定が生まれることはない
    ///
    /// - Parameters:
    ///   - enabled: 有効にする場合はtrue
    ///   - id: 補助辞書のID
    /// - Returns: 更新した場合はtrue、未知のIDの場合はfalse
    @discardableResult
    func updateSupplementalDictionaryEnabled(_ enabled: Bool, for id: String) -> Bool {
        guard self.supplementalSourceIDs.contains(id) else {
            return false
        }
        self.supplementalDictionaryEnabledByID[id] = enabled
        return true
    }

    /// 先頭の補助辞書の有効フラグを更新する互換窓口
    ///
    /// 旧来の単一辞書用の呼び出しを先頭ソースへの操作として受け付ける
    ///
    /// - Parameter enabled: 有効にする場合はtrue
    func updateSupplementalDictionaryEnabled(_ enabled: Bool) {
        guard let firstID = self.supplementalSourceIDs.first else {
            return
        }
        self.updateSupplementalDictionaryEnabled(enabled, for: firstID)
    }

    func updateUserDictionaryURL(_ newURL: URL, forceReload: Bool) {
        if self.userDictionaryURL != newURL || forceReload {
            self.userDictionaryURL = newURL
            self.staticConversionCacheEligibility = nil
            self.userDictionaryLOUDS = nil
            self.userDictionaryHasLoaded = false
            self.userShortcutsLOUDS = nil
            self.userShortcutsHasLoaded = false
        }
    }

    func updateKeyboardLanguage(_ newLanguage: KeyboardLanguage) {
        self.keyboardLanguage = newLanguage
    }

    func updateLearningConfig(_ newConfig: LearningConfig) {
        if self.learningMemoryManager.config != newConfig {
            self.staticConversionCacheEligibility = nil
            let updated = self.learningMemoryManager.updateConfig(newConfig)
            if updated {
                self.resetMemoryLOUDSCache()
            }
        }
    }

    func updateMemoryLOUDS(_ newLOUDS: LOUDS?) {
        self.memoryLOUDS = newLOUDS
        self.memoryHasLoaded = true
    }

    /// 永続学習メモリのLOUDSを読み込んで共有のキャッシュに置く
    ///
    /// 変換経路のmemory問い合わせと永続エントリのポイント照会が同じキャッシュと
    ///
    /// 同じ無効化を使うための単一の入口
    ///
    /// - Returns: 読み込めた場合はLOUDS、存在しない場合はnil
    func loadMemoryLOUDSIfNeeded() -> LOUDS? {
        if self.memoryHasLoaded {
            return self.memoryLOUDS
        }
        if let memoryURL = self.memoryURL, let louds = LOUDS.loadMemory(memoryURL: memoryURL) {
            self.updateMemoryLOUDS(louds)
            return louds
        }
        self.updateMemoryLOUDS(nil)
        return nil
    }

    func updateUserDictionaryLOUDS(_ newLOUDS: LOUDS?) {
        self.userDictionaryLOUDS = newLOUDS
        self.userDictionaryHasLoaded = true
    }

    func updateUserShortcutsLOUDS(_ newLOUDS: LOUDS?) {
        self.userShortcutsLOUDS = newLOUDS
        self.userShortcutsHasLoaded = true
    }

    @available(*, deprecated, message: "This API is deprecated. Directly update the state instead.")
    func updateIfRequired(options: ConvertRequestOptions) {
        if options.keyboardLanguage != self.keyboardLanguage {
            self.keyboardLanguage = options.keyboardLanguage
        }
        self.updateUserDictionaryURL(options.sharedContainerURL, forceReload: false)
        let learningConfig = LearningConfig(learningType: options.learningType, maxMemoryCount: options.maxMemoryCount, memoryURL: options.memoryDirectoryURL)
        self.updateLearningConfig(learningConfig)
    }

    func importDynamicUserDictionary(_ dicdata: [DicdataElement], shortcuts: [DicdataElement] = []) {
        self.staticConversionCacheEligibility = nil
        self.dynamicUserDictionary = dicdata
        self.dynamicUserDictionary.mutatingForEach {
            $0.metadata = .isFromUserDictionary
        }
        self.dynamicUserShortcuts = shortcuts
        self.dynamicUserShortcuts.mutatingForEach {
            $0.metadata = .isFromUserDictionary
        }
    }

    /// 辞書状態を跨いで変換結果を共有しても安全かを返す。
    ///
    /// 学習・動的辞書・永続ユーザ辞書のいずれかが有効な場合は、同じ入力でも
    /// 候補列が変わり得るため共有しない。
    func canShareStaticConversionResults() -> Bool {
        if let staticConversionCacheEligibility {
            return staticConversionCacheEligibility
        }
        guard self.learningMemoryManager.config.learningType == .nothing,
              self.dynamicUserDictionary.isEmpty,
              self.dynamicUserShortcuts.isEmpty else {
            self.staticConversionCacheEligibility = false
            return false
        }
        guard let userDictionaryURL else {
            self.staticConversionCacheEligibility = true
            return true
        }
        let userDictionaryFiles = [
            "user.loudschars2",
            "user.louds",
            "user_shortcuts.loudschars2",
            "user_shortcuts.louds"
        ]
        let hasUserDictionaryFile = userDictionaryFiles.contains {
            FileManager.default.fileExists(
                atPath: userDictionaryURL.appendingPathComponent($0).path
            )
        }
        self.staticConversionCacheEligibility = !hasUserDictionaryFile
        return !hasUserDictionaryFile
    }

    private func resetMemoryLOUDSCache() {
        self.memoryLOUDS = nil
        self.memoryHasLoaded = false
    }

    /// 未保存の学習データを永続化し、保存が起きた場合だけmemoryのLOUDSキャッシュを捨てる
    ///
    /// - Throws: 学習データの保存に失敗した場合は書き込み時のエラー
    func saveMemory() throws {
        if try self.learningMemoryManager.save() {
            self.resetMemoryLOUDSCache()
        }
    }

    func resetMemory() {
        self.learningMemoryManager.resetMemory()
        self.resetMemoryLOUDSCache()
    }

    func forgetMemory(_ candidate: Candidate) {
        self.learningMemoryManager.forgetMemory(data: candidate.data)
        self.resetMemoryLOUDSCache()
    }

    /// 読みと表記と品詞IDが一致する学習エントリだけを正確に削除する
    ///
    /// 表記だけが一致する別品詞の語は残る
    ///
    /// - Parameter target: 削除対象の読みと表記と品詞ID
    /// - Throws: 学習データの保存に失敗した場合は書き込み時のエラー
    func forgetLearningMemory(exactly target: LearningMemoryKey) throws {
        try self.learningMemoryManager.forgetLearningMemory(exactly: target)
        self.resetMemoryLOUDSCache()
    }

    /// 永続化済み学習メモリを指定範囲だけ列挙する
    ///
    /// 末尾まで走査して件数の整合性を確認するため、呼び出し回数が増えると全体で計算量が二乗で増える
    ///
    /// - Parameters:
    ///   - offset: 先頭から数えた開始位置
    ///   - limit: 取得する上限件数
    /// - Returns: 指定範囲のエントリと総件数と次の開始位置
    /// - Throws: メタデータやシャードが壊れている場合は列挙時のエラー
    func learningMemoryEntries(offset: Int, limit: Int) throws -> LearningMemoryPage {
        try self.learningMemoryManager.learningMemoryEntries(offset: offset, limit: limit)
    }

    /// 永続化済み学習メモリを先頭から上限まで1回の走査で取得する
    ///
    /// 学習履歴の選択削除ダイアログが全件取得に使う入口で、上限に達した時点で走査を打ち切る
    ///
    /// - Parameter limit: 取得する上限件数
    /// - Returns: 先頭からのエントリと総件数と次の開始位置
    /// - Throws: メタデータやシャードが壊れている場合は列挙時のエラー
    func learningMemoryEntriesSinglePass(limit: Int) throws -> LearningMemoryPage {
        try self.learningMemoryManager.learningMemoryEntriesSinglePass(limit: limit)
    }

    /// 指定した読みに完全一致する永続化済み学習エントリのキーを取得する
    ///
    /// 全件列挙ではなく読みごとのポイント照会で求めるため、候補注釈や個別削除が高速に動作する
    ///
    /// 一時記憶は参照せず、永続化済みの内容だけを見る
    ///
    /// - Parameter exactReadings: 完全一致で探す読みの一覧
    /// - Returns: 読みと表記と品詞IDのキーの一覧
    /// - Throws: 学習データの置き場が無い場合や停止中の場合は列挙時のエラー
    func persistedLearningMemoryKeys(exactReadings: [String]) throws -> [PersistedLearningMemoryKey] {
        guard let memoryURL = self.memoryURL else {
            throw LearningMemoryEnumerationError.memoryDirectoryUnavailable
        }
        guard let louds = self.loadMemoryLOUDSIfNeeded() else {
            // LOUDSが無い場合でも停止中の内容は未学習と区別して報告する
            guard !LongTermLearningMemory.memoryCollapsed(directoryURL: memoryURL) else {
                throw LearningMemoryEnumerationError.pausedSnapshot
            }
            return []
        }
        return try LongTermLearningMemory.persistedLearningMemoryKeys(
            directoryURL: memoryURL,
            louds: louds,
            char2UInt8: self.learningMemoryManager.char2UInt8,
            exactReadings: exactReadings
        )
    }

    // 学習を反映する
    // TODO: previousの扱いを改善したい
    func updateLearningData(_ candidate: Candidate, with previous: DicdataElement?) {
        // 学習対象外の候補は無視
        if !candidate.isLearningTarget {
            return
        }
        if let previous {
            self.learningMemoryManager.update(data: [previous] + candidate.data)
        } else {
            self.learningMemoryManager.update(data: candidate.data)
        }
    }
    // 予測変換に基づいて学習を反映する
    // TODO: previousの扱いを改善したい
    func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        // 学習対象外の候補は無視
        if !candidate.isLearningTarget {
            return
        }
        switch predictionCandidate.type {
        case .additional(data: let data):
            self.learningMemoryManager.update(data: candidate.data, updatePart: data)
        case .replacement(targetData: let targetData, replacementData: let replacementData):
            self.learningMemoryManager.update(data: candidate.data.dropLast(targetData.count), updatePart: replacementData)
        }
    }
}
