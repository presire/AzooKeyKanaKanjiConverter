import EfficientNGram
package import Foundation
import SwiftUtils

/// 同一モデルのnative contextをConverter間で共有する。
///
/// CPU推論を直列化することで、複数Converterが同時に18 MiBのKV cacheを保持する
/// ことを避ける。context内のKV再利用は毎回完全なtoken prefixを照合するため、
/// セッションを跨いでも推論結果には影響しない。
///
/// キャッシュキーは`resourceURL`と`deviceConfig`の両方から構成する。URLのみをキーにすると、
/// 同じモデルを異なるデバイス構成 (例: CPU→GPU切り替え) で要求した際に、先にロードされた
/// デバイス構成の`Zenz`（＝その`ZenzContext`）が誤って再利用されてしまう。
///
/// アクセスレベルはテスト容易性のためfileprivateからinternalへ緩和している
/// (publicではない = モジュール外からは引き続き不可視)。
final class SharedZenzCache: @unchecked Sendable {
    static let shared = SharedZenzCache()

    private init() {
        self.cache.countLimit = 1
    }

    func zenz(resourceURL: URL, deviceConfig: ZenzaiDeviceConfig) throws -> Zenz {
        try self.lock.withLock {
            let key = Self.cacheKey(resourceURL: resourceURL, deviceConfig: deviceConfig) as NSString
            if let cached = self.cache.object(forKey: key) {
                return cached
            }
            let zenz = try Zenz(resourceURL: resourceURL, deviceConfig: deviceConfig)
            self.cache.setObject(zenz, forKey: key)
            return zenz
        }
    }

    static func cacheKey(resourceURL: URL, deviceConfig: ZenzaiDeviceConfig) -> String {
        "\(resourceURL.absoluteString)#\(deviceConfig.deviceName ?? "")#\(deviceConfig.gpuLayers)"
    }

    private let cache = NSCache<NSString, Zenz>()
    private let lock = NSLock()
}

package final class Zenz {
    package var resourceURL: URL
    /// このZenzインスタンスが構築された際のGGMLバックエンドデバイス構成。
    /// 同一URLでも異なる構成が要求された場合はキャッシュを再利用してはならない
    /// (`KanaKanjiConverter.getModel`のインスタンスキャッシュ判定 `Zenz.canReuse` 参照)。
    package let deviceConfig: ZenzaiDeviceConfig
    private var zenzContext: ZenzContext?
    private let inferenceLock = NSLock()

    package static func shared(resourceURL: URL, deviceConfig: ZenzaiDeviceConfig = ZenzaiDeviceConfig()) throws -> Zenz {
        try SharedZenzCache.shared.zenz(resourceURL: resourceURL, deviceConfig: deviceConfig)
    }

    /// キャッシュされた`Zenz`を、指定されたURL・デバイス構成の要求に対して再利用してよいかを判定する。
    /// `KanaKanjiConverter.getModel`のインスタンスレベルキャッシュ判定から抽出した純粋な述語で、
    /// 実llama.cppコンテキストを構築せずにデバイス構成分離のリグレッションテストが行える。
    package static func canReuse(cachedURL: URL, cachedDeviceConfig: ZenzaiDeviceConfig, requestedURL: URL, requestedDeviceConfig: ZenzaiDeviceConfig) -> Bool {
        cachedURL == requestedURL && cachedDeviceConfig == requestedDeviceConfig
    }

    init(resourceURL: URL, deviceConfig: ZenzaiDeviceConfig = ZenzaiDeviceConfig()) throws {
        self.resourceURL = resourceURL
        self.deviceConfig = deviceConfig
        do {
            #if canImport(Darwin)
            if #available(iOS 16, macOS 13, *) {
                self.zenzContext = try ZenzContext.createContext(path: resourceURL.path(percentEncoded: false), deviceConfig: deviceConfig)
            } else {
                // this is not percent-encoded
                self.zenzContext = try ZenzContext.createContext(path: resourceURL.path, deviceConfig: deviceConfig)
            }
            #else
            // this is not percent-encoded
            self.zenzContext = try ZenzContext.createContext(path: resourceURL.path, deviceConfig: deviceConfig)
            #endif
            debug("Loaded model \(resourceURL.lastPathComponent)")
        } catch {
            throw error
        }
    }

    /// [hazkey-community patch] ロード中モデルが jinen (Qwen3) 系かどうか。
    /// `Kana2Kanji.all_zenzai` が辞書表記との制約比較を NFKC 正規化して行うために参照する。
    package var isJinenModel: Bool {
        self.zenzContext?.isJinenModel ?? false
    }

    package func endSession() {
        // contextはモデル単位で共有される。各呼び出し時にtoken prefixを照合して
        // 不一致範囲を除去するため、Converter単位のnative context再生成は不要。
    }

    func candidateEvaluate(
        convertTarget: String,
        convertTargetCursorPosition: Int? = nil,
        candidates: [Candidate],
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        memoizationCache: ZenzaiMemoizationCache
    ) -> CandidateEvaluationResult {
        self.inferenceLock.withLock {
            guard let zenzContext else {
                return .error
            }
            for candidate in candidates {
                return ZenzCandidateEvaluator.evaluate(
                    context: zenzContext,
                    input: convertTarget.toKatakana(),
                    inputCursorPosition: convertTargetCursorPosition,
                    candidate: candidate,
                    requestRichCandidates: requestRichCandidates,
                    prefixConstraint: prefixConstraint,
                    personalizationMode: personalizationMode,
                    versionDependentConfig: versionDependentConfig,
                    memoizationCache: memoizationCache
                )
            }
            return .error
        }
    }

    func predictNextInputText(
        leftSideContext: String,
        composingText: String,
        count: Int,
        minLength: Int = 1,
        maxEntropy: Float?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        possibleNexts: [String] = []
    ) -> String {
        self.inferenceLock.withLock {
            guard let zenzContext else {
                return ""
            }
            return ZenzInputTextGenerator.generate(
                context: zenzContext,
                leftSideContext: leftSideContext,
                composingText: composingText,
                count: count,
                minLength: minLength,
                maxEntropy: maxEntropy,
                versionDependentConfig: versionDependentConfig,
                possibleNexts: possibleNexts
            )
        }
    }

    package func pureGreedyDecoding(pureInput: String, maxCount: Int = .max) -> String {
        self.inferenceLock.withLock {
            guard let zenzContext else {
                return ""
            }
            return ZenzPureGreedyDecoder.decode(
                context: zenzContext,
                leftSideContext: pureInput,
                maxCount: maxCount
            )
        }
    }

    func generateTypoCandidates(
        leftSideContext: String,
        composingText: ComposingText,
        inputStyle: InputStyle,
        experimentalConfig: ExperimentalTypoCorrectionConfig,
        cache: ZenzaiTypoGenerationCache
    ) -> [ZenzaiTypoCandidate] {
        self.inferenceLock.withLock {
            guard let zenzContext else {
                return []
            }
            return ZenzaiTypoCandidateGenerator.generate(
                context: zenzContext,
                leftSideContext: leftSideContext,
                composingText: composingText,
                inputStyle: inputStyle,
                experimentalConfig: experimentalConfig,
                cache: cache
            )
        }
    }
}
