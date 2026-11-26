import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Redesigned loopback & on-device pairing configuration (preserving the Reukix/retools 3-step structure
/// without any MFi identity UI) + PiP floating pairing guide + Roam-Control-style preferences.
struct ConfigurationView: View {
    @ObservedObject var viewModel: RelocViewModel
    @ObservedObject private var pairing = DevicePairingCoordinator.shared
    @ObservedObject private var pip = PairingPiPPresenter.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showImporter = false
    @State private var copiedPinToast = false

    private var serviceStateText: String {
        if viewModel.connectionVerified { return "接続済み" }
        if viewModel.isVerifyingConnection { return "確認中" }
        return viewModel.connectionCheckFailed ? "接続失敗" : "未確認"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    heroHeaderCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }

                Section {
                    HStack(spacing: 12) {
                        SettingsIconBadge(systemName: "network", color: RelocTheme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("外部プロキシがループバックを提供します")
                                .font(.subheadline.weight(.semibold))
                            Text("先にプロキシ側で \(viewModel.host) のループバックを有効にしてから、下のペアリングと確認を行ってください。Reloc は VPN を作りません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    stepSectionHeader(number: "01", title: "ループバック経路")
                }

                Section {
                    HStack {
                        SettingsIconBadge(
                            systemName: viewModel.pairingStatus.isLoaded ? "checkmark.seal.fill" : "iphone.radiowaves.left.and.right",
                            color: viewModel.pairingStatus.isLoaded ? RelocTheme.emerald : RelocTheme.amber
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ペアリング記録")
                                .font(.subheadline.weight(.medium))
                            Text(viewModel.pairingStatus.isLoaded
                                 ? "保存済み（\(viewModel.pairingStatus.kind?.rawValue ?? "")）"
                                 : "このiPhoneはまだ設定されていません")
                                .font(.caption)
                                .foregroundStyle(viewModel.pairingStatus.isLoaded ? RelocTheme.emerald : .secondary)
                        }
                        Spacer()
                    }

                    if #available(iOS 27.0, *) {
                        if !pairing.isRunning {
                            Button {
                                RelocTheme.hapticMedium()
                                viewModel.startDevicePairing()
                            } label: {
                                HStack {
                                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                                        .font(.subheadline.weight(.semibold))
                                    Text(viewModel.pairingStatus.isLoaded ? "このiPhoneを再ペアリング" : "このiPhoneをワンタップでペアリング")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("フローティングガイド")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(RelocTheme.accent.opacity(0.14), in: Capsule())
                                }
                            }
                            .disabled(viewModel.isVerifyingConnection || viewModel.snapshot.isRunning)
                        }
                    } else {
                        Text("このOSバージョンでは、既存のペアリングファイルを読み込んでください。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if pairing.isRunning || pairing.error != nil {
                        activePairingGuideCard
                    }

                    Button {
                        showImporter = true
                    } label: {
                        Label("既存のペアリングファイルを読み込む", systemImage: "square.and.arrow.down")
                    }
                    .disabled(pairing.isRunning || viewModel.isVerifyingConnection || viewModel.snapshot.isRunning)

                    if viewModel.pairingStatus.isLoaded {
                        Button("保存したペアリング記録を削除", role: .destructive) {
                            viewModel.removePairingFile()
                        }
                        .disabled(pairing.isRunning || viewModel.isVerifyingConnection || viewModel.snapshot.isRunning)
                    }
                } header: {
                    stepSectionHeader(number: "02", title: "デバイスペアリング")
                } footer: {
                    Text("ペアリングを始めると、ピクチャ・イン・ピクチャのガイドが表示されます。「設定 → プライバシーとセキュリティ → デベロッパモード」で「Relocとペアリング」をタップすると、フローティングウィンドウに6桁のコードがリアルタイムで出ます。")
                }

                Section {
                    HStack(spacing: 10) {
                        if viewModel.isVerifyingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            SettingsIconBadge(
                                systemName: viewModel.connectionVerified
                                    ? "checkmark"
                                    : (viewModel.connectionCheckFailed ? "exclamationmark" : "link"),
                                color: viewModel.connectionVerified
                                    ? RelocTheme.emerald
                                    : (viewModel.connectionCheckFailed ? RelocTheme.amber : .secondary)
                            )
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.deviceConnectionStatus)
                                .font(.subheadline.weight(.medium))
                                .textSelection(.enabled)
                            if let port = viewModel.discoveredDevicePort {
                                Text("ループバックポートに接続済み：\(port)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button {
                        RelocTheme.hapticLight()
                        viewModel.testConnection(silent: false)
                    } label: {
                        Label(
                            viewModel.connectionVerified ? "接続を再確認" : "デバイス接続を確認",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(!viewModel.pairingStatus.isLoaded || viewModel.isVerifyingConnection || pairing.isRunning || viewModel.snapshot.isRunning)

                    if !viewModel.deviceUDID.isEmpty {
                        LabeledContent("デバイス UDID") {
                            Text(viewModel.deviceUDID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    stepSectionHeader(number: "03", title: "接続の確認")
                } footer: {
                    Text("Remote Pairing サービスを自動検出し、ペアリング記録で広告の識別情報を確かめたあと、デバイスサービスで接続できることを確認します。")
                }

                Section {
                    Stepper(value: $viewModel.intervalSeconds, in: 1.0...10.0, step: 0.5) {
                        Label {
                            Text(String(format: "NMEA 送信間隔 · %.1f 秒", viewModel.intervalSeconds))
                                .monospacedDigit()
                        } icon: {
                            SettingsIconBadge(systemName: "timer", color: RelocTheme.accent)
                        }
                    }

                    Picker(selection: $viewModel.durationSeconds) {
                        Text("連続動作").tag(0.0)
                        Text("60 秒").tag(60.0)
                        Text("180 秒").tag(180.0)
                        Text("600 秒").tag(600.0)
                        Text("1800 秒").tag(1800.0)
                    } label: {
                        Label {
                            Text("セッション時間")
                        } icon: {
                            SettingsIconBadge(systemName: "hourglass", color: .purple)
                        }
                    }

                    Toggle(isOn: $viewModel.gcj02CorrectionEnabled) {
                        Label {
                            Text("中国本土マップの GCJ-02 補正")
                        } icon: {
                            SettingsIconBadge(systemName: "globe.asia.australia.fill", color: RelocTheme.emerald)
                        }
                    }

                    Picker(selection: $viewModel.gradualMoveMode) {
                        ForEach(GradualMoveMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    } label: {
                        Label {
                            Text("移動モード")
                        } icon: {
                            SettingsIconBadge(systemName: "arrow.triangle.swap", color: RelocTheme.accent)
                        }
                    }

                    Toggle(isOn: $viewModel.microJitterEnabled) {
                        Label {
                            Text("自然な微小ドリフト（±0.6m のGPS揺れ）")
                        } icon: {
                            SettingsIconBadge(systemName: "dot.radiowaves.left.and.right", color: RelocTheme.amber)
                        }
                    }

                    Toggle(isOn: $viewModel.backgroundKeepAliveEnabled) {
                        Label {
                            Text("バックグラウンド維持（マップを切り替えても切断しない）")
                        } icon: {
                            SettingsIconBadge(systemName: "bolt.shield.fill", color: .teal)
                        }
                    }
                } header: {
                    Text("位置情報の設定")
                } footer: {
                    Text("遠距離へ一度に飛ぶとシステムに弾かれることがあります。段階移動は現在地から目標まで、指定の速度で滑らかに進みます。")
                }

                Section {
                    Picker(selection: $viewModel.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    } label: {
                        Label {
                            Text("外観テーマ")
                        } icon: {
                            SettingsIconBadge(systemName: "circle.lefthalf.filled", color: .gray)
                        }
                    }

                    Picker(selection: $viewModel.mapSource) {
                        ForEach(MapSource.allCases) { src in
                            Text(src.title).tag(src)
                        }
                    } label: {
                        Label {
                            Text("地図データソース")
                        } icon: {
                            SettingsIconBadge(systemName: "globe.americas.fill", color: RelocTheme.accent)
                        }
                    }

                    if viewModel.mapSource == .appleNative {
                        Picker(selection: $viewModel.mapStyle) {
                            ForEach(MapDisplayStyle.allCases) { s in
                                Text(s.title).tag(s)
                            }
                        } label: {
                            Label {
                                Text("Appleマップのスタイル")
                            } icon: {
                                SettingsIconBadge(systemName: "map.fill", color: RelocTheme.accent)
                            }
                        }
                    }
                } header: {
                    Text("地図と外観")
                } footer: {
                    Text("初期設定はシステムの Appleマップ（純正 MapKit）です。高徳表記のない国際WGS-84地図が必要なときは、世界街道図、OpenStreetMap、世界衛星図に切り替えられます。")
                }
            }
            .navigationTitle("デバイスのペアリングと接続")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                viewModel.importDiscoveredPairing()
                await viewModel.verifyConnectionIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    viewModel.importDiscoveredPairing()
                    Task {
                        await viewModel.verifyConnectionIfNeeded()
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
                PairingDocumentPicker(
                    onPick: { url in
                        showImporter = false
                        viewModel.importPairingFile(url: url)
                    },
                    onCancel: {
                        showImporter = false
                    }
                )
                .ignoresSafeArea()
            }
        }
    }

    private var heroHeaderCard: some View {
        let ready = viewModel.connectionVerified
        let accent: Color = ready ? RelocTheme.emerald : (viewModel.pairingStatus.isLoaded ? RelocTheme.amber : RelocTheme.accent)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: ready ? "checkmark.shield.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(ready ? "デバイスのループバックは準備完了です" : "このiPhoneのループバック接続を設定")
                        .font(.headline)
                    Text(ready ? "「位置情報」タブに戻って、位置の固定を始められます" : "ループバック経路、このiPhoneのペアリング、接続確認の順に進めてください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                MetricTile(
                    title: "ペアリング状態",
                    value: viewModel.pairingStatus.isLoaded ? "保存済み" : "未設定",
                    tint: viewModel.pairingStatus.isLoaded ? RelocTheme.emerald : .secondary
                )
                MetricTile(
                    title: "デバイスサービス",
                    value: serviceStateText,
                    tint: ready ? RelocTheme.emerald : (viewModel.connectionCheckFailed ? RelocTheme.amber : .secondary)
                )
                MetricTile(
                    title: "ループバックホスト",
                    value: viewModel.host,
                    tint: RelocTheme.accent
                )
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accent.opacity(0.25), lineWidth: 1)
        )
    }

    private var activePairingGuideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pairing.isRunning {
                HStack(spacing: 6) {
                    pairingStepPill(num: 1, title: "広告の準備完了", active: pairing.stepIndex >= 1, current: pairing.stepIndex == 1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    pairingStepPill(num: 2, title: "ペアリングコードを入力", active: pairing.stepIndex >= 2, current: pairing.stepIndex == 2)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    pairingStepPill(num: 3, title: "保存が完了しました", active: pairing.stepIndex >= 3, current: pairing.stepIndex == 3)
                }
            }

            Text(pairing.status)
                .font(.footnote.weight(.medium))
                .foregroundStyle(pairing.error != nil ? RelocTheme.crimson : .primary)
                .textSelection(.enabled)

            if let pin = pairing.pin {
                let chars = Array(pin)
                HStack(spacing: 6) {
                    ForEach(Array(chars.enumerated()), id: \.offset) { idx, ch in
                        Text(String(ch))
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(RelocTheme.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(RelocTheme.amber.opacity(0.45), lineWidth: 1)
                            )
                        if idx == 2 && chars.count == 6 {
                            Spacer().frame(width: 4)
                        }
                    }
                }

                Button {
                    UIPasteboard.general.string = pin
                    RelocTheme.hapticLight()
                    copiedPinToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedPinToast = false }
                } label: {
                    Label(copiedPinToast ? "ペアリングコードをコピーしました" : "ペアリングコードをコピー", systemImage: copiedPinToast ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RelocTheme.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelocTheme.amber)
            }

            if pairing.isRunning {
                if pip.isSupported {
                    Button {
                        RelocTheme.hapticLight()
                        pairing.toggleFloatingGuide()
                    } label: {
                        Label(pip.isActive ? "フローティングガイドを閉じる" : "フローティングガイドを表示", systemImage: pip.isActive ? "pip.exit" : "pip.enter")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RelocTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelocTheme.accent)
                }

                Button("ペアリングをキャンセル", role: .destructive) {
                    pairing.cancel()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RelocTheme.crimson)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private func pairingStepPill(num: Int, title: String, active: Bool, current: Bool) -> some View {
        HStack(spacing: 4) {
            Text("\(num)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 16, height: 16)
                .background(active ? RelocTheme.accent : Color.secondary.opacity(0.25), in: Circle())
                .foregroundStyle(active ? .white : .secondary)
            Text(title)
                .font(.system(size: 11, weight: current ? .bold : .medium))
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(current ? RelocTheme.accent.opacity(0.14) : Color.clear, in: Capsule())
    }

    private func stepSectionHeader(number: String, title: String) -> some View {
        HStack(spacing: 6) {
            Text(number)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RelocTheme.accent.opacity(0.15), in: Capsule())
                .foregroundStyle(RelocTheme.accent)
            Text(title)
                .font(.caption.weight(.bold))
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// Native UIDocumentPicker wrapper using `forOpeningContentTypes: [.item], asCopy: true`
/// so custom extensions (`.rppairing`, `.mobiledevicepairing`, `.mobilepair`, `.plist`, or
/// extensionless files) from Files / Downloads / iCloud / WeChat are never greyed out.
private struct PairingDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            } else {
                onCancel()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
