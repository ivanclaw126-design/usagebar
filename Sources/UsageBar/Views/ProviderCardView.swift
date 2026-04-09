import SwiftUI

struct ProviderCardView: View {
    let snapshot: ProviderBalanceSnapshot
    let hasCredential: Bool
    let reconnectAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.provider.displayName)
                        .font(.headline)
                    Text(snapshot.status.badgeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if snapshot.status == .authRequired || hasCredential == false {
                    Button("Reconnect", action: reconnectAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                Text("Updated")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(snapshot.fetchedAt.fullTimestampLabel)
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
                    metricBlock(title: "Remaining", value: formattedRemaining)
                    metricBlock(title: "Used", value: snapshot.usedValue ?? "—")
                    metricBlock(title: "Reset", value: snapshot.resetAt?.dashboardLabel ?? "—")
                }
            }

            Text(snapshot.summaryText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)

            Text(snapshot.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Text(metadata.statusText ?? snapshot.status.badgeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                Text("\(metadata.windows.filter { $0.bucket != .unmatched }.count) windows")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.75))
                    .clipShape(Capsule())
            }

            if metadata.windows.isEmpty {
                HStack(spacing: 12) {
                    metricBlock(title: "Remaining", value: formattedRemaining)
                    metricBlock(title: "Used", value: snapshot.usedValue ?? "—")
                    metricBlock(title: "Reset", value: snapshot.resetAt?.dashboardLabel ?? "—")
                }
            } else {
                ForEach(metadata.windows.prefix(3)) { window in
                    bailianWindowRow(window)
                }

                if metadata.unmatchedWindowCount > 0 {
                    Text("Other Limits: \(metadata.unmatchedWindowCount) unmatched windows")
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
                    Text(metadata.sourceLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if let credits = metadata.creditsRemaining {
                    Text("\(formattedCredits(credits)) credits")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.75))
                        .clipShape(Capsule())
                }
            }

            if metadata.windows.isEmpty {
                Text("Local Codex usage windows are not available yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(metadata.windows.prefix(2)) { window in
                    codexWindowRow(window)
                }
            }

            if let email = metadata.accountEmail {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text(metadata.subscriptionStatusText ?? snapshot.status.badgeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                Text("\(metadata.windows.filter { $0.bucket != .unmatched }.count) windows")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.75))
                    .clipShape(Capsule())
            }

            if metadata.windows.isEmpty {
                Text("Quota windows are not available yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(metadata.windows.prefix(3)) { window in
                    quotaWindowRow(window)
                }

                if metadata.unmatchedWindowCount > 0 {
                    Text("Other Limits: \(metadata.unmatchedWindowCount) unmatched windows")
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
                Text("Resets")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(window.resetAt?.fullTimestampLabel ?? "—")
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
                Text("Resets")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(window.resetAt?.fullTimestampLabel ?? "—")
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
                Text("Resets")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(window.resetAt?.fullTimestampLabel ?? window.resetDescription ?? "—")
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
        switch snapshot.status {
        case .ok:
            .green
        case .degraded:
            .yellow
        case .authRequired, .error:
            .red
        case .supportedLimited:
            .blue
        case .unsupported:
            .secondary
        }
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

    private var dataAgeColor: Color {
        switch snapshot.fetchedAt.ageTint {
        case .fresh:
            return Color(red: 0.16, green: 0.62, blue: 0.34)
        case .aging:
            return Color(red: 0.90, green: 0.55, blue: 0.12)
        case .stale:
            return Color(red: 0.84, green: 0.22, blue: 0.22)
        }
    }
}
