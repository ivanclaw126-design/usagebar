import Foundation

extension Date {
    var dashboardLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
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

    var fullTimestampLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
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
