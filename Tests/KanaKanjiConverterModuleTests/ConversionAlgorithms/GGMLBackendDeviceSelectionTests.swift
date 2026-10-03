@testable import KanaKanjiConverterModule
import XCTest

/// resolveDeviceConfigの回帰テストをまとめる
///
/// 実際の振り分け先であるcreateDeviceConfigの背後にある純粋な分類処理だけを検証する
///
/// llama.cppのVulkanバックエンドは統合GPUをGGML_BACKEND_DEVICE_TYPE_IGPUとして報告する
///
/// 専用メモリを持つGGML_BACKEND_DEVICE_TYPE_GPUとは別種別だが、どちらもモデルの層をオフロードできる
///
/// 実GPUやllama.cppには触れず、GGMLBackendDeviceの単純な初期化子で合成デバイスを作って検証する
///
/// - Note: 装置設定APIは7ka-hiira/AzooKeyKanaKanjiConverterのcommit 8b4befcから移植した
///
/// - Note: .igpuのGPU扱いはcommit 38ef2faによるpresire独自の拡張である
final class GGMLBackendDeviceSelectionTests: XCTestCase {
    /// 名前指定した統合GPUが要求どおりの層数を受け取ることを検証する
    ///
    /// AMD APUなどの統合GPUはホストメモリを使うが、専用GPUと同様にオフロード可能である
    func testResolveDeviceConfigTreatsIntegratedGPUAsGPUCapable() {
        let devices = [
            GGMLBackendDevice(name: "Vulkan0", description: "AMD Radeon Graphics (RADV RAPHAEL_MENDOCINO)", type: .igpu),
            GGMLBackendDevice(name: "CPU", description: "AMD Ryzen 9 9900X 12-Core Processor", type: .cpu),
        ]

        let config = resolveDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99, devices: devices)

        XCTAssertEqual(config.deviceName, "Vulkan0")
        XCTAssertEqual(config.gpuLayers, 99, "an integrated GPU selected by name must receive the requested GPU layer count, not be forced to 0")
    }

    /// 名前指定した専用GPUが要求どおりの層数を受け取ることを検証する
    ///
    /// 統合GPUとの対照として、従来のGPU種別も変わらずGPU扱いになる
    func testResolveDeviceConfigTreatsDedicatedGPUAsGPUCapable() {
        let devices = [
            GGMLBackendDevice(name: "Vulkan0", description: "NVIDIA GeForce RTX", type: .gpu),
            GGMLBackendDevice(name: "CPU", description: "Generic CPU", type: .cpu),
        ]

        let config = resolveDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99, devices: devices)

        XCTAssertEqual(config.deviceName, "Vulkan0")
        XCTAssertEqual(config.gpuLayers, 99)
    }

    /// CPU種別のデバイスでは層数が0に強制されることを検証する
    ///
    /// CPUに層を載せる指定でも推論には使えないため、層数要求を無視する
    func testResolveDeviceConfigForcesZeroLayersForCPUDevice() {
        let devices = [
            GGMLBackendDevice(name: "CPU", description: "Generic CPU", type: .cpu),
        ]

        let config = resolveDeviceConfig(deviceName: "CPU", gpuLayers: 99, devices: devices)

        XCTAssertEqual(config.deviceName, "CPU")
        XCTAssertEqual(config.gpuLayers, 0)
    }

    /// 分類不能と加速器種別でも層数が0に強制されることを検証する
    ///
    /// GPUでも統合GPUでもない装置へ層を割り当てない
    func testResolveDeviceConfigForcesZeroLayersForUnknownOrAccelDeviceType() {
        let devices = [
            GGMLBackendDevice(name: "Weird0", description: "Unclassified device", type: .unknown),
            GGMLBackendDevice(name: "Accel0", description: "BLAS accelerator", type: .accel),
        ]

        XCTAssertEqual(resolveDeviceConfig(deviceName: "Weird0", gpuLayers: 99, devices: devices).gpuLayers, 0)
        XCTAssertEqual(resolveDeviceConfig(deviceName: "Accel0", gpuLayers: 99, devices: devices).gpuLayers, 0)
    }

    /// 存在しないデバイス名ではCPUへフォールバックすることを検証する
    ///
    /// 指定名が一覧に無いときは利用可能なCPU装置を選び、層数は0にする
    func testResolveDeviceConfigFallsBackToCPUWhenRequestedDeviceNameIsAbsent() {
        let devices = [
            GGMLBackendDevice(name: "Vulkan0", description: "Some GPU", type: .igpu),
            GGMLBackendDevice(name: "CPU", description: "Generic CPU", type: .cpu),
        ]

        let config = resolveDeviceConfig(deviceName: "Vulkan9-does-not-exist", gpuLayers: 99, devices: devices)

        XCTAssertEqual(config.deviceName, "CPU")
        XCTAssertEqual(config.gpuLayers, 0)
    }

    /// 装置が空のときは装置名なしで層数0を返すことを検証する
    ///
    /// 列挙に失敗した環境でも呼び出し側がCPU専用として続けられる
    func testResolveDeviceConfigReturnsNilDeviceWhenNoDevicesEnumerated() {
        let config = resolveDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99, devices: [])

        XCTAssertNil(config.deviceName)
        XCTAssertEqual(config.gpuLayers, 0)
    }
}
