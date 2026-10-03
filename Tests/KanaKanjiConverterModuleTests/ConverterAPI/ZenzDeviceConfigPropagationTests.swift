@testable import KanaKanjiConverterModule
import XCTest

/// GPU装置設定がZenzaiモデル構築連鎖へ伝わることの回帰テストをまとめる
///
/// KanaKanjiConverterのgetModelからZenzの共有保持を経てモデル構築の差し替え口までの経路を検証する
///
/// 実際のllama.cppのモデル構築器であるSharedZenzModelのinitを差し替えるため、llama.cppや実モデルや実GPUには触れない
///
/// 偽構築器はSharedZenzModelの生成前に必ず失敗させ、呼び出しだけを完全に観測する
///
/// - Note: 装置設定APIは7ka-hiira/AzooKeyKanaKanjiConverterのcommit 8b4befcから移植した
final class ZenzDeviceConfigPropagationTests: XCTestCase {
    /// 構築の差し替え口へ到達したことを観測するための送出用エラー
    ///
    /// わざと失敗させてSharedZenzModelの生成を防ぐ
    private struct SentinelConstructionError: Error {}

    /// 偽構築器を製品の初期化子へ戻す
    ///
    /// 他のテストへ差し替えが漏れないようにする
    override func tearDown() {
        SharedZenzModelCache.modelConstructor = SharedZenzModel.init
        super.tearDown()
    }

    /// 明示のGPU設定が構築の差し替え口まで不変で届くことを検証する
    ///
    /// ConvertRequestOptionsのZenzaiModeに載せた装置設定を、製品の呼び出しと同じweightURLとdeviceConfigの取り出し口経由で渡す
    func testGetModelPropagatesExplicitGPUDeviceConfigToModelConstructionSeam() {
        var capturedCalls: [(path: String, deviceConfig: ZenzaiDeviceConfig)] = []
        SharedZenzModelCache.modelConstructor = { path, deviceConfig in
            capturedCalls.append((path, deviceConfig))
            throw SentinelConstructionError()
        }

        let modelURL = URL(fileURLWithPath: "/tmp/zenz-device-config-propagation-\(UUID().uuidString).gguf")
        let gpuConfig = ZenzaiDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99)
        let zenzaiMode = ConvertRequestOptions.ZenzaiMode.on(
            weight: modelURL,
            personalizationMode: nil,
            deviceConfig: gpuConfig
        )

        let converter = KanaKanjiConverter.withoutDictionary()
        let model = converter.getModel(modelURL: zenzaiMode.weightURL, deviceConfig: zenzaiMode.deviceConfig)

        XCTAssertNil(model, "the fake constructor always throws, so getModel must fail rather than return a model")
        XCTAssertEqual(capturedCalls.count, 1, "the model construction seam must be reached exactly once")
        XCTAssertEqual(capturedCalls.first?.path, modelURL.path)
        XCTAssertEqual(
            capturedCalls.first?.deviceConfig, gpuConfig,
            "the GPU device config supplied through ConvertRequestOptions.ZenzaiMode must reach the model construction seam unchanged"
        )
    }

    /// CPU専用設定がGPUへ格上げされずに届くことを検証する
    ///
    /// GPU未選択時の暗黙の既定が誤ってGPU扱いにならない
    func testGetModelPropagatesCPUDeviceConfigToModelConstructionSeam() {
        var capturedCalls: [(path: String, deviceConfig: ZenzaiDeviceConfig)] = []
        SharedZenzModelCache.modelConstructor = { path, deviceConfig in
            capturedCalls.append((path, deviceConfig))
            throw SentinelConstructionError()
        }

        let modelURL = URL(fileURLWithPath: "/tmp/zenz-device-config-propagation-\(UUID().uuidString).gguf")
        let cpuConfig = ZenzaiDeviceConfig(deviceName: "CPU", gpuLayers: 0)
        let zenzaiMode = ConvertRequestOptions.ZenzaiMode.on(
            weight: modelURL,
            personalizationMode: nil,
            deviceConfig: cpuConfig
        )

        let converter = KanaKanjiConverter.withoutDictionary()
        _ = converter.getModel(modelURL: zenzaiMode.weightURL, deviceConfig: zenzaiMode.deviceConfig)

        XCTAssertEqual(capturedCalls.count, 1)
        XCTAssertEqual(capturedCalls.first?.deviceConfig, cpuConfig)
        XCTAssertEqual(capturedCalls.first?.deviceConfig.gpuLayers, 0)
    }

    // MARK: - キャッシュの同一性と分離

    /// 同じ重みパスでも装置設定が違えばキャッシュを共有しないことを検証する
    ///
    /// 装置を切り替えたときに別装置向けのモデルを誤って再利用しない
    func testSharedZenzModelCacheKeySeparatesDeviceConfigsForSamePath() {
        let path = "/tmp/shared-zenz-model-cache-key-test.gguf"
        let cpuConfig = ZenzaiDeviceConfig(deviceName: nil, gpuLayers: 0)
        let gpuConfig = ZenzaiDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99)

        let cpuKey = SharedZenzModelCache.cacheKey(path: path, deviceConfig: cpuConfig)
        let gpuKey = SharedZenzModelCache.cacheKey(path: path, deviceConfig: gpuConfig)

        XCTAssertNotEqual(cpuKey, gpuKey, "CPU and GPU device configs for the same weight path must not share a cache identity")
        XCTAssertEqual(cpuKey, SharedZenzModelCache.cacheKey(path: path, deviceConfig: cpuConfig), "identical device configs must map to the same cache identity")
    }

    /// 外側のZenz層のキャッシュも同じ分離規則に従うことを検証する
    ///
    /// 資源URLをキーにする層でも装置設定ごとに別物として扱う
    func testSharedZenzCacheKeySeparatesDeviceConfigsForSameURL() {
        let url = URL(fileURLWithPath: "/tmp/shared-zenz-cache-key-test.gguf")
        let cpuConfig = ZenzaiDeviceConfig(deviceName: nil, gpuLayers: 0)
        let gpuConfig = ZenzaiDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99)

        let cpuKey = SharedZenzCache.cacheKey(resourceURL: url, deviceConfig: cpuConfig)
        let gpuKey = SharedZenzCache.cacheKey(resourceURL: url, deviceConfig: gpuConfig)

        XCTAssertNotEqual(cpuKey, gpuKey, "CPU and GPU device configs for the same model URL must not share a cache identity")
        XCTAssertEqual(cpuKey, SharedZenzCache.cacheKey(resourceURL: url, deviceConfig: cpuConfig), "identical device configs must map to the same cache identity")
    }

    /// 読み込み済みのZenzを装置設定が違う要求に再利用しないことを検証する
    ///
    /// 同じモデルURLでも装置設定が違えば作り直し、一致するときだけ再利用する
    ///
    /// getModelの個体層の近道判定から抜き出した純粋述語で検証するため、実際のllama.cpp文脈は要らない
    func testZenzCanReuseRejectsMismatchedDeviceConfigForSameURL() {
        let url = URL(fileURLWithPath: "/tmp/zenz-instance-cache-test.gguf")
        let cpuConfig = ZenzaiDeviceConfig(deviceName: nil, gpuLayers: 0)
        let gpuConfig = ZenzaiDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99)

        XCTAssertFalse(
            Zenz.canReuse(cachedURL: url, cachedDeviceConfig: cpuConfig, requestedURL: url, requestedDeviceConfig: gpuConfig),
            "a CPU-loaded model must not be reused for a GPU device-config request"
        )
        XCTAssertTrue(
            Zenz.canReuse(cachedURL: url, cachedDeviceConfig: gpuConfig, requestedURL: url, requestedDeviceConfig: gpuConfig),
            "identical URL and device config must be reusable"
        )
    }
}
