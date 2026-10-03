#if Zenzai || ZenzaiCPU
// Zenzai/ZenzaiCPU が有効でない場合、llama-mock.swift の実装が利用される
import llama
#endif
#if canImport(Darwin)
import Darwin
#endif

import Algorithms
import Foundation
import Synchronization
import SwiftUtils

// [Hazkey Community Patch] ZenzInferencePerf が数える推論の内訳。
/// 1要求分の値を `ZenzInferencePerf.consumeCounters()` で取り出す。
public struct ZenzInferencePerfCounters: Sendable, Equatable {
    /// llama_decode の実行回数
    public var inferenceCount = 0
    /// モデルに読ませたトークン数 (KVキャッシュを再利用できなかった部分)
    public var fedTokenCount = 0
    /// KVキャッシュを再利用できたトークン数
    public var reusedTokenCount = 0
    /// 候補評価の回数 (評価結果キャッシュのヒットも含む。推論上限を減らす単位)
    public var evaluationCount = 0
    /// 評価結果が .continue で下書きからやり直した回数
    public var redraftCount = 0
    /// 評価結果が .retry で同じ下書きの別候補を評価し直した回数
    public var retryCount = 0
    /// 下書き (kana2lattice) を作った回数 (下書きキャッシュのヒットは含まない)
    public var draftCount = 0
    /// リッチ評価の代替制約から下書きを作った回数 (draftCount とは別に数える)
    public var alternativeDraftCount = 0
    /// 下書きの作成時間の合計 (代替制約の下書きを含む)
    public var draftNanoseconds: UInt64 = 0
    /// 語彙の走査 (最大値・上位候補の探索) にかかった時間の合計
    public var vocabScanNanoseconds: UInt64 = 0
    public var evaluationCacheHitCount = 0
    public var evaluationCacheMissCount = 0
    public var resolvedConversionCacheHitCount = 0
    public var resolvedConversionCacheMissCount = 0
    public var draftConversionCacheHitCount = 0
    public var draftConversionCacheMissCount = 0
    public var promptTokenCacheHitCount = 0
    public var promptTokenCacheMissCount = 0
    /// リッチ評価の推論回数
    public var richInferenceCount = 0
    /// リッチ評価でモデルに読ませたトークン数
    public var richFedTokenCount = 0
    /// リッチ評価で、前回の評価のロジットを使い回したため読ませずに済んだトークン数
    public var richReusedTokenCount = 0
    /// リッチ評価のうち、全ての位置で前回の評価のロジットを使い回し、モデルを実行しなかった回数
    public var richFullyReusedCount = 0
    /// リッチ評価の推論時間の合計
    public var richInferenceNanoseconds: UInt64 = 0

    public init() {}
}

/// Zenzai推論の計測値を集めるプロセス共通の入れ物
///
/// 推論時間と推論期限の監視だけを持ち、推論自体は行わない
///
/// - Note: [Hazkey Community Patch]
public final class ZenzInferencePerf: @unchecked Sendable {
    /// 共有インスタンス
    public static let shared = ZenzInferencePerf()

    /// 計測値の更新を直列化する錠
    private let lock = NSLock()
    /// 積算した推論時間 (ナノ秒)
    private var elapsedNanoseconds: UInt64 = 0
    /// 計測が有効かどうか (HAZKEY_PERF_EVIDENCE設定時にtrue)
    public let enabled: Bool

    /// 推論期限 (ナノ秒、HAZKEY_ZENZAI_DEADLINE_MS設定時のみ有効)
    ///
    /// elapsedNanosecondsと同じ単調時計を使う
    ///
    /// - Note: 期限の監視はHAZKEY_PERF_EVIDENCE設定とは独立に動作する
    public let deadlineNanoseconds: UInt64?
    /// 現在の監視区間の開始時刻 (未開始時はnil)
    private var deadlineWindowStart: UInt64?

    /// 環境変数から計測有効化と推論期限を読み込んで初期化する
    private init() {
        let perfEvidence = ProcessInfo.processInfo.environment["HAZKEY_PERF_EVIDENCE"]
        self.enabled = perfEvidence?.isEmpty == false
        self.deadlineNanoseconds = Self.parseDeadlineMilliseconds(
            ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_DEADLINE_MS"]
        )
    }

    /// 環境変数の文字から推論期限をナノ秒に変換する
    ///
    /// 1から2000の整数だけを受け付け、それ以外は期限無効としてnilを返す
    ///
    /// - Parameter raw: 環境変数の文字
    /// - Returns: 推論期限 (ナノ秒、無効時はnil)
    private static func parseDeadlineMilliseconds(_ raw: String?) -> UInt64? {
        // 未設定や0や範囲外や非数値は全てデッドライン無効として扱いトラップしない
        guard let raw, let value = Int(raw), value >= 1, value <= 2_000 else {
            return nil
        }
        return UInt64(value) * 1_000_000
    }

    /// 推論時間を積算する
    ///
    /// - Parameter nanoseconds: 加算する推論時間 (ナノ秒)
    func record(_ nanoseconds: UInt64) {
        guard enabled else { return }
        lock.lock()
        elapsedNanoseconds &+= nanoseconds
        lock.unlock()
    }

    /// 積算した推論時間を取り出して0に戻す
    ///
    /// - Returns: 取り出した推論時間 (ナノ秒、無効時は0)
    public func consumeElapsedNanoseconds() -> UInt64 {
        guard enabled else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let elapsed = elapsedNanoseconds
        elapsedNanoseconds = 0
        return elapsed
    }

    // [Hazkey Community Patch] 推論の内訳を数える計測 (HAZKEY_PERF_EVIDENCE 設定時のみ)。
    // `elapsedNanoseconds` と同じく、呼び出し側が1要求ごとに consumeCounters() で取り出す。
    private var counters = ZenzInferencePerfCounters()

    /// 計測が有効なときだけ単調時計の値を返す。無効時は0を返し、時計を読まない。
    func now() -> UInt64 {
        enabled ? DispatchTime.now().uptimeNanoseconds : 0
    }

    /// `now()` で得た開始時刻からの経過時間 (無効時と開始時刻0では0)。
    func elapsed(since start: UInt64) -> UInt64 {
        start == 0 ? 0 : DispatchTime.now().uptimeNanoseconds &- start
    }

    func count(_ update: (inout ZenzInferencePerfCounters) -> Void) {
        guard enabled else { return }
        lock.lock()
        update(&counters)
        lock.unlock()
    }

    public func consumeCounters() -> ZenzInferencePerfCounters {
        guard enabled else { return ZenzInferencePerfCounters() }
        lock.lock()
        defer { lock.unlock() }
        let result = counters
        counters = ZenzInferencePerfCounters()
        return result
    }

    // [Hazkey Community Patch] A7: リッチ評価でロジット行を使い回したトークン数の累計。
    // HAZKEY_PERF_EVIDENCE の設定に関わらず、使い回しが起きたときだけ数える (テストで使い回しの発生を確かめるため)
    private var richLogitsReusedTokenTotal = 0

    func addRichLogitsReusedTokens(_ count: Int) {
        lock.lock()
        richLogitsReusedTokenTotal += count
        lock.unlock()
    }

    /// プロセスの開始からリッチ評価でロジット行を使い回したトークン数の累計
    public func richLogitsReusedTokenCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return richLogitsReusedTokenTotal
    }

    /// 期限監視の区間を開始する
    ///
    /// HAZKEY_ZENZAI_DEADLINE_MS未設定時は何もしない
    ///
    /// Zenzai推論を行う独立した入口 (all_zenzaiとZenzPureGreedyDecoder.decodeとZenzInputTextGenerator.generate) の先頭で呼ぶ
    public func beginDeadlineWindow() {
        guard deadlineNanoseconds != nil else { return }
        lock.lock()
        deadlineWindowStart = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    /// 現在の監視区間が期限切れかどうかを返す
    ///
    /// 期限未設定または区間未開始の場合は常にfalseを返し既存の動作を変えない
    ///
    /// - Returns: 期限切れならtrue
    public func deadlineExpired() -> Bool {
        guard let deadlineNanoseconds else { return false }
        lock.lock()
        let start = deadlineWindowStart
        lock.unlock()
        guard let start else { return false }
        return DispatchTime.now().uptimeNanoseconds &- start >= deadlineNanoseconds
    }
}

/// GGMLバックエンドデバイスの構成 (ConvertRequestOptions側の定義への別名)
///
/// - Note: 7ka-hiira/AzooKeyKanaKanjiConverterのcommit 8b4befcから移植
public typealias ZenzaiDeviceConfig = ConvertRequestOptions.ZenzaiMode.DeviceConfig

/// GGMLバックエンドデバイスの情報
///
/// - Note: 7ka-hiira/AzooKeyKanaKanjiConverterのcommit 8b4befcから移植
public struct GGMLBackendDevice: Sendable {
    /// デバイス名
    public let name: String
    /// デバイスの説明
    public let description: String
    /// デバイスの種別
    public let type: DeviceType

    /// デバイスの種別
    ///
    /// - Note: igpuはホストメモリを使う内蔵GPUというGGML独自の区分であり、専用メモリのgpuとは区別されるがモデル層のオフロード先として同等に扱える
    public enum DeviceType: Sendable {
        /// CPU
        case cpu
        /// 専用メモリを持つGPU
        case gpu
        /// ホストメモリを使う内蔵GPU (38ef2faによる独自拡張)
        case igpu
        /// その他の加速器
        case accel
        /// 不明な種別
        case unknown
    }

    /// 値をそのまま保持する初期化子であり、どのZenzai traitでも使える
    ///
    /// 実llama.cppに触れずに仮想デバイスでresolveDeviceConfigをテストするために用意する
    ///
    /// - Parameters:
    ///   - name: デバイス名
    ///   - description: デバイスの説明
    ///   - type: デバイスの種別
    public init(name: String, description: String, type: DeviceType) {
        self.name = name
        self.description = description
        self.type = type
    }

    /// 実GGMLデバイスから情報を取り出す (本番用であり、enumerateGGMLBackendDevicesからのみ呼ばれる)
    ///
    /// - Parameter device: 実GGMLバックエンドデバイス
    #if Zenzai
    init(device: ggml_backend_dev_t) {
        if let namePtr = ggml_backend_dev_name(device) {
            self.name = String(cString: namePtr)
        } else {
            self.name = "Unknown"
        }

        if let descPtr = ggml_backend_dev_description(device) {
            self.description = String(cString: descPtr)
        } else {
            self.description = "Unknown"
        }

        switch ggml_backend_dev_type(device) {
        case GGML_BACKEND_DEVICE_TYPE_CPU:
            self.type = .cpu
        case GGML_BACKEND_DEVICE_TYPE_GPU:
            self.type = .gpu
        case GGML_BACKEND_DEVICE_TYPE_IGPU:
            self.type = .igpu
        case GGML_BACKEND_DEVICE_TYPE_ACCEL:
            self.type = .accel
        default:
            self.type = .unknown
        }
    }
    #endif
}

/// 利用可能なGGMLバックエンドデバイスを列挙する
///
/// 使う前にloadGGMLBackendsを1回呼んでおく
///
/// - Returns: 見つかったデバイスの一覧 (traitなしビルドでは空)
/// - Note: 7ka-hiira/AzooKeyKanaKanjiConverterのcommit 8b4befcから移植
public func enumerateGGMLBackendDevices() -> [GGMLBackendDevice] {
    #if Zenzai
    let deviceCount = ggml_backend_dev_count()
    var devices: [GGMLBackendDevice] = []
    for i in 0..<deviceCount {
        if let device = ggml_backend_dev_get(i) {
            devices.append(GGMLBackendDevice(device: device))
        }
    }
    return devices
    #else
    return []
    #endif
}

/// 利用可能なGGMLバックエンドを全て読み込む
///
/// - Parameter path: バックエンドを探すディレクトリ (nilの場合は既定の探索を使う)
/// - Note: 7ka-hiira/AzooKeyKanaKanjiConverterのcommit 8b4befcから移植
public func loadGGMLBackends(from path: String? = nil) {
    #if Zenzai
    if let path {
        ggml_backend_load_all_from_path(path)
    } else {
        ggml_backend_load_all()
    }
    #endif
}

/// 列挙済みのデバイス一覧からZenzaiDeviceConfigを決める純粋な選択処理
///
/// createDeviceConfigから切り出したテスト容易な関数であり、実llama.cppに触れない
///
/// テストは仮想のGGMLBackendDevice (igpuを含む) を直接渡して種別判定を検証する
///
/// - Parameters:
///   - deviceName: 使用するデバイス名 (nilの場合はCPUデバイスを選ぶ)
///   - gpuLayers: GPUへオフロードする層数
///   - devices: 列挙済みのデバイス一覧
/// - Returns: 決定したデバイス構成
func resolveDeviceConfig(
    deviceName: String?,
    gpuLayers: Int32,
    devices: [GGMLBackendDevice]
) -> ZenzaiDeviceConfig {
    if let targetName = deviceName,
       let device = devices.first(where: { $0.name == targetName }) {
        switch device.type {
        case .gpu, .igpu:
            return ZenzaiDeviceConfig(deviceName: targetName, gpuLayers: gpuLayers)
        case .cpu, .accel, .unknown:
            return ZenzaiDeviceConfig(deviceName: targetName, gpuLayers: 0)
        }
    }

    if let cpuDevice = devices.first(where: { $0.type == .cpu }) {
        return ZenzaiDeviceConfig(deviceName: cpuDevice.name, gpuLayers: 0)
    }

    return ZenzaiDeviceConfig(deviceName: nil, gpuLayers: 0)
}

/// 利用可能なバックエンドデバイスを調べてデバイス構成を作る
///
/// 内部ではenumerateGGMLBackendDevicesの結果をresolveDeviceConfigに渡す
///
/// - Parameters:
///   - deviceName: 使用するデバイス名 (nilの場合は自動選択)
///   - gpuLayers: GPUへオフロードする層数
/// - Returns: 決定したデバイス構成
/// - Note: 7ka-hiira/AzooKeyKanaKanjiConverterのcommit 8b4befcから移植
public func createDeviceConfig(
    deviceName: String? = nil,
    gpuLayers: Int32 = 99
) -> ZenzaiDeviceConfig {
    resolveDeviceConfig(deviceName: deviceName, gpuLayers: gpuLayers, devices: enumerateGGMLBackendDevices())
}

enum ZenzError: LocalizedError {
    case couldNotLoadModel(path: String)
    case couldNotLoadContext
    case couldNotLoadVocab

    var errorDescription: String? {
        switch self {
        case .couldNotLoadContext: return "failed to load context"
        case .couldNotLoadModel(path: let path): return "could not load model weight at \(path)"
        case .couldNotLoadVocab: return "failed to load vocab"
        }
    }
}

/// llama.cpp のバックエンドはプロセス単位で一度だけ初期化する。
///
/// `llama_backend_free()` は現在 MPI 用の後始末にしか使われないため、モデルや
/// コンテキストより先に解放される可能性があるプロセス終了時の明示解放は行わない。
private enum ZenzBackend {
    private static let initialized: Void = {
        // ベンダーの異なるVulkan ICDが共存するマルチGPUのLinux環境でのSIGILLクラッシュを抑える
        // 参照: https://github.com/7ka-Hiira/hazkey/issues/29
        // VulkanローダーがVkInstanceを作ると全ICDを初期化し、ベンダー混在状態がSwiftランタイムの事前条件失敗
        // (ud2によるSIGILL) を起こすため、ggml_backend_load_all実行より前に単一ベンダーのICDへ制限する
        // この失敗はSwiftのdo/catchでは捕捉できない
        Self.pinVulkanICDIfNeeded()

        llama_backend_init()
    }()

    static func initializeIfNeeded() {
        _ = self.initialized
    }

    /// 標準の探索場所からVulkan ICDを検出し、複数ベンダー共存時は最初のベンダーのICD群へローダーを制限する
    ///
    /// 制限はVK_DRIVER_FILESとVK_ICD_FILENAMESの書き出しで行う
    ///
    /// 複数GPU環境 (NVIDIAのdGPUとAMDやIntelのiGPUの共存など) で両方のICDが入っているとZenzaiやVulkanの初期化中にSIGILLで落ちる問題
    /// (https://github.com/7ka-Hiira/hazkey/issues/29) への回避策である
    ///
    /// 利用者が指定したVK_DRIVER_FILESやVK_ICD_FILENAMES (シェルやsystemd unitや設定ファイルによる指定) は常に尊重し上書きしない
    ///
    /// - Note: ICDが2件以上あるときだけ介入し、1件の環境は問題の影響を受けないため触れない
    ///
    /// - Note: 選んだベンダーのICDは全て残す
    ///
    /// 同一ベンダーのICD同士は安全に共存でき、1ファイルへ絞ると搭載GPUに対応しないドライバーを選ぶ恐れがある
    /// (intel_hasvk_icd.x86_64.jsonがintel_icd.x86_64.jsonより先に整列され、HASVKはGen7とGen8にしか対応しないためANV対応のiGPUが見えなくなる)
    ///
    /// - Important: あらゆるGGMLバックエンドやVulkan APIの呼び出しより前に呼ぶこと
    private static func pinVulkanICDIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if env["VK_DRIVER_FILES"] != nil { return }
        if env["VK_ICD_FILENAMES"] != nil { return }

        var icdSearchPaths = [
            "/usr/share/vulkan/icd.d",
            "/usr/local/share/vulkan/icd.d",
            "/etc/vulkan/icd.d",
        ]
        // XDG_DATA_DIRS設定時はその配下も探索する (ArchやFedoraやDebianでの典型的な配置に対応する)
        if let xdg = env["XDG_DATA_DIRS"] {
            for entry in xdg.split(separator: ":") {
                icdSearchPaths.append("\(entry)/vulkan/icd.d")
            }
        }

        let fm = FileManager.default
        var foundICDs: [String] = []
        for searchPath in icdSearchPaths {
            guard let candidates = try? fm.contentsOfDirectory(atPath: searchPath) else { continue }
            // ディレクトリの順序はファイルシステムにより安定しないため整列し、選ぶベンダー群を確定的にする
            for candidate in candidates.filter({ $0.hasSuffix(".json") }).sorted() {
                foundICDs.append("\(searchPath)/\(candidate)")
            }
        }

        // ICDが複数あるときだけ介入し、1件の環境は問題の影響を受けないため何もしない
        guard foundICDs.count > 1 else { return }

        let firstVendor = VulkanICDVendor(filename: URL(fileURLWithPath: foundICDs[0]).lastPathComponent)
        let pinned = foundICDs
            .filter { VulkanICDVendor(filename: URL(fileURLWithPath: $0).lastPathComponent) == firstVendor }
            .joined(separator: ":")
        debug("[Vulkan ICD] Multi-ICD environment detected: \(foundICDs). Pinning to \(pinned) to avoid SIGILL (Issue #29).")
        setenv("VK_DRIVER_FILES", pinned, 1)
        setenv("VK_ICD_FILENAMES", pinned, 1)
    }

    /// ICDファイル名をベンダー別にまとめる区分
    ///
    /// 同一ベンダーのマニフェストだけを一緒に残すための判定に使う
    ///
    /// 不明な名前は自分自身にだけ一致し、未知ドライバーでは従来の1ファイル指定の振る舞いを保つ
    private enum VulkanICDVendor: Equatable {
        /// Intel
        case intel
        /// NVIDIA
        case nvidia
        /// AMD
        case amd
        /// lavapipe (ソフトウェア実装)
        case lavapipe
        /// 未知の名前 (ファイル名ごと区別する)
        case other(String)

        /// ファイル名からベンダー区分を作る
        ///
        /// - Parameter filename: ICDマニフェストのファイル名
        init(filename: String) {
            if filename.hasPrefix("intel") {
                self = .intel
            } else if filename.contains("nvidia") {
                self = .nvidia
            } else if filename.contains("radeon") || filename.contains("amd") {
                self = .amd
            } else if filename.contains("lvp") {
                self = .lavapipe
            } else {
                self = .other(filename)
            }
        }
    }
}

private final class ZenzTokenArrayBox {
    init(_ tokens: [llama_token]) {
        self.tokens = tokens
    }

    let tokens: [llama_token]
}

struct ZenzResolvedConversionCacheKey: Equatable, Hashable {
    var input: [ComposingText.InputElement]
    var convertTarget: String
    var convertTargetCursorPosition: Int?
    var keyboardLanguage: KeyboardLanguage
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    var prefixConstraint: Kana2Kanji.PrefixConstraint
    var inferenceLimit: Int
    /// 評価に使った全文の読み
    ///
    /// カーソルより前の読みが同じでも右側の読みが違う入力で変換結果を共有しないためにキーの一部にする
    ///
    /// - Note: [Hazkey Community Patch]
    var evaluationConvertTarget: String
}

struct ZenzDraftConversionCacheKey: Equatable, Hashable {
    var input: [ComposingText.InputElement]
    var convertTarget: String
    var convertTargetCursorPosition: Int?
    var keyboardLanguage: KeyboardLanguage
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    var prefixConstraint: Kana2Kanji.PrefixConstraint
}

struct ZenzDraftConversion {
    var resultPrevs: [RegisteredNode]
    var resultLatticeHead: ZenzResolvedLatticeHead
}

struct ZenzResolvedConversion {
    var resultPrevs: [RegisteredNode]
    var resultLatticeHead: ZenzResolvedLatticeHead
    var prefixConstraint: Kana2Kanji.PrefixConstraint
    var satisfyingCandidate: Candidate
}

struct ZenzResolvedLatticeNode: Hashable {
    var data: DicdataElement
    var range: Lattice.LatticeRange
}

final class ZenzResolvedLatticeHead: @unchecked Sendable {
    init(nodes: [ZenzResolvedLatticeNode]) {
        self.nodes = nodes
        self.fingerprint = nodes.hashValue
    }

    let nodes: [ZenzResolvedLatticeNode]
    let fingerprint: Int
}

private final class ZenzResolvedConversionCache: @unchecked Sendable {
    private struct Entry {
        var value: ZenzResolvedConversion
        var accessIndex: UInt64
    }

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: ZenzResolvedConversionCacheKey) -> ZenzResolvedConversion? {
        self.lock.withLock {
            guard var entry = self.entries[key] else {
                return nil
            }
            self.accessIndex &+= 1
            entry.accessIndex = self.accessIndex
            self.entries[key] = entry
            return entry.value
        }
    }

    func insert(_ value: ZenzResolvedConversion, for key: ZenzResolvedConversionCacheKey) {
        var value = value
        self.lock.withLock {
            // 逐次入力では最大辞書長を超えた後の先頭候補が同一になる。
            // 不変配列を既存entryと共有し、prefixごとの重複保持を避ける。
            if let sharedHead = self.entries.values.lazy.map({
                $0.value.resultLatticeHead
            }).first(where: {
                $0.fingerprint == value.resultLatticeHead.fingerprint
                    && $0.nodes == value.resultLatticeHead.nodes
            }) {
                value.resultLatticeHead = sharedHead
            }
            self.accessIndex &+= 1
            self.entries[key] = Entry(value: value, accessIndex: self.accessIndex)
            if self.entries.count > self.capacity,
               let oldestKey = self.entries.min(by: {
                   $0.value.accessIndex < $1.value.accessIndex
               })?.key {
                self.entries.removeValue(forKey: oldestKey)
            }
        }
    }

    private let capacity: Int
    private var entries: [ZenzResolvedConversionCacheKey: Entry] = [:]
    private var accessIndex: UInt64 = 0
    private let lock = NSLock()
}

/// 同じ辞書状態・入力・制約から得た不変のdraft経路を共有するLRU cache。
/// 可変な探索状態を含むlattice本体は保持しない。
final class ZenzDraftConversionCache: @unchecked Sendable {
    private struct Entry {
        var value: ZenzDraftConversion
        var accessIndex: UInt64
    }

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: ZenzDraftConversionCacheKey) -> ZenzDraftConversion? {
        self.lock.withLock {
            guard var entry = self.entries[key] else { return nil }
            self.accessIndex &+= 1
            entry.accessIndex = self.accessIndex
            self.entries[key] = entry
            return entry.value
        }
    }

    func insert(_ value: ZenzDraftConversion, for key: ZenzDraftConversionCacheKey) {
        var value = value
        self.lock.withLock {
            if let sharedHead = self.entries.values.lazy.map({
                $0.value.resultLatticeHead
            }).first(where: {
                $0.fingerprint == value.resultLatticeHead.fingerprint
                    && $0.nodes == value.resultLatticeHead.nodes
            }) {
                value.resultLatticeHead = sharedHead
            }
            self.accessIndex &+= 1
            self.entries[key] = Entry(value: value, accessIndex: self.accessIndex)
            if self.entries.count > self.capacity,
               let oldestKey = self.entries.min(by: {
                   $0.value.accessIndex < $1.value.accessIndex
               })?.key {
                self.entries.removeValue(forKey: oldestKey)
            }
        }
    }

    private let capacity: Int
    private var entries: [ZenzDraftConversionCacheKey: Entry] = [:]
    private var accessIndex: UInt64 = 0
    private let lock = NSLock()
}

/// 1つの`KanaKanjiConverter`内で再利用するZenzaiのメモ化キャッシュ。
///
/// モデルやnative contextとは所有者を分け、別Converter間では共有しない。一方、
/// `stopComposition()`は入力中の状態だけを終了するAPIなので、このキャッシュは
/// compositionを跨いで保持する。
final class ZenzaiMemoizationCache: @unchecked Sendable {
    init(
        evaluationCapacity: Int = 256,
        resolvedConversionCapacity: Int = 64,
        draftConversionCapacity: Int = 128,
        promptTokenCapacity: Int = 128
    ) {
        self.evaluationCache = ZenzEvaluationCache(capacity: evaluationCapacity)
        self.resolvedConversionCache = ZenzResolvedConversionCache(
            capacity: resolvedConversionCapacity
        )
        self.draftConversionCache = ZenzDraftConversionCache(
            capacity: draftConversionCapacity
        )
        self.evaluationPromptTokenCache.countLimit = promptTokenCapacity
    }

    func cachedEvaluation(for key: ZenzEvaluationCacheKey) -> CandidateEvaluationResult? {
        let value = self.evaluationCache.value(for: key)
        ZenzInferencePerf.shared.count {
            if value == nil { $0.evaluationCacheMissCount += 1 } else { $0.evaluationCacheHitCount += 1 }
        }
        return value
    }

    func cacheEvaluation(_ result: CandidateEvaluationResult, for key: ZenzEvaluationCacheKey) {
        self.evaluationCache.insert(result, for: key)
    }

    func cachedResolvedConversion(
        for key: ZenzResolvedConversionCacheKey
    ) -> ZenzResolvedConversion? {
        let value = self.resolvedConversionCache.value(for: key)
        ZenzInferencePerf.shared.count {
            if value == nil { $0.resolvedConversionCacheMissCount += 1 } else { $0.resolvedConversionCacheHitCount += 1 }
        }
        return value
    }

    func cacheResolvedConversion(
        _ value: ZenzResolvedConversion,
        for key: ZenzResolvedConversionCacheKey
    ) {
        self.resolvedConversionCache.insert(value, for: key)
    }

    func cachedDraftConversion(for key: ZenzDraftConversionCacheKey) -> ZenzDraftConversion? {
        let value = self.draftConversionCache.value(for: key)
        ZenzInferencePerf.shared.count {
            if value == nil { $0.draftConversionCacheMissCount += 1 } else { $0.draftConversionCacheHitCount += 1 }
        }
        return value
    }

    func cacheDraftConversion(
        _ value: ZenzDraftConversion,
        for key: ZenzDraftConversionCacheKey
    ) {
        self.draftConversionCache.insert(value, for: key)
    }

    func cachedEvaluationPromptTokens(for prompt: String) -> [llama_token]? {
        let tokens = self.evaluationPromptTokenCache.object(forKey: prompt as NSString)?.tokens
        ZenzInferencePerf.shared.count {
            if tokens == nil { $0.promptTokenCacheMissCount += 1 } else { $0.promptTokenCacheHitCount += 1 }
        }
        return tokens
    }

    func cacheEvaluationPromptTokens(_ tokens: [llama_token], for prompt: String) {
        self.evaluationPromptTokenCache.setObject(
            ZenzTokenArrayBox(tokens),
            forKey: prompt as NSString
        )
    }

    private let evaluationCache: ZenzEvaluationCache
    private let resolvedConversionCache: ZenzResolvedConversionCache
    private let draftConversionCache: ZenzDraftConversionCache
    private let evaluationPromptTokenCache = NSCache<NSString, ZenzTokenArrayBox>()
}

/// 読み取り専用のGGUFモデルを複数の推論コンテキスト間で共有する。
///
/// KV cacheなどの可変状態は`ZenzContext`側に残し、モデルの重みとvocabularyだけを
/// 共有することで、同じモデルを利用するConverterごとの再ロードを避ける。
///
/// アクセスレベルはテスト容易性のためfileprivateからinternalへ緩和している
///
/// (publicではないためモジュール外からは引き続き不可視)
final class SharedZenzModel {
    /// GGUFモデルを読み込み、語彙とアーキテクチャを取り出す
    ///
    /// バックエンドの初期化はZenzBackendが1回だけ行う
    ///
    /// - Parameters:
    ///   - path: モデルファイルのパス
    ///   - deviceConfig: GGMLバックエンドデバイスの構成
    /// - Throws: モデルや語彙の読み込みに失敗した場合
    init(path: String, deviceConfig: ZenzaiDeviceConfig) throws {
        ZenzBackend.initializeIfNeeded()
        var modelParams = llama_model_default_params()
        #if Zenzai
        modelParams.n_gpu_layers = deviceConfig.gpuLayers
        let loadedModel: OpaquePointer?
        if let deviceName = deviceConfig.deviceName,
           let device = ggml_backend_dev_by_name(deviceName) {
            var devices = [device, nil]
            loadedModel = devices.withUnsafeMutableBufferPointer { buffer in
                modelParams.devices = buffer.baseAddress
                return llama_model_load_from_file(path, modelParams)
            }
        } else {
            loadedModel = llama_model_load_from_file(path, modelParams)
        }
        #elseif ZenzaiCPU
        modelParams.n_gpu_layers = 0
        modelParams.split_mode = LLAMA_SPLIT_MODE_NONE
        guard let cpuDevice = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU) else {
            debug("Could not find CPU backend")
            throw ZenzError.couldNotLoadModel(path: path)
        }
        // NULL終端のCPU専用デバイス一覧を渡す
        // n_gpu_layersが0だけではllama.cppがMetalデバイスも列挙し、コンテキスト生成時に初期化してしまう
        var devices = [cpuDevice, nil]
        let loadedModel = devices.withUnsafeMutableBufferPointer { buffer in
            modelParams.devices = buffer.baseAddress
            return llama_model_load_from_file(path, modelParams)
        }
        #else
        let loadedModel = llama_model_load_from_file(path, modelParams)
        #endif
        guard let model = loadedModel else {
            debug("Could not load model at \(path)")
            throw ZenzError.couldNotLoadModel(path: path)
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            debug("Could not load vocab!")
            throw ZenzError.couldNotLoadVocab
        }
        self.model = model
        self.vocab = vocab
        self.architecture = Self.architecture(of: model)
    }

    deinit {
        llama_model_free(self.model)
    }

    let model: OpaquePointer
    let vocab: OpaquePointer

    /// GGUFのgeneral.architectureの値
    ///
    /// jinen (Qwen3) 系はNFKC正規化とBOSなしと条件トークンなしで推論する必要があり、ZenzContextがこの値で方式を判定する
    ///
    /// 既存zenzはzenzを返すため挙動は変わらない
    ///
    /// - Note: [Hazkey Community Patch]
    let architecture: String

    /// モデルのメタデータからgeneral.architectureを読む
    ///
    /// 読めない場合は空文字を返し、jinen系とは判定しない
    ///
    /// - Parameter model: 読み込み済みのモデル
    /// - Returns: general.architectureの値 (読めない場合は空文字)
    private static func architecture(of model: OpaquePointer) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = llama_model_meta_val_str(model, "general.architecture", &buffer, buffer.count)
        guard length > 0 else {
            return ""
        }
        return String(cString: buffer)
    }
}

/// 同時に強参照するモデルを1個に制限する、プロセス共通のモデルキャッシュ。
///
/// `NSCache`にすることでメモリプレッシャー時にはモデルを解放できる。呼び出し側の
/// `ZenzContext`もモデルを強参照するため、使用中のモデルが解放されることはない。
///
/// キャッシュキーはpathとdeviceConfigの両方から構成する
///
/// pathだけをキーにすると同じモデルファイルを異なるデバイス構成で読み込もうとした際に先に読み込まれた構成のモデルが誤って再利用されてしまう
///
/// アクセスレベルはテスト容易性のためfileprivateからinternalへ緩和している
///
/// (publicではないためモジュール外からは引き続き不可視)
final class SharedZenzModelCache: @unchecked Sendable {
    static let shared = SharedZenzModelCache()

    private init() {
        self.cache.countLimit = 1
    }

    /// テスト用の注入点
    ///
    /// 本番コードは常にSharedZenzModel.initを既定値として使い、実際のllama.cppモデル読み込みを行う
    ///
    /// @testable importしたテストだけが実モデルやGPUなしでdeviceConfigの伝播や重複防止を検証するために上書きしてよく、使い終わったら必ず既定値へ戻す
    nonisolated(unsafe) static var modelConstructor: (String, ZenzaiDeviceConfig) throws -> SharedZenzModel = SharedZenzModel.init

    /// 要求されたパスとデバイス構成に対応する共有モデルを返す
    ///
    /// キャッシュにあれば再利用し、なければmodelConstructorで構築して保持する
    ///
    /// - Parameters:
    ///   - path: モデルファイルのパス
    ///   - deviceConfig: GGMLバックエンドデバイスの構成
    /// - Returns: 要求に対応する共有モデル
    /// - Throws: モデルの読み込みに失敗した場合
    func model(path: String, deviceConfig: ZenzaiDeviceConfig) throws -> SharedZenzModel {
        try self.lock.withLock {
            let key = Self.cacheKey(path: path, deviceConfig: deviceConfig) as NSString
            if let cached = self.cache.object(forKey: key) {
                return cached
            }
            let model = try Self.modelConstructor(path, deviceConfig)
            self.cache.setObject(model, forKey: key)
            return model
        }
    }

    /// モデルのパスとデバイス構成からキャッシュキーを作る
    ///
    /// 同じモデルでもデバイス構成が違えば別のモデルを保持するために両方をキーに含める
    ///
    /// - Parameters:
    ///   - path: モデルファイルのパス
    ///   - deviceConfig: GGMLバックエンドデバイスの構成
    /// - Returns: パスとデバイス名とGPU層数を連結したキー
    static func cacheKey(path: String, deviceConfig: ZenzaiDeviceConfig) -> String {
        "\(path)#\(deviceConfig.deviceName ?? "")#\(deviceConfig.gpuLayers)"
    }

    private let cache = NSCache<NSString, SharedZenzModel>()
    private let lock = NSLock()
}

final class ZenzContext {
    #if Zenzai || ZenzaiCPU
    /// CPU用ggmlスレッドプールの共有状態
    private struct CPUThreadPoolState: Sendable {
        /// 共有スレッドプールのアドレス (未作成時はnil)
        var threadPoolAddress: UInt?
        /// 共有スレッドプールのスレッド数
        var threadCount: Int32?
        /// 貸し出し中のコンテキスト数
        var leaseCount = 0
    }

    /// CPU用ggmlスレッドプールを1個だけ共有する保管庫
    ///
    /// スレッド数が一致する要求には同じプールを貸し出し、使い終わった全コンテキストが返却したら破棄する
    private final class CPUThreadPoolStore: Sendable {
        private let state = Mutex(CPUThreadPoolState())

        /// 共有スレッドプールを貸し出す
        ///
        /// スレッド数が一致すれば既存プールの貸し出し数を増やし、未作成なら作ってから貸し出す
        ///
        /// - Parameter threadCount: 要求するスレッド数
        /// - Returns: 貸し出すスレッドプール (作成失敗時はnil)
        func acquire(threadCount: Int32) -> OpaquePointer? {
            state.withLock { state in
                if let threadPoolAddress = state.threadPoolAddress,
                   let threadPool = OpaquePointer(bitPattern: threadPoolAddress) {
                    guard state.threadCount == threadCount else {
                        return nil
                    }
                    state.leaseCount += 1
                    return threadPool
                }

                guard let threadPool = llama_cpu_threadpool_create(threadCount) else {
                    return nil
                }

                state.threadPoolAddress = UInt(bitPattern: threadPool)
                state.threadCount = threadCount
                state.leaseCount = 1
                NSLog("ZenzContext CPU ggml threadpool created (threads: \(threadCount))")
                return threadPool
            }
        }

        /// 借りたスレッドプールを返却する
        ///
        /// 貸し出し数が0になったらプールを破棄する
        ///
        /// - Parameter threadPool: 返却するスレッドプール
        func release(_ threadPool: OpaquePointer) {
            state.withLock { state in
                guard state.threadPoolAddress == UInt(bitPattern: threadPool), state.leaseCount > 0 else {
                    return
                }

                state.leaseCount -= 1
                guard state.leaseCount == 0 else {
                    return
                }

                state.threadPoolAddress = nil
                state.threadCount = nil
                llama_cpu_threadpool_free(threadPool)
                NSLog("ZenzContext CPU ggml threadpool released")
            }
        }
    }

    /// プロセス共通のCPUスレッドプール保管庫
    private static let cpuThreadPoolStore = CPUThreadPoolStore()
    #endif

    private let sharedModel: SharedZenzModel
    private var context: OpaquePointer
    private var batch: llama_batch
    private var prevInputBySeq: [llama_seq_id: [llama_token]] = [:]
    /// [Hazkey Community Patch] A7: 直前のリッチ評価のロジット行 (評価用シーケンスのみ)
    private let richLogitsRows: RichLogitsRowStore
    private var prevPromptBySeq: [llama_seq_id: String] = [:]
    // [Hazkey Community Patch] tokenToPiece(token:) の復号結果 (トークンIDで添字付け、未復号は nil)
    private var pieceCache: [[CChar]?] = []
    /// このコンテキストのデバイス構成 (再生成時に再利用する)
    private var currentDeviceConfig: ZenzaiDeviceConfig
    /// 借りている共有CPUスレッドプール (GPU構成時はnil)
    private let cpuThreadPool: OpaquePointer?
    /// 借りている共有CPUスレッドプールのスレッド数
    private let cpuThreadPoolThreadCount: Int32?

    private let n_len: Int32 = 512
    private let evalSeqId: llama_seq_id = 0
    private let inputPredictionSeqId: llama_seq_id = 1

    /// 共有モデルと構築済みコンテキストからZenzContextを作る
    ///
    /// - Parameters:
    ///   - sharedModel: 共有GGUFモデル
    ///   - context: llama.cppコンテキスト
    ///   - deviceConfig: このコンテキストのデバイス構成
    ///   - cpuThreadPool: 借りている共有CPUスレッドプール
    ///   - cpuThreadPoolThreadCount: 借りている共有CPUスレッドプールのスレッド数
    private init(
        sharedModel: SharedZenzModel,
        context: OpaquePointer,
        deviceConfig: ZenzaiDeviceConfig,
        cpuThreadPool: OpaquePointer?,
        cpuThreadPoolThreadCount: Int32?
    ) {
        self.sharedModel = sharedModel
        self.context = context
        self.batch = llama_batch_init(512, 0, 1)
        self.richLogitsRows = RichLogitsRowStore(rowWidth: Int(llama_vocab_n_tokens(sharedModel.vocab)))
        self.currentDeviceConfig = deviceConfig
        self.cpuThreadPool = cpuThreadPool
        self.cpuThreadPoolThreadCount = cpuThreadPoolThreadCount
    }

    deinit {
        Self.detachCPUThreadPool(self.cpuThreadPool, from: self.context)
        llama_batch_free(self.batch)
        llama_free(context)
        Self.releaseCPUThreadPool(self.cpuThreadPool)
    }

    /// CPU構成のときだけ共有CPUスレッドプールを借りる
    ///
    /// - Parameters:
    ///   - deviceConfig: このコンテキストのデバイス構成
    ///   - threadCount: 要求するスレッド数
    /// - Returns: 借りたスレッドプール (GPU構成時とtraitなしビルド時はnil)
    private static func acquireCPUThreadPool(
        deviceConfig: ZenzaiDeviceConfig,
        threadCount: Int32
    ) -> OpaquePointer? {
        #if Zenzai || ZenzaiCPU
        guard deviceConfig.gpuLayers == 0 else {
            return nil
        }
        return cpuThreadPoolStore.acquire(threadCount: threadCount)
        #else
        return nil
        #endif
    }

    /// 借りた共有CPUスレッドプールをコンテキストへ結び付ける
    ///
    /// プールとコンテキストのスレッド数が一致するときだけ結び付ける
    ///
    /// - Parameters:
    ///   - threadPool: 借りたスレッドプール
    ///   - poolThreadCount: プールのスレッド数
    ///   - contextThreadCount: コンテキストのスレッド数
    ///   - context: 結び付け先のコンテキスト
    private static func attachCPUThreadPool(
        _ threadPool: OpaquePointer?,
        poolThreadCount: Int32?,
        contextThreadCount: Int32,
        to context: OpaquePointer
    ) {
        #if Zenzai || ZenzaiCPU
        guard let threadPool, let poolThreadCount, poolThreadCount == contextThreadCount else {
            return
        }
        llama_attach_threadpool(context, threadPool, threadPool)
        #endif
    }

    /// 共有CPUスレッドプールをコンテキストから切り離す
    ///
    /// - Parameters:
    ///   - threadPool: 借りているスレッドプール
    ///   - context: 切り離し元のコンテキスト
    private static func detachCPUThreadPool(_ threadPool: OpaquePointer?, from context: OpaquePointer) {
        #if Zenzai || ZenzaiCPU
        guard threadPool != nil else {
            return
        }
        llama_detach_threadpool(context)
        #endif
    }

    /// 借りた共有CPUスレッドプールを返却する
    ///
    /// - Parameter threadPool: 返却するスレッドプール
    private static func releaseCPUThreadPool(_ threadPool: OpaquePointer?) {
        #if Zenzai || ZenzaiCPU
        guard let threadPool else {
            return
        }
        cpuThreadPoolStore.release(threadPool)
        #endif
    }

    /// デバイス構成に合わせたllama.cppコンテキスト設定を作る
    ///
    /// GPU層数が0より大きいときだけKQVのオフロードを有効にする
    ///
    /// - Parameter deviceConfig: このコンテキストのデバイス構成
    /// - Returns: コンテキスト設定
    private static func ctx_params(deviceConfig: ZenzaiDeviceConfig) -> llama_context_params {
        let n_threads = self.inferenceThreadCount
        debug("Using \(n_threads) threads")
        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = 512
        ctx_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        ctx_params.n_threads       = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)
        ctx_params.n_batch = 512
        #if Zenzai || ZenzaiCPU
        ctx_params.n_ubatch = 64
        #endif
        #if Zenzai
        ctx_params.offload_kqv = deviceConfig.gpuLayers > 0
        #endif
        // 推論時間は呼び出し側で計測する。llama.cpp内部の統計更新は不要。
        ctx_params.no_perf = true
        return ctx_params
    }

    /// 対話的な推論に使うCPUスレッド数を実行環境のトポロジーから決定する。
    ///
    /// Apple Siliconでは性能の異なるクラスタを跨ぐと短いdecodeのbarrier待ちが
    /// 増えるため、最高性能クラスタの物理コア数を利用する。それ以外の環境では
    /// OSへ応答性の余地を残しつつ、llama.cppの小規模モデルで過剰並列にならない
    /// よう8スレッドを上限とする。
    // [Hazkey Community Patch]
    // HAZKEY_ZENZAI_CPU_THREADS設定時はそのスレッド数を使い、未設定や不正な値は従来の自動決定を変えずに使う
    private static let cpuThreadCountOverride: Int? = {
        guard let raw = ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_CPU_THREADS"],
              let value = Int(raw), value >= 1, value <= 8 else {
            return nil
        }
        return value
    }()

    private static var inferenceThreadCount: Int {
        let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        #if canImport(Darwin)
        let performanceCoreCount = self.sysctlInt32("hw.perflevel0.physicalcpu")
        #else
        let performanceCoreCount: Int? = nil
        #endif
        let selected = self.selectInferenceThreadCount(
            activeProcessorCount: activeProcessorCount,
            performanceCoreCount: performanceCoreCount
        )
        if let override = self.cpuThreadCountOverride {
            debug("HAZKEY_ZENZAI_CPU_THREADS override: using \(override) threads (default would be \(selected))")
            return override
        }
        return selected
    }

    /// DarwinではmacOS/iOSともに最高性能クラスタを優先し、sysctl値を取得できない
    /// 端末やDarwin以外では論理CPU数から安全なフォールバックを選ぶ。
    static func selectInferenceThreadCount(
        activeProcessorCount: Int,
        performanceCoreCount: Int?
    ) -> Int {
        let activeProcessorCount = max(1, activeProcessorCount)
        if let performanceCoreCount,
           performanceCoreCount > 0,
           performanceCoreCount <= activeProcessorCount {
            return performanceCoreCount
        }
        let reservedProcessorCount = if activeProcessorCount >= 8 {
            2
        } else if activeProcessorCount >= 4 {
            1
        } else {
            0
        }
        return max(1, min(8, activeProcessorCount - reservedProcessorCount))
    }

    #if canImport(Darwin)
    private static func sysctlInt32(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else {
            return nil
        }
        return Int(value)
    }
    #endif

    /// 共有モデルから新しい推論コンテキストを作る
    ///
    /// CPU構成のときは共有CPUスレッドプールを借りて結び付ける
    ///
    /// - Parameters:
    ///   - path: モデルファイルのパス
    ///   - deviceConfig: GGMLバックエンドデバイスの構成 (省略時はCPU構成)
    /// - Returns: 新しい推論コンテキスト
    /// - Throws: モデルやコンテキストの読み込みに失敗した場合
    static func createContext(
        path: String,
        deviceConfig: ZenzaiDeviceConfig = ZenzaiDeviceConfig()
    ) throws -> ZenzContext {
        let sharedModel = try SharedZenzModelCache.shared.model(
            path: path,
            deviceConfig: deviceConfig
        )
        var params = ctx_params(deviceConfig: deviceConfig)
        #if ZenzaiCPU
        // CPU 専用: KV / KQV 等の GPU オフロードを完全に無効化
        params.offload_kqv = false
        #endif
        let context = llama_init_from_model(sharedModel.model, params)
        guard let context else {
            debug("Could not load context!")
            throw ZenzError.couldNotLoadContext
        }
        let cpuThreadPool = Self.acquireCPUThreadPool(
            deviceConfig: deviceConfig,
            threadCount: params.n_threads
        )
        let cpuThreadPoolThreadCount = cpuThreadPool == nil ? nil : params.n_threads
        Self.attachCPUThreadPool(
            cpuThreadPool,
            poolThreadCount: cpuThreadPoolThreadCount,
            contextThreadCount: params.n_threads,
            to: context
        )

        return ZenzContext(
            sharedModel: sharedModel,
            context: context,
            deviceConfig: deviceConfig,
            cpuThreadPool: cpuThreadPool,
            cpuThreadPoolThreadCount: cpuThreadPoolThreadCount
        )
    }

    func resetContext() throws {
        Self.detachCPUThreadPool(self.cpuThreadPool, from: self.context)
        llama_free(self.context)
        var params = Self.ctx_params(deviceConfig: self.currentDeviceConfig)
        #if ZenzaiCPU
        params.offload_kqv = false
        #endif
        let context = llama_init_from_model(self.sharedModel.model, params)
        guard let context else {
            debug("Could not load context!")
            throw ZenzError.couldNotLoadContext
        }
        self.context = context
        Self.attachCPUThreadPool(
            self.cpuThreadPool,
            poolThreadCount: self.cpuThreadPoolThreadCount,
            contextThreadCount: params.n_threads,
            to: context
        )
        self.prevInputBySeq = [:]
        self.richLogitsRows.release()
        self.prevPromptBySeq = [:]
    }

    /// リッチ評価で前回計算したロジット行を使い回す計画
    ///
    /// - Note: [Hazkey Community Patch] A7
    struct RichLogitsReusePlan: Equatable {
        /// この位置からモデルに読ませる (これより前はKVキャッシュに残す)
        var feedStart: Int
    }

    /// リッチ評価で、前回の評価のロジット行を使い回せる範囲を決める
    ///
    /// 位置 `p` のロジット行は `tokens[0...p]` だけで決まるため、トークン列が実際に一致した長さまでは前回の行をそのまま使える。
    /// 前回の行は `previousLogitsStart` 以降の位置にしかないため、今回の開始位置がそれより前なら使い回さない。
    ///
    /// - Parameters:
    ///   - previousTokens: 前回の評価で読ませたトークン列 (KVキャッシュの内容と一致していること)
    ///   - previousLogitsStart: 前回の評価でロジットを計算した開始位置
    ///   - tokens: 今回読ませるトークン列
    ///   - logitsStart: 今回ロジットが必要な開始位置
    /// - Returns: 使い回せる行が1つもないときは nil
    static func richLogitsReusePlan(
        previousTokens: [llama_token],
        previousLogitsStart: Int,
        tokens: [llama_token],
        logitsStart: Int
    ) -> RichLogitsReusePlan? {
        guard previousLogitsStart <= logitsStart, logitsStart >= 0 else {
            return nil
        }
        let matched = min(previousTokens.commonPrefix(with: tokens).count, tokens.count)
        guard matched > logitsStart else {
            return nil
        }
        return RichLogitsReusePlan(feedStart: matched)
    }

    /// リッチ評価のロジット行を使い回す機能が有効か
    ///
    /// `HAZKEY_ZENZAI_RICH_LOGITS_REUSE=0` で無効になる (使い回した場合としない場合で結果が同じことの確認用)。
    /// テストがプロセス内で切り替えられるよう、評価のたびに読む
    private static var richLogitsReuseEnabled: Bool {
        guard let value = getenv("HAZKEY_ZENZAI_RICH_LOGITS_REUSE") else {
            return true
        }
        return String(cString: value) != "0"
    }

    private func getLogits(tokens: [llama_token], logits_start_index: Int = 0, seqId: llama_seq_id = 0, isRichEvaluation: Bool = false) -> UnsafeMutablePointer<Float>? {
        let perfStart = ZenzInferencePerf.shared.enabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if perfStart != 0 {
                let elapsed = DispatchTime.now().uptimeNanoseconds - perfStart
                ZenzInferencePerf.shared.record(elapsed)
                if isRichEvaluation {
                    ZenzInferencePerf.shared.count {
                        $0.richInferenceNanoseconds &+= elapsed
                    }
                }
            }
        }
        // [Hazkey Community Patch] バッチとKVキャッシュに収まらない入力は、領域外へ書き込む前に拒否する
        // (バッチは n_len 件分しか確保していない)
        guard tokens.count <= Int(n_len), tokens.count <= Int(llama_n_ctx(context)) else {
            debug("error: \(tokens.count) tokens exceed the batch or the KV cache size")
            return nil
        }
        // [Hazkey Community Patch] A7: リッチ評価のロジット行は、評価用シーケンスの直前の推論がリッチ評価だったときだけ使い回す。
        // 評価用シーケンスの推論はKVキャッシュと直前の入力を書き換えるため、使い回しの記録を先に捨てる
        // (入力予測用シーケンスの推論は評価用シーケンスを書き換えないため、記録を残す)。
        // リッチ評価でない推論と、使い回しを無効にした場合は、行を保持せず領域も解放する
        let currentPrevInput = self.prevInputBySeq[seqId] ?? []
        let richLogits = self.richLogitsRows.beginInference(
            isEvaluationSequence: seqId == evalSeqId,
            isRichEvaluation: isRichEvaluation,
            reuseEnabled: Self.richLogitsReuseEnabled,
            kvTokens: currentPrevInput,
            tokens: tokens,
            logitsStart: logits_start_index
        )
        let reusePlan = richLogits.reusePlan

        var effectivePrevInput = currentPrevInput

        // もう一方のシーケンスの方が長い接頭辞一致を持つときはKVキャッシュを写して再利用する
        // (ロジット行を使い回すときは、自分のシーケンスがロジットの開始位置より先まで一致しているため写さない)
        let otherSeqId: llama_seq_id? = if seqId == evalSeqId {
            inputPredictionSeqId
        } else if seqId == inputPredictionSeqId {
            evalSeqId
        } else {
            nil
        }
        if reusePlan == nil, let otherSeqId, let otherPrevInput = self.prevInputBySeq[otherSeqId] {
            let currentPrefix = currentPrevInput.commonPrefix(with: tokens).count
            let otherPrefix = otherPrevInput.commonPrefix(with: tokens).count
            if otherPrefix > currentPrefix {
                let copiedPrefixCount = min(otherPrefix, logits_start_index)
                if copiedPrefixCount > 0 {
                    llama_memory_seq_rm(llama_get_memory(context), seqId, 0, -1)
                    llama_memory_seq_cp(llama_get_memory(context), otherSeqId, seqId, 0, llama_pos(copiedPrefixCount))
                    effectivePrevInput = otherPrevInput
                }
            }
        }

        // Manage KV cache: remove entries that differ from previous input
        let prefixCacheCount: Int
        do {
            let pos_max = llama_memory_seq_pos_max(llama_get_memory(self.context), seqId)
            debug("pos max:", pos_max, "prevInput count:", effectivePrevInput.count, "tokens count:", tokens.count)
            let commonTokens = effectivePrevInput.commonPrefix(with: tokens)
            // Remove KV cache from position commonTokens.count onwards to recompute divergent part
            // removed range: [llama_pos(commonTokens.count), inf)
            prefixCacheCount = reusePlan?.feedStart ?? min(commonTokens.count, logits_start_index)
            llama_memory_seq_rm(llama_get_memory(context), seqId, llama_pos(prefixCacheCount), -1)
            debug("new pos max:", llama_memory_seq_pos_max(llama_get_memory(self.context), seqId), "commonTokens:", commonTokens.count)
        }
        self.batch.n_tokens = 0
        for i in tokens.indices.dropFirst(prefixCacheCount) {
            llama_batch_add(&self.batch, tokens[i], Int32(i), [seqId], logits: logits_start_index <= i)
        }
        // 評価 (全ての位置で前回のロジット行を使い回すときはモデルを実行しない)
        if self.batch.n_tokens > 0, llama_decode(context, self.batch) != 0 {
            debug("llama_decode() failed")
            // [Hazkey Community Patch] 失敗時は処理済みの部分がKVキャッシュに残り得るため、読ませる前の状態に揃え、
            // 直前の入力もKVキャッシュの内容と一致させる (古い入力のままだと、次の推論が欠けた位置を再利用する)
            llama_memory_seq_rm(llama_get_memory(context), seqId, llama_pos(prefixCacheCount), -1)
            self.prevInputBySeq[seqId] = Array(tokens.prefix(prefixCacheCount))
            return nil
        }
        let reusedTokenCount = reusePlan.map { $0.feedStart - logits_start_index } ?? 0
        if reusedTokenCount > 0 {
            ZenzInferencePerf.shared.addRichLogitsReusedTokens(reusedTokenCount)
        }
        ZenzInferencePerf.shared.count {
            if self.batch.n_tokens > 0 {
                $0.inferenceCount += 1
            }
            $0.fedTokenCount += tokens.count - prefixCacheCount
            $0.reusedTokenCount += prefixCacheCount
            if isRichEvaluation {
                $0.richInferenceCount += 1
                $0.richFedTokenCount += tokens.count - prefixCacheCount
                $0.richReusedTokenCount += reusedTokenCount
                if reusePlan != nil && prefixCacheCount == tokens.count {
                    $0.richFullyReusedCount += 1
                }
            }
        }
        // update cached input for next call (for KV cache management)
        self.prevInputBySeq[seqId] = tokens
        guard richLogits.keepsRows, logits_start_index < tokens.count else {
            return llama_get_logits(context)
        }
        // [Hazkey Community Patch] A7: リッチ評価のロジット行を自前の領域へ集め、次のリッチ評価で使い回す。
        // 行の並びは llama_get_logits と同じ (位置 logits_start_index の行が先頭) で、呼び出し側の添字計算は変わらない
        let freshStart = max(prefixCacheCount, logits_start_index)
        let reusedRows: RichLogitsRowStore.ReusedRows? = richLogits.previousLogitsStart.map {
            .init(previousLogitsStart: $0, rowCount: freshStart - logits_start_index)
        }
        return self.richLogitsRows.assemble(
            tokens: tokens,
            logitsStart: logits_start_index,
            reusedRows: reusedRows,
            freshRows: freshStart < tokens.count ? llama_get_logits(context) : nil
        )
    }

    func previousEvaluationPrompt() -> String {
        self.prevPromptBySeq[evalSeqId] ?? ""
    }

    func setPreviousEvaluationPrompt(_ prompt: String) {
        self.prevPromptBySeq[evalSeqId] = prompt
    }

    func normalizeForModel(_ text: String) -> String {
        if self.isJinenModel {
            // [Hazkey Community Patch]
            // jinen (Qwen3) 系はNFKC正規化済みテキストで学習されているためzenz用の空白置換や改行削除は適用しない
            return text.precomposedStringWithCompatibilityMapping
        }
        return self.preprocessText(text: text)
    }

    /// モデルがjinen (Qwen3) 系かどうか
    ///
    /// GGUFのgeneral.architectureがqwen3のときにtrueになる
    ///
    /// jinen-v2系はNFKC前提とBOSなしと条件トークンなしで学習されているためzenzとは異なる前処理と符号化を使う
    ///
    /// - Note: [Hazkey Community Patch]
    var isJinenModel: Bool {
        self.sharedModel.architecture == "qwen3"
    }

    func encodeEvaluationPrompt(
        _ prompt: String,
        memoizationCache: ZenzaiMemoizationCache
    ) -> [llama_token] {
        if let cached = memoizationCache.cachedEvaluationPromptTokens(for: prompt) {
            return cached
        }
        // [Hazkey Community Patch]
        // jinen (Qwen3) 系はBOSを付けずに学習されているため符号化時にBOSを付けず、zenzは従来どおりBOSを付ける
        let tokens = self.encode(prompt, addBOS: !self.isJinenModel, addEOS: false)
        memoizationCache.cacheEvaluationPromptTokens(tokens, for: prompt)
        return tokens
    }

    func encode(_ text: String, addBOS: Bool, addEOS: Bool = false) -> [llama_token] {
        // [Hazkey Community Patch]
        // zenzは従来の前処理のまま符号化し、jinenはnormalizeForModelのNFKC正規化で符号化する
        self.tokenize(text: self.normalizeForModel(text), add_bos: addBOS, add_eos: addEOS)
    }

    func encodeRaw(_ text: String, addBOS: Bool, addEOS: Bool = false) -> [llama_token] {
        self.tokenize(text: text, add_bos: addBOS, add_eos: addEOS)
    }

    func evaluationLogits(tokens: [llama_token], startOffset: Int, isRichEvaluation: Bool = false) -> UnsafeMutablePointer<Float>? {
        self.getLogits(tokens: tokens, logits_start_index: startOffset, seqId: evalSeqId, isRichEvaluation: isRichEvaluation)
    }

    func inputPredictionLogits(tokens: [llama_token], startOffset: Int) -> UnsafeMutablePointer<Float>? {
        self.getLogits(tokens: tokens, logits_start_index: startOffset, seqId: inputPredictionSeqId)
    }

    var vocabSize: Int {
        Int(llama_vocab_n_tokens(self.sharedModel.vocab))
    }

    var eosToken: llama_token {
        llama_vocab_eos(self.sharedModel.vocab)
    }

    func decodeTokens(_ tokens: [llama_token]) -> String {
        let cchars: [CChar] = tokens.flatMap(self.tokenToPiece)
        let data = Data(cchars.map { UInt8(bitPattern: $0) })
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], logits: Bool) {
        batch.token   [Int(batch.n_tokens)] = id
        batch.pos     [Int(batch.n_tokens)] = pos
        batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
        for i in 0..<seq_ids.count {
            batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i]
        }
        batch.logits  [Int(batch.n_tokens)] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func preprocessText(text: String) -> String {
        // replace space into ideographic space (\u3000) for zenz tokenizer
        // replace newline into null for zenz tokenizer
        text.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "")
    }
    private func tokenize(text: String, add_bos: Bool, add_eos: Bool = false) -> [llama_token] {
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (add_bos ? 1 : 0)
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        let tokenCount = llama_tokenize(self.sharedModel.vocab, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, false)
        var swiftTokens: [llama_token] = if tokenCount < 0 {
            [llama_vocab_bos(self.sharedModel.vocab)]
        } else {
            (0..<tokenCount).map {tokens[Int($0)]}
        }
        tokens.deallocate()
        if add_eos {
            swiftTokens.append(llama_vocab_eos(self.sharedModel.vocab))
        }
        return swiftTokens
    }

    /// - note: The result does not contain null-terminator
    func tokenToPiece(token: llama_token) -> [CChar] {
        // [Hazkey Community Patch] 語彙は sharedModel (let) に固定されるため、復号結果を
        // このインスタンスの寿命の間だけ保持する。空の piece (制御トークン) も保持する。
        let index = Int(token)
        if self.pieceCache.isEmpty {
            self.pieceCache = Array(repeating: nil, count: self.vocabSize)
        }
        guard self.pieceCache.indices.contains(index) else {
            return self.uncachedTokenToPiece(token: token)
        }
        if let cached = self.pieceCache[index] {
            return cached
        }
        let piece = self.uncachedTokenToPiece(token: token)
        self.pieceCache[index] = piece
        return piece
    }

    private func uncachedTokenToPiece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(self.sharedModel.vocab, token, result, 8, 0, false)

        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(self.sharedModel.vocab, token, newResult, Int32(-nTokens), 0, false)
            let bufferPointer: UnsafeBufferPointer<Int8> = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer: UnsafeBufferPointer<Int8> = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}

/// リッチ評価のロジット行を、次のリッチ評価で使い回すために保持する
///
/// 行は位置 `record.logitsStart` の行を先頭に、`rowWidth` 個ずつ並ぶ (`llama_get_logits` と同じ並び)。
/// llama.cpp に依存しないため、単体で検証できる
///
/// - Note: [Hazkey Community Patch] A7
final class RichLogitsRowStore {
    /// 前回の行から使い回す範囲
    struct ReusedRows: Equatable {
        /// 前回の行の先頭の位置
        var previousLogitsStart: Int
        /// 使い回す行の数 (今回の開始位置から数える)
        var rowCount: Int
    }

    /// 1行あたりの値の数 (語彙数)
    let rowWidth: Int
    /// 保持している行の出所 (読ませたトークン列と、先頭の行の位置)
    private(set) var record: (tokens: [llama_token], logitsStart: Int)?
    /// 確保済みの領域の大きさ (Float の個数)
    private(set) var capacity = 0
    /// 領域の先頭から有効な値の数 (記録を取り出した後も、次の assemble までは前回の行として残る)
    private var validFloatCount = 0
    private var buffer: UnsafeMutablePointer<Float>?

    init(rowWidth: Int) {
        self.rowWidth = rowWidth
    }

    deinit {
        self.buffer?.deallocate()
    }

    /// 推論の開始時に決める、行の扱い
    struct InferenceStart: Equatable {
        /// 今回の行を保持するか (保持しない場合は llama_get_logits をそのまま使う)
        var keepsRows: Bool
        /// 前回の行を使い回す範囲 (nil なら使い回さない)
        var reusePlan: ZenzContext.RichLogitsReusePlan?
        /// 使い回す前回の行の先頭の位置 (使い回すときだけ値を持つ)
        var previousLogitsStart: Int?
    }

    /// 推論の開始時に、今回の行を保持するかと、前回の行を使い回せる範囲を決める
    ///
    /// 評価用シーケンスの推論はKVキャッシュを書き換えるため、記録を必ず捨てる (行は次の assemble まで領域に残る)。
    /// 入力予測用シーケンスの推論は評価用シーケンスを書き換えないため、記録を残す。
    /// 評価用シーケンスで行を保持しない推論 (リッチ評価でない、または使い回しが無効) では、領域も解放する
    ///
    /// - Parameters:
    ///   - isEvaluationSequence: 評価用シーケンスの推論か
    ///   - isRichEvaluation: リッチ評価か
    ///   - reuseEnabled: 使い回しが有効か
    ///   - kvTokens: このシーケンスのKVキャッシュに入っているトークン列 (前回読ませたトークン列)
    ///   - tokens: 今回読ませるトークン列
    ///   - logitsStart: 今回ロジットが必要な開始位置
    func beginInference(
        isEvaluationSequence: Bool,
        isRichEvaluation: Bool,
        reuseEnabled: Bool,
        kvTokens: [llama_token],
        tokens: [llama_token],
        logitsStart: Int
    ) -> InferenceStart {
        guard isEvaluationSequence else {
            return InferenceStart(keepsRows: false, reusePlan: nil, previousLogitsStart: nil)
        }
        let previous = self.record
        self.record = nil
        guard isRichEvaluation, reuseEnabled else {
            self.release()
            return InferenceStart(keepsRows: false, reusePlan: nil, previousLogitsStart: nil)
        }
        // 記録がKVキャッシュの内容と食い違う (別のシーケンスから写した、失敗で巻き戻したなど) ときは使い回さない
        guard let previous, previous.tokens == kvTokens,
              let plan = ZenzContext.richLogitsReusePlan(
                  previousTokens: previous.tokens,
                  previousLogitsStart: previous.logitsStart,
                  tokens: tokens,
                  logitsStart: logitsStart
              ) else {
            return InferenceStart(keepsRows: true, reusePlan: nil, previousLogitsStart: nil)
        }
        return InferenceStart(keepsRows: true, reusePlan: plan, previousLogitsStart: previous.logitsStart)
    }

    /// 記録と領域を捨てる
    func release() {
        self.buffer?.deallocate()
        self.buffer = nil
        self.capacity = 0
        self.validFloatCount = 0
        self.record = nil
    }

    /// 今回の行を、前回の行と今回計算した行から集める
    ///
    /// - Parameters:
    ///   - tokens: 今回読ませたトークン列
    ///   - logitsStart: 今回ロジットが必要な開始位置
    ///   - reusedRows: 前回の行から使い回す範囲 (nil なら使い回さない)
    ///   - freshRows: モデルが今回計算した行 (使い回した行の次の位置から並ぶ。全ての行を使い回すときは nil でよい)
    /// - Returns: 位置 `logitsStart` の行が先頭の領域。必要な行が無いときは nil (記録も捨てる)
    func assemble(
        tokens: [llama_token],
        logitsStart: Int,
        reusedRows: ReusedRows?,
        freshRows: UnsafePointer<Float>?
    ) -> UnsafeMutablePointer<Float>? {
        self.record = nil
        let rowCount = tokens.count - logitsStart
        let reusedRowCount = reusedRows?.rowCount ?? 0
        let shift = reusedRows.map { (logitsStart - $0.previousLogitsStart) * self.rowWidth } ?? 0
        let preservedFloatCount = reusedRowCount > 0 ? shift + reusedRowCount * self.rowWidth : 0
        // 前回の行が足りない、または今回計算した行が足りないときは集められない
        guard logitsStart >= 0, rowCount > 0, shift >= 0, (0...rowCount).contains(reusedRowCount),
              preservedFloatCount <= self.validFloatCount,
              reusedRowCount == rowCount || freshRows != nil else {
            self.validFloatCount = 0
            return nil
        }
        let buffer = self.reserve(floatCount: rowCount * self.rowWidth, preservedFloatCount: preservedFloatCount)
        if shift > 0, reusedRowCount > 0 {
            // 前回の行を今回の開始位置に合わせて先頭へ詰める (移動元と移動先が重なり得るため memmove)
            memmove(buffer, buffer + shift, reusedRowCount * self.rowWidth * MemoryLayout<Float>.stride)
        }
        if let freshRows, reusedRowCount < rowCount {
            (buffer + reusedRowCount * self.rowWidth).update(from: freshRows, count: (rowCount - reusedRowCount) * self.rowWidth)
        }
        self.validFloatCount = rowCount * self.rowWidth
        self.record = (tokens: tokens, logitsStart: logitsStart)
        return buffer
    }

    /// 必要な大きさの領域を用意する。確保し直すときは先頭の `preservedFloatCount` 個の値を写す
    private func reserve(floatCount: Int, preservedFloatCount: Int) -> UnsafeMutablePointer<Float> {
        if let buffer = self.buffer, self.capacity >= floatCount {
            return buffer
        }
        let newBuffer = UnsafeMutablePointer<Float>.allocate(capacity: floatCount)
        if let buffer = self.buffer {
            if preservedFloatCount > 0 {
                newBuffer.update(from: buffer, count: preservedFloatCount)
            }
            buffer.deallocate()
        }
        self.buffer = newBuffer
        self.capacity = floatCount
        return newBuffer
    }
}
