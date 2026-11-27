import Foundation
import SwiftUtils

enum ZenzPromptBuilder {
    private static let inputTag = "\u{EE00}"
    private static let outputTag = "\u{EE01}"
    private static let contextTag = "\u{EE02}"
    private static let rightContextTag = "\u{EE07}"
    static let alignmentSeparator = "\u{EE08}"

    private static func trimmedContext(_ context: String, maxLength: Int?) -> String {
        guard !context.isEmpty else {
            return ""
        }
        return String(context.suffix(maxLength ?? 40))
    }

    private static func trimmedModeContext(_ modeContext: String?, maxLength: Int?) -> String {
        guard let modeContext else {
            return ""
        }
        return String(modeContext.suffix(maxLength ?? 40))
    }

    private static func trimmedRightContext(_ modeContext: String?, maxLength: Int?) -> String {
        guard let modeContext else {
            return ""
        }
        return String(modeContext.prefix(maxLength ?? 40))
    }

    private static func v3Conditions(_ mode: ConvertRequestOptions.ZenzaiV3DependentMode) -> [String] {
        var conditions: [String] = []
        if let profile = mode.profile, !profile.isEmpty {
            let pf = profile.suffix(25)
            conditions.append("\u{EE03}\(pf)")
        }
        if let topic = mode.topic, !topic.isEmpty {
            let tp = topic.suffix(25)
            conditions.append("\u{EE04}\(tp)")
        }
        if let style = mode.style, !style.isEmpty {
            let st = style.suffix(25)
            conditions.append("\u{EE05}\(st)")
        }
        if let preference = mode.preference, !preference.isEmpty {
            let pr = preference.suffix(25)
            conditions.append("\u{EE06}\(pr)")
        }
        return conditions
    }

    /// 入力予測用のプロンプト文字列を構築する
    ///
    /// v3モード以外が指定された場合はnilを返す
    ///
    /// - Parameters:
    ///   - leftSideContext: 左文脈の文字列
    ///   - composingText: 入力中の文字列
    ///   - versionDependentConfig: Zenzaiのバージョン依存設定
    ///   - alwaysEmitContextTag: 左文脈が空の場合でもコンテキストタグU+EE02を常に出力するかどうか
    /// - Returns: 構築したプロンプト文字列 (非対応バージョンではnil)
    static func inputPredictionPrompt(
        leftSideContext: String,
        composingText: String,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        alwaysEmitContextTag: Bool = false
    ) -> String? {
        guard case let .v3(mode) = versionDependentConfig else {
            return nil
        }
        let conditions = self.v3Conditions(mode)
        let trimmedLeftContext = self.trimmedContext(leftSideContext, maxLength: mode.maxLeftSideContextLength)
        let trimmedRightContext = self.trimmedRightContext(mode.rightSideContext, maxLength: mode.maxRightSideContextLength)
        let input = composingText.toKatakana()
        var prompt = conditions.joined(separator: "")
        // [Hazkey Community Patch]
        // Jinenモデルでは左文脈が空でもコンテキストタグU+EE02を前置する
        if alwaysEmitContextTag || !trimmedLeftContext.isEmpty {
            prompt += contextTag + trimmedLeftContext
        }
        if !trimmedRightContext.isEmpty {
            prompt += rightContextTag + trimmedRightContext
        }
        return prompt + inputTag + input
    }

    static func typoCorrectionPromptPrefix(leftSideContext: String) -> String {
        if leftSideContext.isEmpty {
            return inputTag
        } else {
            return contextTag + leftSideContext + inputTag
        }
    }

    /// 候補評価用のプロンプト文字列を構築する
    ///
    /// v2モードとv3モードでタグ配置を切り替える
    ///
    /// - Parameters:
    ///   - input: 評価対象の読み文字列
    ///   - inputCursorPosition: 読み内のカーソル位置
    ///   - userDictionaryPrompt: v2モード向けのユーザ辞書プロンプト文字列
    ///   - versionDependentConfig: Zenzaiのバージョン依存設定
    ///   - alwaysEmitContextTag: v3モードで左文脈が空の場合でもコンテキストタグU+EE02を常に出力するかどうか
    /// - Returns: 構築したプロンプト文字列
    static func candidateEvaluationPrompt(
        input: String,
        inputCursorPosition: Int? = nil,
        userDictionaryPrompt: String,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        alwaysEmitContextTag: Bool = false
    ) -> String {
        var conditions: [String] = []

        let leftSideContext: String
        let rightSideContext: String
        let enableAlignmentSeparator: Bool
        switch versionDependentConfig {
        case .v2(let mode):
            // ユーザ辞書の条件はv2のみ。v3には対応するタグがなく、入力前の余分な文字列として扱われる
            if !userDictionaryPrompt.isEmpty {
                conditions.append("辞書:\(userDictionaryPrompt)")
            }
            if let profile = mode.profile, !profile.isEmpty {
                let pf = profile.suffix(25)
                conditions.append("プロフィール:\(pf)")
            }
            leftSideContext = self.trimmedModeContext(mode.leftSideContext, maxLength: mode.maxLeftSideContextLength)
            rightSideContext = ""
            enableAlignmentSeparator = false
        case .v3(let mode):
            conditions.append(contentsOf: self.v3Conditions(mode))
            leftSideContext = self.trimmedModeContext(mode.leftSideContext, maxLength: mode.maxLeftSideContextLength)
            rightSideContext = self.trimmedRightContext(mode.rightSideContext, maxLength: mode.maxRightSideContextLength)
            enableAlignmentSeparator = mode.enableAlignmentSeparator
        }

        switch versionDependentConfig {
        case .v2:
            if !conditions.isEmpty {
                return inputTag + input + contextTag + conditions.joined(separator: "・") + "・発言:\(leftSideContext)" + outputTag
            } else if !leftSideContext.isEmpty {
                return inputTag + input + contextTag + leftSideContext + outputTag
            } else {
                return inputTag + input + outputTag
            }
        case .v3:
            var prompt = conditions.joined(separator: "")
            // [Hazkey Community Patch]
            // Jinenモデルでは左文脈が空でもコンテキストタグU+EE02を前置する
            if alwaysEmitContextTag || !leftSideContext.isEmpty {
                prompt += contextTag + leftSideContext
            }
            if !rightSideContext.isEmpty {
                prompt += rightContextTag + rightSideContext
            }
            let promptInput = enableAlignmentSeparator
                ? self.inputWithAlignmentSeparator(input, cursorPosition: inputCursorPosition)
                : input
            return prompt + inputTag + promptInput + outputTag
        }
    }

    static func shouldInsertAlignmentSeparator(input: String, cursorPosition: Int?) -> Bool {
        guard let cursorPosition else {
            return false
        }
        return cursorPosition >= 0 && cursorPosition < input.count
    }

    private static func inputWithAlignmentSeparator(_ input: String, cursorPosition: Int?) -> String {
        guard self.shouldInsertAlignmentSeparator(input: input, cursorPosition: cursorPosition), let cursorPosition else {
            return input
        }
        let cursorIndex = input.index(input.startIndex, offsetBy: cursorPosition)
        return String(input[..<cursorIndex]) + self.alignmentSeparator + String(input[cursorIndex...])
    }
}
