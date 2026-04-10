import SwiftUI

struct ProviderCardView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    let snapshot: ProviderBalanceSnapshot
    let hasCredential: Bool
    let reconnectAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ProviderLogoView(provider: snapshot.provider)
                        Text(snapshot.provider.displayName)
                            .font(.headline)
                    }
                    Text(statusBadgeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if snapshot.status == .authRequired || hasCredential == false {
                    Button(text("Reconnect", "重新连接"), action: reconnectAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                Text(text("Updated", "更新于"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(snapshot.fetchedAt.fullTimestampLabel(isChinese: settingsStore.snapshot.language == .chinese))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dataAgeColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let bailianMetadata = snapshot.providerMetadata?.bailian {
                bailianUsageSection(metadata: bailianMetadata)
            } else if let zaiMetadata = snapshot.providerMetadata?.zai {
                zaiQuotaSection(metadata: zaiMetadata)
            } else if let codexMetadata = snapshot.providerMetadata?.codex {
                codexUsageSection(metadata: codexMetadata)
            } else {
                HStack(spacing: 12) {
                    metricBlock(title: text("Remaining", "剩余"), value: formattedRemaining)
                    metricBlock(title: text("Used", "已用"), value: snapshot.usedValue ?? "—")
                    metricBlock(
                        title: text("Reset", "重置"),
                        value: snapshot.resetAt?.dashboardLabel(isChinese: settingsStore.snapshot.language == .chinese) ?? "—"
                    )
                }
            }

            if shouldShowFooterText {
                Text(snapshot.summaryText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)

                Text(snapshot.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.78), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.05), radius: 16, y: 8)
        }
    }

    @ViewBuilder
    private func bailianUsageSection(metadata: BailianProviderMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.planName ?? "Coding Plan")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Text(providerSubtitleText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(providerSubtitleColor)
                }
                Spacer()
            }

            if metadata.windows.isEmpty {
                HStack(spacing: 12) {
                    metricBlock(title: text("Remaining", "剩余"), value: formattedRemaining)
                    metricBlock(title: text("Used", "已用"), value: snapshot.usedValue ?? "—")
                    metricBlock(
                        title: text("Reset", "重置"),
                        value: snapshot.resetAt?.dashboardLabel(isChinese: settingsStore.snapshot.language == .chinese) ?? "—"
                    )
                }
            } else {
                ForEach(metadata.windows.prefix(3)) { window in
                    bailianWindowRow(window)
                }

                if metadata.unmatchedWindowCount > 0 {
                    Text(text("Other Limits: \(metadata.unmatchedWindowCount) unmatched windows", "其他限制：\(metadata.unmatchedWindowCount) 个未匹配窗口"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func codexUsageSection(metadata: CodexProviderMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.planName ?? "Codex")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Text(providerSubtitleText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(providerSubtitleColor)
                }
                Spacer()
                if let credits = metadata.creditsRemaining, credits > 0 {
                    Text("\(formattedCredits(credits)) credits")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.75))
                        .clipShape(Capsule())
                }
            }

            if metadata.windows.isEmpty {
                Text(text("Codex usage windows are not available yet.", "暂时还没有 Codex 用量窗口数据。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(metadata.windows.prefix(2)) { window in
                    codexWindowRow(window)
                }
            }
        }
    }

    @ViewBuilder
    private func zaiQuotaSection(metadata: ZAIProviderMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.planName ?? "Unknown Plan")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Text(providerSubtitleText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(providerSubtitleColor)
                }
                Spacer()
            }

            if metadata.windows.isEmpty {
                Text(text("Quota windows are not available yet.", "暂时还没有配额窗口数据。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(metadata.windows.prefix(3)) { window in
                    quotaWindowRow(window)
                }

                if metadata.unmatchedWindowCount > 0 {
                    Text(text("Other Limits: \(metadata.unmatchedWindowCount) unmatched windows", "其他限制：\(metadata.unmatchedWindowCount) 个未匹配窗口"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func quotaWindowRow(_ window: ZAIQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.bucket.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(window.percentage.rounded()))%")
                    .font(.system(.title3, design: .rounded).weight(.bold))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.07))
                    Capsule()
                        .fill(progressColor(for: window.percentage))
                        .frame(width: max(proxy.size.width * min(max(window.percentage / 100, 0), 1), 10))
                }
            }
            .frame(height: 8)

            HStack(alignment: .top, spacing: 8) {
                Text(text("Resets", "重置"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(
                    window.resetAt.map {
                        $0.resetLabel(
                            isChinese: settingsStore.snapshot.language == .chinese,
                            includeTime: window.bucket == .fiveHour
                        )
                    } ?? window.resetDescription ?? zaiResetFallbackText(for: window)
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.92), lineWidth: 1)
                )
        )
    }

    private func bailianWindowRow(_ window: BailianUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.bucket.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(window.percentage.rounded()))%")
                    .font(.system(.title3, design: .rounded).weight(.bold))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.07))
                    Capsule()
                        .fill(progressColor(for: window.percentage))
                        .frame(width: max(proxy.size.width * min(max(window.percentage / 100, 0), 1), 10))
                }
            }
            .frame(height: 8)

            HStack(alignment: .top, spacing: 8) {
                Text(text("Resets", "重置"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(
                    window.resetAt.map {
                        $0.resetLabel(
                            isChinese: settingsStore.snapshot.language == .chinese,
                            includeTime: window.bucket == .fiveHour
                        )
                    } ?? "—"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.92), lineWidth: 1)
                )
        )
    }

    private func codexWindowRow(_ window: CodexUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.bucket.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(window.percentage.rounded()))%")
                    .font(.system(.title3, design: .rounded).weight(.bold))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.07))
                    Capsule()
                        .fill(progressColor(for: window.percentage))
                        .frame(width: max(proxy.size.width * min(max(window.percentage / 100, 0), 1), 10))
                }
            }
            .frame(height: 8)

            HStack(alignment: .top, spacing: 8) {
                Text(text("Resets", "重置"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(
                    window.resetAt.map {
                        $0.resetLabel(
                            isChinese: settingsStore.snapshot.language == .chinese,
                            includeTime: window.bucket == .fiveHour
                        )
                    } ?? window.resetDescription ?? "—"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.92), lineWidth: 1)
                )
        )
    }

    private var formattedRemaining: String {
        if let remaining = snapshot.remainingValue {
            return remaining + (snapshot.remainingUnit.map { " \($0)" } ?? "")
        }
        if snapshot.status == .supportedLimited {
            return "Not exposed"
        }
        return "—"
    }

    private var statusColor: Color {
        if isBailianRecentSavedSnapshot {
            return .green
        }
        if isBailianExpiredSavedSnapshot {
            return .red
        }
        switch snapshot.status {
        case .ok:
            return Color.green
        case .degraded:
            return Color.yellow
        case .authRequired, .error:
            return Color.red
        case .supportedLimited:
            return Color.blue
        case .unsupported:
            return Color.secondary
        }
    }

    private var providerSubtitleText: String {
        if isBailianRecentSavedSnapshot {
            return text("Saved snapshot is still current", "已保存快照仍在有效期内")
        }
        if isBailianExpiredSavedSnapshot {
            return text("Saved snapshot expired", "已保存快照已过期")
        }
        switch snapshot.status {
        case .ok:
            return text("Live usage synced", "已同步最新用量")
        case .degraded:
            return text("Cached snapshot", "显示缓存快照")
        case .authRequired:
            return text("Reconnect needed", "需要重新连接")
        case .supportedLimited:
            return text("Limited data", "仅有限数据")
        case .unsupported:
            return text("Unsupported", "暂不支持")
        case .error:
            return text("Refresh failed", "刷新失败")
        }
    }

    private var statusBadgeText: String {
        if isBailianRecentSavedSnapshot {
            return text("Connected", "已连接")
        }
        if isBailianExpiredSavedSnapshot {
            return text("Expired", "已过期")
        }
        switch snapshot.status {
        case .ok:
            return text("Connected", "已连接")
        case .degraded:
            return text("Delayed", "已延迟")
        case .authRequired:
            return text("Auth Required", "需要授权")
        case .unsupported:
            return text("Unsupported", "暂不支持")
        case .supportedLimited:
            return text("Limited", "受限")
        case .error:
            return text("Error", "错误")
        }
    }

    private var providerSubtitleColor: Color {
        if isBailianRecentSavedSnapshot {
            return .green
        }
        if isBailianExpiredSavedSnapshot {
            return .red
        }
        switch snapshot.status {
        case .ok:
            return .green
        case .degraded:
            return .orange
        case .authRequired, .error:
            return .red
        case .supportedLimited:
            return .blue
        case .unsupported:
            return .secondary
        }
    }

    private var shouldShowFooterText: Bool {
        snapshot.providerMetadata == nil
    }

    private func formattedCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        return formatter.string(from: value as NSNumber) ?? String(format: "%.2f", value)
    }

    private func metricBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressColor(for percentage: Double) -> Color {
        switch percentage {
        case ..<40:
            return Color(red: 0.18, green: 0.62, blue: 0.36)
        case ..<75:
            return Color(red: 0.95, green: 0.67, blue: 0.16)
        default:
            return Color(red: 0.90, green: 0.34, blue: 0.29)
        }
    }

    private func zaiResetFallbackText(for window: ZAIQuotaWindow) -> String {
        guard window.bucket == .fiveHour else {
            return "—"
        }
        return text(
            "Not exposed by the current official endpoint",
            "官方接口目前未明确提供"
        )
    }

    private var dataAgeColor: Color {
        if isBailianRecentSavedSnapshot {
            return Color(red: 0.16, green: 0.62, blue: 0.34)
        }
        if isBailianExpiredSavedSnapshot {
            return Color(red: 0.84, green: 0.22, blue: 0.22)
        }
        switch snapshot.fetchedAt.ageTint {
        case .fresh:
            return Color(red: 0.16, green: 0.62, blue: 0.34)
        case .aging:
            return Color(red: 0.90, green: 0.55, blue: 0.12)
        case .stale:
            return Color(red: 0.84, green: 0.22, blue: 0.22)
        }
    }

    private func text(_ english: String, _ chinese: String) -> String {
        settingsStore.text(english, chinese)
    }

    private var isBailianSavedSnapshot: Bool {
        snapshot.provider == .bailian && snapshot.providerMetadata?.bailian?.statusText == "Saved Session"
    }

    private var isBailianRecentSavedSnapshot: Bool {
        isBailianSavedSnapshot && snapshot.fetchedAt.bailianSnapshotFreshness == .valid
    }

    private var isBailianExpiredSavedSnapshot: Bool {
        isBailianSavedSnapshot && snapshot.fetchedAt.bailianSnapshotFreshness == .expired
    }
}

private struct ProviderLogoView: View {
    let provider: ProviderKind

    var body: some View {
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .renderingMode(provider == .bailian ? .template : .original)
            .foregroundStyle(Color.black.opacity(0.82))
            .scaledToFit()
            .frame(width: 16, height: 16)
    }

    private var assetName: String {
        switch provider {
        case .bailian:
            return "BailianLogo"
        case .zaiGlobal:
            return "ZAILogo"
        case .openAIPlus:
            return "OpenAILogo"
        }
    }
}
