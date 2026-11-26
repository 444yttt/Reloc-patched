import Foundation
import RelocDeviceBridge
import SwiftUI
import UIKit

private final class DevicePairingContext {
    weak var owner: DevicePairingCoordinator?
    let session: UUID

    init(owner: DevicePairingCoordinator, session: UUID) {
        self.owner = owner
        self.session = session
    }
}

private let devicePairingEventCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pointer, context in
    guard let pointer, let context else { return }
    let text = String(cString: pointer)
    DispatchQueue.main.async {
        let box = Unmanaged<DevicePairingContext>.fromOpaque(context).takeUnretainedValue()
        let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        box.owner?.receive(event, session: box.session)
        if ["completed", "failed", "cancelled"].contains(event["type"] as? String ?? "") {
            Unmanaged<DevicePairingContext>.fromOpaque(context).release()
        }
    }
}

/// On-device iOS 27 Remote Pairing responder with PiP floating live guide and background keep-alive.
@MainActor
final class DevicePairingCoordinator: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = DevicePairingCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var stepIndex = 0 // 0=idle, 1=broadcasting, 2=connected/pin, 3=completed
    @Published private(set) var status = "デバイスのペアリングはまだ始まっていません"
    @Published private(set) var pin: String?
    @Published private(set) var error: String?

    private var service: NetService?
    private var handle: UInt64 = 0
    private var session: UUID?
    private var cancelReason: String?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var onSaveRecord: ((Data, Data, String) throws -> Void)?
    private let pip = PairingPiPPresenter.shared
    private let keepAlive = BackgroundKeepAlive()

    func start(onSaveRecord: @escaping (Data, Data, String) throws -> Void) {
        guard !isRunning else { return }
        #if targetEnvironment(simulator)
        error = "このiPhone上でのペアリングには、iOS 27以降の実機が必要です。"
        status = error ?? ""
        return
        #else
        guard #available(iOS 27.0, *) else {
            error = "このOSでは既存のペアリングファイルを読み込んでください。本体での直接ペアリングには iOS 27 が必要です。"
            status = error ?? ""
            return
        }

        self.onSaveRecord = onSaveRecord
        let id = UUID()
        session = id
        isRunning = true
        stepIndex = 1
        pin = nil
        error = nil
        cancelReason = nil
        status = "このiPhoneのペアリングサービスを準備しています…"

        let deadline = Date().addingTimeInterval(300)
        keepAlive.start(useSilentAudio: true)
        pip.startSession(deadline: deadline)

        do {
            let request: [String: Any] = [:]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            background = UIApplication.shared.beginBackgroundTask(withName: "Reloc Device Pairing") { [weak self] in
                Task { @MainActor in
                    self?.cancel(reason: "システムのバックグラウンド時間が終了しました。Relocに戻ってもう一度試してください。")
                }
            }
            let context = Unmanaged.passRetained(DevicePairingContext(owner: self, session: id)).toOpaque()
            handle = json.withCString { rl_device_pairing_start($0, devicePairingEventCallback, context) }
            if handle == 0 {
                Unmanaged<DevicePairingContext>.fromOpaque(context).release()
                finish(error: "デバイスのペアリングサービスを起動できません。")
            }
        } catch {
            finish(error: error.localizedDescription)
        }
        #endif
    }

    func toggleFloatingGuide() {
        pip.togglePiP()
    }

    func cancel(reason: String? = nil) {
        cancelReason = reason
        service?.stop()
        service = nil
        if handle != 0 {
            rl_device_pairing_cancel(handle)
        } else {
            finish(error: reason)
        }
    }

    fileprivate func receive(_ event: [String: Any], session id: UUID) {
        guard session == id else { return }
        switch event["type"] as? String {
        case "ready":
            guard let identifier = event["identifier"] as? String,
                  let port = event["port"] as? Int,
                  (1...65535).contains(port),
                  let txt = event["txt"] as? [String: String] else {
                cancel(reason: "ペアリングサービスが無効なブロードキャストパラメータを返しました。")
                return
            }
            let netService = NetService(
                domain: "local.",
                type: "_remotepairing-pairable-host._tcp.",
                name: identifier,
                port: Int32(port)
            )
            netService.delegate = self
            netService.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
            self.service = netService
            netService.publish()
            stepIndex = 1
            status = "「設定 → プライバシーとセキュリティ → デベロッパモード」を開き、一番下の「Relocとペアリング」を選んでください。"
            pip.update(
                step: 1,
                headline: "① 設定 → プライバシーとセキュリティ → デベロッパモード",
                subtitle: "一番下の「Relocとペアリング」をタップすると、ペアリングコードがここに表示されます"
            )

        case "connected":
            stepIndex = 2
            status = "システムが接続されました。ペアリングコードを生成しています…"
            pip.update(
                step: 2,
                headline: "② システムが接続されました",
                subtitle: "安全なチャネルを確立し、6桁のペアリングコードを生成しています…"
            )

        case "pin":
            guard let pin = event["pin"] as? String else { return }
            self.pin = pin
            stepIndex = 2
            status = "システム設定に、次の6桁のペアリングコードを入力してください。"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            pip.update(
                step: 2,
                headline: "ペアリングコードを入力",
                subtitle: "システムの設定ダイアログに6桁のペアリングコードを入力してください",
                pin: pin
            )

        case "completed":
            guard let encoded = event["record"] as? String,
                  let record = Data(base64Encoded: encoded),
                  let irk = (event["host_irk"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  irk.count == 16,
                  let save = onSaveRecord else {
                finish(error: "システムが完全なペアリング記録を返しませんでした。")
                return
            }
            let udid = event["udid"] as? String ?? ""
            do {
                try save(record, irk, udid)
                stepIndex = 3
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                finish(error: nil, succeeded: true)
                status = "ペアリング記録を自動保存しました"
            } catch {
                finish(error: error.localizedDescription)
            }

        case "failed":
            finish(error: event["error"] as? String ?? "デバイスのペアリングが完了しませんでした。")

        case "cancelled":
            finish(error: cancelReason)

        default:
            break
        }
    }

    private func finish(error: String?, succeeded: Bool = false) {
        self.error = error
        status = error ?? (succeeded ? "ペアリング記録を自動保存しました" : "ペアリングを終了しました")
        isRunning = false
        stepIndex = succeeded ? 3 : 0
        pin = nil
        handle = 0
        session = nil
        onSaveRecord = nil
        service?.delegate = nil
        service?.stop()
        service = nil
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        keepAlive.stop()
        let finalMessage = error ?? (succeeded ? "ペアリングが完了しました。Relocに戻って位置情報を開始できます" : "ペアリングを終了しました")
        pip.finish(succeeded: succeeded, message: finalMessage)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        cancel(reason: "ペアリングサービスを公開できません（エラーコード \(code)）。「設定 → プライバシーとセキュリティ → ローカルネットワーク」で Reloc のアクセスを許可してから、もう一度試してください。")
    }
}
