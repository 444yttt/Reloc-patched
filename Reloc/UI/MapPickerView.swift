import CoreLocation
import MapKit
import SwiftUI

struct MapPickerView: View {
    @ObservedObject var viewModel: RelocViewModel
    @ObservedObject private var coreLocation: LiveCoreLocationMonitor
    @Environment(\.colorScheme) private var colorScheme
    let switchToConfig: () -> Void

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var cameraTarget: CLLocationCoordinate2D?
    @State private var showManualCoordinate = false
    @State private var showPlacesSheet = false
    @State private var showStopConfirm = false
    @State private var copiedAddressToast = false

    init(viewModel: RelocViewModel, switchToConfig: @escaping () -> Void) {
        self.viewModel = viewModel
        self._coreLocation = ObservedObject(wrappedValue: viewModel.coreLocation)
        self.switchToConfig = switchToConfig
    }

    var body: some View {
        ZStack(alignment: .top) {
            if viewModel.mapSource.isPureWGS84 {
                WebMercatorMapView(
                    activeCoordinate: viewModel.activeMapCoordinate,
                    isSessionRunning: viewModel.snapshot.isRunning,
                    pendingCoordinate: viewModel.pendingMapCoordinate,
                    mapSource: viewModel.mapSource,
                    cameraTarget: $cameraTarget,
                    onTapCoordinate: { coord in
                        RelocTheme.hapticLight()
                        viewModel.selectLocationFromMap(coord)
                    }
                )
                .ignoresSafeArea()
            } else {
                InteractiveMKMapView(
                    activeCoordinate: viewModel.activeMapCoordinate,
                    isSessionRunning: viewModel.snapshot.isRunning,
                    pendingCoordinate: viewModel.pendingMapCoordinate,
                    mapSource: viewModel.mapSource,
                    mapStyle: viewModel.mapStyle,
                    isDarkMode: colorScheme == .dark,
                    cameraTarget: $cameraTarget,
                    onTapCoordinate: { coord in
                        RelocTheme.hapticLight()
                        viewModel.selectLocationFromMap(coord)
                    }
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                searchBar
                if !searchResults.isEmpty {
                    searchResultsList
                }
                topStatusRow

                if let interrupted = viewModel.interruptedSession, !viewModel.snapshot.isRunning {
                    interruptedRecoveryBanner(interrupted)
                }

                Spacer()

                HStack {
                    Spacer()
                    rightControlDock
                }

                fixedLocationCard
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.top, 8)
        }
        .toolbarBackground(.hidden, for: .tabBar)
        .sheet(isPresented: $showManualCoordinate) {
            ManualCoordinateSheet(viewModel: viewModel) { coord in
                cameraTarget = coord
            }
        }
        .sheet(isPresented: $showPlacesSheet) {
            PlacesSheet(viewModel: viewModel) { coord in
                cameraTarget = coord
            }
        }
        .confirmationDialog("位置情報を停止して、実際の位置に戻しますか？", isPresented: $showStopConfirm, titleVisibility: .visible) {
            Button("停止して戻す", role: .destructive) {
                RelocTheme.hapticMedium()
                viewModel.stopAndRestore()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("停止すると、システムは徐々にこのiPhone本来のGPS位置へ戻します。")
        }
    }

    // MARK: - Top Search Bar & Status Row

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RelocTheme.accent)

            TextField("場所を検索するか、緯度, 経度を入力", text: $searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { performSearch() }

            if isSearching {
                ProgressView().controlSize(.small)
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    RelocTheme.hapticLight()
                    showManualCoordinate = true
                } label: {
                    Image(systemName: "number.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("座標を手入力")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var topStatusRow: some View {
        HStack(spacing: 8) {
            Button(action: switchToConfig) {
                HStack(spacing: 7) {
                    PulsingStatusDot(
                        color: statusDotColor,
                        isPulsing: viewModel.snapshot.isRunning
                    )
                    Text(statusPillTitle)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
            }

            Spacer()

            if viewModel.snapshot.isRunning {
                HStack(spacing: 5) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(RelocTheme.emerald)
                    Text(String(format: "%.4f, %.4f", viewModel.targetLocation.latitude, viewModel.targetLocation.longitude))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
            }
        }
    }

    private var rightControlDock: some View {
        VStack(spacing: 10) {
            MapHUDIconButton(systemName: "bookmark.fill") {
                showPlacesSheet = true
            }

            Menu {
                Section("地図データソース") {
                    ForEach(MapSource.allCases) { source in
                        Button {
                            viewModel.mapSource = source
                        } label: {
                            Label(source.shortTitle, systemImage: viewModel.mapSource == source ? "checkmark" : "globe")
                        }
                    }
                }
                if viewModel.mapSource == .appleNative {
                    Section("Appleマップのスタイル") {
                        ForEach(MapDisplayStyle.allCases) { style in
                            Button {
                                viewModel.mapStyle = style
                            } label: {
                                Label(style.title, systemImage: viewModel.mapStyle == style ? "checkmark" : "map")
                            }
                        }
                    }
                }
                Section("座標") {
                    Button { showManualCoordinate = true } label: {
                        Label("緯度経度を手入力", systemImage: "number")
                    }
                }
            } label: {
                Image(systemName: "map.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            }

            MapHUDIconButton(systemName: viewModel.snapshot.isRunning ? "scope" : "location.fill") {
                if !viewModel.snapshot.isRunning, let real = viewModel.coreLocation.latest {
                    cameraTarget = viewModel.toMapCoordinate(CLLocationCoordinate2D(latitude: real.latitude, longitude: real.longitude))
                } else {
                    viewModel.coreLocation.requestOneShot()
                    cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
                }
            }
        }
    }

    private var statusDotColor: Color {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            return RelocTheme.emerald
        case .injectingPendingLock, .waitingSubscription:
            return viewModel.needsLocationServiceRefresh ? RelocTheme.amber : RelocTheme.accent
        case .connecting:
            return RelocTheme.amber
        case .idle:
            if viewModel.connectionVerified { return RelocTheme.emerald }
            return viewModel.pairingStatus.isLoaded ? RelocTheme.accent : RelocTheme.crimson
        }
    }

    private var statusPillTitle: String {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            if viewModel.isGradualMoving {
                return "段階移動中（\(viewModel.gradualMoveRemainingText)）"
            }
            return "外部位置情報が有効です ✓"
        case .injectingPendingLock:
            if viewModel.isGradualMoving {
                return "段階移動中（\(viewModel.gradualMoveRemainingText)）· ACK \(viewModel.snapshot.packetsAcknowledged)"
            }
            return viewModel.needsLocationServiceRefresh
                ? "更新待ち · ACK \(viewModel.snapshot.packetsAcknowledged)"
                : "位置を切り替え中 · ACK \(viewModel.snapshot.packetsAcknowledged)"
        case .waitingSubscription:
            return "認証済み · 購読を起こしています…"
        case .connecting:
            return "ループバック接続を確立しています…"
        case .idle:
            if viewModel.connectionVerified { return "ループバックは準備完了です" }
            return viewModel.pairingStatus.isLoaded ? "ペアリング済み · ワンタップで位置情報を開始できます" : "未ペアリング"
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(searchResults.prefix(6).enumerated()), id: \.offset) { _, item in
                    Button {
                        RelocTheme.hapticLight()
                        let coord = item.placemark.coordinate
                        viewModel.selectSearchResultCoordinate(coord, name: item.name, address: item.placemark.title)
                        cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
                        searchResults = []
                        searchText = ""
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(RelocTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "不明な場所")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if let title = item.placemark.title {
                                    Text(title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    Divider().padding(.leading, 40)
                }
            }
        }
        .frame(maxHeight: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    }

    private func interruptedRecoveryBanner(_ record: InterruptedSessionRecord) -> some View {
        HStack(spacing: 10) {
            SettingsIconBadge(systemName: "arrow.counterclockwise", color: RelocTheme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("前回の位置情報セッションが予期せず中断されました")
                    .font(.caption.weight(.bold))
                Text("前回の位置を復元：\(record.placeName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("復元") {
                RelocTheme.hapticMedium()
                viewModel.resumeInterruptedSession()
                cameraTarget = viewModel.activeMapCoordinate
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RelocTheme.amber, in: Capsule())
            .foregroundStyle(.white)

            Button {
                viewModel.dismissInterruptedSession()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(RelocTheme.amber.opacity(0.35), lineWidth: 0.8))
    }

    // MARK: - Bottom Fixed Location Card

    private var sheetGrabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
    }

    private var fixedLocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sheetGrabber

            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((viewModel.pendingLocation != nil ? RelocTheme.amber : (viewModel.snapshot.isRunning ? RelocTheme.emerald : RelocTheme.accent)).opacity(0.16))
                        .frame(width: 42, height: 42)
                    Image(systemName: viewModel.pendingLocation != nil ? "mappin.and.ellipse" : (viewModel.snapshot.isRunning ? "location.fill" : "mappin.circle.fill"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(viewModel.pendingLocation != nil ? RelocTheme.amber : (viewModel.snapshot.isRunning ? RelocTheme.emerald : RelocTheme.accent))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedPlaceName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(viewModel.selectedPlaceAddress.isEmpty
                             ? String(format: "%.5f, %.5f", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude)
                             : viewModel.selectedPlaceAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button {
                            let text = "\(viewModel.selectedPlaceName) (\(String(format: "%.6f, %.6f", viewModel.inspectedLocation.latitude, viewModel.inspectedLocation.longitude)))"
                            UIPasteboard.general.string = text
                            RelocTheme.hapticLight()
                            copiedAddressToast = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedAddressToast = false }
                        } label: {
                            Image(systemName: copiedAddressToast ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(copiedAddressToast ? RelocTheme.emerald : RelocTheme.accent)
                        }
                    }
                }

                Spacer()

                Button {
                    RelocTheme.hapticLight()
                    viewModel.toggleFavoriteForInspected()
                } label: {
                    Image(systemName: viewModel.isCurrentInspectedFavorite ? "heart.fill" : "heart")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(viewModel.isCurrentInspectedFavorite ? .pink : .secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }

                if viewModel.pendingLocation != nil {
                    Button {
                        viewModel.clearPendingSelection()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(Color.secondary.opacity(0.12), in: Circle())
                    }
                }
            }

            if !viewModel.pairingStatus.isLoaded {
                Button(action: switchToConfig) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RelocTheme.amber)
                        Text("このiPhoneはまだペアリングされていません。「デバイス接続」でワンタップペアリングしてください").font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .padding(10)
                    .background(RelocTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .foregroundStyle(.primary)
            } else if coreLocation.authorizationStatus == .denied || coreLocation.authorizationStatus == .restricted {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash.fill").foregroundStyle(RelocTheme.crimson)
                    Text("位置情報の許可がないため、外部GPSの購読を自動では開始できません").font(.caption.weight(.semibold))
                    Spacer()
                    Button("設定する") {
                        viewModel.openAppSettings()
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RelocTheme.crimson, in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
                .background(RelocTheme.crimson.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if viewModel.snapshot.isRunning {
                liveTriggerStatusBanner
            } else if viewModel.isRestoringRealLocation {
                restoreLocationStatusBanner
            } else if viewModel.realLocationRestoredNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RelocTheme.emerald)
                    Text("このiPhone本来のGPS位置に戻しました")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RelocTheme.emerald)
                    Spacer()
                }
                .padding(10)
                .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let err = viewModel.snapshot.lastError {
                Text("前回のエラー：\(err)")
                    .font(.caption)
                    .foregroundStyle(RelocTheme.crimson)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                if viewModel.snapshot.isRunning {
                    if viewModel.pendingLocation != nil {
                        RelocPrimaryButton(
                            title: "この位置に更新",
                            systemImage: "paperplane.fill",
                            gradient: RelocTheme.accentGradient
                        ) {
                            viewModel.applyPendingLocationUpdate()
                        }
                    }
                    RelocPrimaryButton(
                        title: "停止して戻す",
                        systemImage: "stop.fill",
                        gradient: RelocTheme.crimsonGradient
                    ) {
                        showStopConfirm = true
                    }
                } else {
                    RelocPrimaryButton(
                        title: "位置情報を開始",
                        systemImage: "paperplane.fill",
                        gradient: RelocTheme.accentGradient,
                        disabled: !viewModel.canStartSession
                    ) {
                        viewModel.start(mode: .send)
                    }
                }
            }
        }
        .relocGlassCard(cornerRadius: 24, padding: 15)
    }

    @ViewBuilder
    private var restoreLocationStatusBanner: some View {
        if viewModel.needsRestoreLocationRefresh {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(RelocTheme.amber)
                    Text("外部接続は切れていますが、システムが前回の位置をキャッシュしたままです（室内の弱い電波でよく起きます）。下のワンタップ更新で、実際の位置にすぐ戻せます。")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                Button {
                    RelocTheme.hapticMedium()
                    viewModel.launchOneTapRestoreRefresh()
                } label: {
                    Label("位置情報サービスをワンタップ更新（実際の位置に戻す）", systemImage: "pip.enter")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RelocTheme.amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.white)
                }
            }
            .padding(10)
            .background(RelocTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("切断と無効化の電文を送りました。このiPhone本来のGPSを起こして位置を戻しています…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("すぐに更新") {
                    RelocTheme.hapticLight()
                    viewModel.launchOneTapRestoreRefresh()
                }
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RelocTheme.accent.opacity(0.14), in: Capsule())
                .foregroundStyle(RelocTheme.accent)
            }
            .padding(9)
            .background(RelocTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private var gradualMoveBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("段階移動中（\(viewModel.gradualMoveRemainingText)）")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RelocTheme.accent)
                Text(String(format: "指定速度 %.0f km/h で目標ピンへ向かっています", viewModel.gradualMoveSpeedKmh))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(RelocTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var liveTriggerStatusBanner: some View {
        if viewModel.isGradualMoving, viewModel.snapshot.isRunning, !viewModel.needsLocationServiceRefresh {
            gradualMoveBanner
        } else {
        switch viewModel.injectionPhase {
        case .activeConfirmed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(RelocTheme.emerald)
                VStack(alignment: .leading, spacing: 1) {
                    Text("外部GPSは完全に有効です")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RelocTheme.emerald)
                    Text("システムが外部機器由来（isProducedByAccessory = true）を確認しました。ほかのアプリに切り替えて大丈夫です")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(10)
            .background(RelocTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .injectingPendingLock where viewModel.needsLocationServiceRefresh:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.circle.fill").foregroundStyle(RelocTheme.amber)
                    Text("NMEA はつながっていますが、システムがこのiPhoneのキャッシュ位置を使い続けています。下のワンタップ更新（フローティングの5秒カウントダウン付き）で確実に切り替えられます。")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 8) {
                    Button {
                        RelocTheme.hapticMedium()
                        viewModel.launchOneTapLocationRefresh()
                    } label: {
                        Label("位置情報サービスをワンタップ更新（フローティングガイド）", systemImage: "pip.enter")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RelocTheme.amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    Button {
                        RelocTheme.hapticLight()
                        viewModel.retryAutoLock()
                    } label: {
                        Text("再試行")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(10)
            .background(RelocTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        default:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(
                    viewModel.injectionPhase == .connecting
                        ? "デバイスのループバックに接続し、MFi認証を行っています…"
                        : (viewModel.injectionPhase == .waitingSubscription
                            ? "認証に成功しました。システムの外部GPS購読を自動で起こしています…"
                            : "NMEA座標を高速に送っています。システムが外部ソースをロックするのを待っています…")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer()
                if viewModel.snapshot.authenticated {
                    Button("強制更新") {
                        RelocTheme.hapticLight()
                        viewModel.launchOneTapLocationRefresh()
                    }
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RelocTheme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(RelocTheme.accent)
                }
            }
            .padding(9)
            .background(RelocTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        }
    }

    // MARK: - Search Action

    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
           (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) {
            viewModel.selectWGSLocation(TargetLocation(latitude: lat, longitude: lon, altitude: viewModel.targetLocation.altitude))
            cameraTarget = viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate
            searchResults = []
            searchText = ""
            return
        }

        isSearching = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = trimmed
        let search = MKLocalSearch(request: req)
        search.start { response, _ in
            Task { @MainActor in
                isSearching = false
                searchResults = response?.mapItems ?? []
            }
        }
    }
}

// MARK: - Interactive MKMapView Wrapper

private struct InteractiveMKMapView: UIViewRepresentable {
    let activeCoordinate: CLLocationCoordinate2D
    let isSessionRunning: Bool
    let pendingCoordinate: CLLocationCoordinate2D?
    let mapSource: MapSource
    let mapStyle: MapDisplayStyle
    let isDarkMode: Bool
    @Binding var cameraTarget: CLLocationCoordinate2D?
    let onTapCoordinate: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapCoordinate: onTapCoordinate)
    }

    func makeUIView(context: Context) -> RelocMKMapView {
        let mapView = RelocMKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)

        applyMapSource(to: mapView, context: context)

        let activeAnn = TaggedAnnotation(kind: .active)
        activeAnn.coordinate = activeCoordinate
        activeAnn.title = "現在地"
        mapView.addAnnotation(activeAnn)
        context.coordinator.activeAnnotation = activeAnn

        let region = MKCoordinateRegion(
            center: activeCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        mapView.setRegion(region, animated: false)
        return mapView
    }

    func updateUIView(_ uiView: RelocMKMapView, context: Context) {
        context.coordinator.onTapCoordinate = onTapCoordinate
        context.coordinator.isSessionRunning = isSessionRunning

        applyMapSource(to: uiView, context: context)

        if let activeAnn = context.coordinator.activeAnnotation {
            if abs(activeAnn.coordinate.latitude - activeCoordinate.latitude) > 1e-9 ||
               abs(activeAnn.coordinate.longitude - activeCoordinate.longitude) > 1e-9 {
                activeAnn.coordinate = activeCoordinate
            }
            if let markerView = uiView.view(for: activeAnn) as? MKMarkerAnnotationView {
                markerView.markerTintColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
            }
        }

        if let pending = pendingCoordinate {
            if let existing = context.coordinator.pendingAnnotation {
                existing.coordinate = pending
            } else {
                let ann = TaggedAnnotation(kind: .pending)
                ann.coordinate = pending
                ann.title = "更新予定の位置"
                uiView.addAnnotation(ann)
                context.coordinator.pendingAnnotation = ann
            }
        } else if let existing = context.coordinator.pendingAnnotation {
            uiView.removeAnnotation(existing)
            context.coordinator.pendingAnnotation = nil
        }

        if let target = cameraTarget {
            let region = MKCoordinateRegion(
                center: target,
                span: uiView.region.span.latitudeDelta > 0.25
                    ? MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    : uiView.region.span
            )
            uiView.setRegion(region, animated: true)
            DispatchQueue.main.async {
                cameraTarget = nil
            }
        }
    }

    private func applyMapSource(to mapView: RelocMKMapView, context: Context) {
        mapView.hideNativeAttribution = mapSource.isPureWGS84

        if mapSource == .appleNative {
            if let overlay = context.coordinator.tileOverlay {
                mapView.removeOverlay(overlay)
                context.coordinator.tileOverlay = nil
                context.coordinator.appliedTileKey = nil
            }
            switch mapStyle {
            case .standard: mapView.mapType = .standard
            case .satellite: mapView.mapType = .satellite
            case .hybrid: mapView.mapType = .hybrid
            }
            return
        }

        let key = mapSource.rawValue
        guard context.coordinator.appliedTileKey != key else { return }

        if let existing = context.coordinator.tileOverlay {
            mapView.removeOverlay(existing)
        }
        mapView.mapType = .standard
        let overlay = GlobalWGSTileOverlay(source: mapSource, isDarkMode: isDarkMode)
        mapView.addOverlay(overlay, level: .aboveLabels)
        context.coordinator.tileOverlay = overlay
        context.coordinator.appliedTileKey = key
    }

    final class TaggedAnnotation: MKPointAnnotation {
        enum Kind { case active, pending }
        let kind: Kind
        init(kind: Kind) {
            self.kind = kind
            super.init()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onTapCoordinate: (CLLocationCoordinate2D) -> Void
        var isSessionRunning = false
        var activeAnnotation: TaggedAnnotation?
        var pendingAnnotation: TaggedAnnotation?
        var tileOverlay: MKTileOverlay?
        var appliedTileKey: String?

        init(onTapCoordinate: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onTapCoordinate = onTapCoordinate
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            onTapCoordinate(coord)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let tagged = annotation as? TaggedAnnotation else { return nil }
            let id = tagged.kind == .active ? "reloc.active" : "reloc.pending"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.displayPriority = .required
            if tagged.kind == .active {
                view.markerTintColor = isSessionRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
                view.glyphImage = UIImage(systemName: "location.fill")
            } else {
                view.markerTintColor = UIColor(RelocTheme.amber)
                view.glyphImage = UIImage(systemName: "mappin")
            }
            return view
        }
    }
}

/// MKMapView subclass that suppresses the underlying MapKit/AutoNavi attribution logo
/// when custom WGS-84 tiles completely replace map content (`canReplaceMapContent = true`).
private final class RelocMKMapView: MKMapView {
    var hideNativeAttribution: Bool = false {
        didSet {
            updateAttributionSubviews()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateAttributionSubviews()
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        updateAttributionSubviews()
    }

    private func updateAttributionSubviews() {
        Self.applyAttributionVisibility(in: self, hide: hideNativeAttribution, depth: 0)
    }

    private static func applyAttributionVisibility(in root: UIView, hide: Bool, depth: Int) {
        guard depth <= 4 else { return }
        for subview in root.subviews {
            let className = String(describing: type(of: subview))
            // Never touch map rendering canvas, overlays, annotations, compass, or scale bar.
            if className.contains("BasicMap")
                || className.contains("VKMap")
                || className.contains("Annotation")
                || className.contains("Overlay")
                || className.contains("Compass")
                || className.contains("Scale") {
                continue
            }
            if isAttributionView(subview, className: className) {
                subview.isHidden = hide
                subview.alpha = hide ? 0.0 : 1.0
                continue
            }
            applyAttributionVisibility(in: subview, hide: hide, depth: depth + 1)
        }
    }

    private static func isAttributionView(_ view: UIView, className: String) -> Bool {
        if className.localizedCaseInsensitiveContains("Attribution")
            || className.localizedCaseInsensitiveContains("Logo")
            || className.localizedCaseInsensitiveContains("Legal") {
            return true
        }
        if let label = view as? UILabel, let text = label.text,
           (text.contains("高徳") || text.localizedCaseInsensitiveContains("AutoNavi") || text.contains("法律情報") || text.localizedCaseInsensitiveContains("Legal")) {
            return true
        }
        return false
    }
}

/// High-DPI cached global WGS-84 tile overlay (`canReplaceMapContent = true`) that completely replaces
/// AutoNavi/AMap tiles on Mainland China devices while keeping MapKit gestures, annotations, and search.
private final class GlobalWGSTileOverlay: MKTileOverlay {
    private let source: MapSource
    private let isDarkMode: Bool

    private static let tileSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "reloc_map_tiles"
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = [
            "User-Agent": "Reloc/1.0 (iOS; https://github.com/reloc)",
        ]
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }()

    init(source: MapSource, isDarkMode: Bool) {
        self.source = source
        self.isDarkMode = isDarkMode
        super.init(urlTemplate: nil)
        self.canReplaceMapContent = true
        self.minimumZ = 0
        self.maximumZ = 19
        self.tileSize = CGSize(width: 256, height: 256)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        switch source {
        case .globalStreet:
            return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/\(path.z)/\(path.y)/\(path.x)")!
        case .globalOSM:
            return URL(string: "https://tile.openstreetmap.org/\(path.z)/\(path.x)/\(path.y).png")!
        case .globalSatellite:
            return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/\(path.z)/\(path.y)/\(path.x)")!
        case .appleNative:
            return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/\(path.z)/\(path.y)/\(path.x)")!
        }
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let tileURL = url(forTilePath: path)
        var req = URLRequest(url: tileURL)
        req.cachePolicy = .returnCacheDataElseLoad
        Self.tileSession.dataTask(with: req) { data, response, error in
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result(nil, NSError(domain: "RelocTileOverlay", code: http.statusCode))
                return
            }
            result(data, error)
        }.resume()
    }
}

// MARK: - Places Sheet (Favorites + Recent 30 History + Rename)

private struct PlacesSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    let onSelect: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var tab = 0
    @State private var newFavoriteName = ""
    @State private var renamingFavorite: FavoriteLocation?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("カテゴリ", selection: $tab) {
                    Text("お気に入り (\(viewModel.favorites.count))").tag(0)
                    Text("最近の記録 (\(viewModel.recents.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                List {
                    if tab == 0 {
                        Section("選択中の位置をお気に入りに追加") {
                            HStack {
                                TextField("名前を入力", text: $newFavoriteName)
                                Button("保存") {
                                    viewModel.saveCurrentAsFavorite(name: newFavoriteName)
                                    newFavoriteName = ""
                                }
                                .disabled(newFavoriteName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }

                        Section("お気に入りに保存しました") {
                            if viewModel.favorites.isEmpty {
                                Text("お気に入りの場所はまだありません").foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.favorites) { fav in
                                    Button {
                                        viewModel.selectWGSLocation(
                                            TargetLocation(latitude: fav.latitude, longitude: fav.longitude, altitude: fav.altitude),
                                            name: fav.name,
                                            address: fav.subtitle
                                        )
                                        onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(fav.name).foregroundStyle(.primary)
                                            Text(fav.subtitle ?? String(format: "%.5f, %.5f", fav.latitude, fav.longitude))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            viewModel.deleteFavorite(id: fav.id)
                                        } label: {
                                            Label("削除", systemImage: "trash")
                                        }
                                        Button {
                                            renameText = fav.name
                                            renamingFavorite = fav
                                        } label: {
                                            Label("名前を変更", systemImage: "pencil")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }
                    } else {
                        Section {
                            if viewModel.recents.isEmpty {
                                Text("最近使った記録はまだありません").foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.recents) { item in
                                    Button {
                                        viewModel.selectWGSLocation(
                                            TargetLocation(latitude: item.latitude, longitude: item.longitude, altitude: item.altitude),
                                            name: item.name,
                                            address: item.subtitle
                                        )
                                        onSelect(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name).foregroundStyle(.primary)
                                            Text(item.subtitle ?? String(format: "%.5f, %.5f", item.latitude, item.longitude))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            viewModel.deleteRecent(id: item.id)
                                        } label: {
                                            Label("削除", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("最近使った場所（最大30件）")
                                Spacer()
                                if !viewModel.recents.isEmpty {
                                    Button("すべて削除") { viewModel.clearRecents() }
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("お気に入りと履歴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .alert("お気に入りの名前を変更", isPresented: Binding(
                get: { renamingFavorite != nil },
                set: { if !$0 { renamingFavorite = nil } }
            )) {
                TextField("新しい名前", text: $renameText)
                Button("キャンセル", role: .cancel) { renamingFavorite = nil }
                Button("保存") {
                    if let fav = renamingFavorite {
                        viewModel.renameFavorite(id: fav.id, newName: renameText)
                    }
                    renamingFavorite = nil
                }
            }
        }
    }
}

private struct ManualCoordinateSheet: View {
    @ObservedObject var viewModel: RelocViewModel
    let onApply: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var latText = ""
    @State private var lonText = ""
    @State private var altText = ""
    @State private var favoriteName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("WGS-84 座標") {
                    TextField("緯度（-90〜90）", text: $latText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("経度（-180〜180）", text: $lonText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("標高（m）", text: $altText)
                        .keyboardType(.numbersAndPunctuation)
                }

                Section("お気に入りに保存（任意）") {
                    TextField("場所の名前", text: $favoriteName)
                }
            }
            .navigationTitle("座標を手入力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") {
                        if let lat = Double(latText), let lon = Double(lonText),
                           (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) {
                            let alt = Double(altText) ?? viewModel.inspectedLocation.altitude
                            viewModel.selectWGSLocation(
                                TargetLocation(latitude: lat, longitude: lon, altitude: alt),
                                name: favoriteName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : favoriteName
                            )
                            if !favoriteName.trimmingCharacters(in: .whitespaces).isEmpty {
                                viewModel.saveCurrentAsFavorite(name: favoriteName)
                            }
                            onApply(viewModel.pendingMapCoordinate ?? viewModel.activeMapCoordinate)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                let loc = viewModel.inspectedLocation
                latText = String(format: "%.6f", loc.latitude)
                lonText = String(format: "%.6f", loc.longitude)
                altText = String(format: "%.1f", loc.altitude)
            }
        }
    }
}
