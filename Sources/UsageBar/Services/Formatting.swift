import Foundation

extension Date {
    func dashboardLabel(isChinese: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if isChinese {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: self)
    }

    var relativeLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: .now)
    }

    var veryShortRelativeLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: .now)
            .replacingOccurrences(of: "in ", with: "")
    }

    func fullTimestampLabel(isChinese: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if isChinese {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
        }
        return formatter.string(from: self)
    }

    func resetLabel(isChinese: Bool, includeTime: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let currentYear = Calendar.current.component(.year, from: .now)
        let targetYear = Calendar.current.component(.year, from: self)
        if isChinese {
            formatter.dateFormat = includeTime
                ? (currentYear == targetYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm")
                : (currentYear == targetYear ? "M月d日" : "yyyy年M月d日")
        } else {
            formatter.dateFormat = includeTime
                ? (currentYear == targetYear ? "MMM d HH:mm" : "MMM d, yyyy HH:mm")
                : (currentYear == targetYear ? "MMM d" : "MMM d, yyyy")
        }
        return formatter.string(from: self)
    }

    var ageTint: DataAgeTint {
        let age = Date().timeIntervalSince(self)
        if age <= 600 {
            return .fresh
        }
        if age <= 86_400 {
            return .aging
        }
        return .stale
    }
}

enum DataAgeTint: Equatable {
    case fresh
    case aging
    case stale
}
