import Foundation

struct ProviderPayloadReader {
    let root: Any

    init(root: Any) {
        self.root = root
    }

    func string(forKeyPaths keyPaths: [[String]]) -> String? {
        for keyPath in keyPaths {
            if let string = normalizedString(value(at: keyPath)) {
                return string
            }
        }
        return nil
    }

    func number(forKeyPaths keyPaths: [[String]]) -> Double? {
        for keyPath in keyPaths {
            if let number = normalizedNumber(value(at: keyPath)) {
                return number
            }
        }
        return nil
    }

    func date(forKeyPaths keyPaths: [[String]]) -> Date? {
        for keyPath in keyPaths {
            if let date = normalizedDate(value(at: keyPath)) {
                return date
            }
        }
        return nil
    }

    func bool(forKeyPaths keyPaths: [[String]]) -> Bool? {
        for keyPath in keyPaths {
            switch value(at: keyPath) {
            case let bool as Bool:
                return bool
            case let number as NSNumber:
                return number.boolValue
            case let string as String:
                if ["true", "1", "yes"].contains(string.lowercased()) {
                    return true
                }
                if ["false", "0", "no"].contains(string.lowercased()) {
                    return false
                }
            default:
                break
            }
        }
        return nil
    }

    func array(forKeyPaths keyPaths: [[String]]) -> [Any]? {
        for keyPath in keyPaths {
            if let array = value(at: keyPath) as? [Any], array.isEmpty == false {
                return array
            }
        }
        return nil
    }

    func dictionary(forKeyPaths keyPaths: [[String]]) -> [String: Any]? {
        for keyPath in keyPaths {
            if let dictionary = value(at: keyPath) as? [String: Any] {
                return dictionary
            }
        }
        return nil
    }

    private func value(at keyPath: [String]) -> Any? {
        var current: Any? = root
        for key in keyPath {
            if let dict = current as? [String: Any] {
                current = dict[key]
                continue
            }

            if
                let array = current as? [Any],
                let first = array.first as? [String: Any]
            {
                current = first[key]
                continue
            }

            return nil
        }
        return current
    }

    private func normalizedString(_ value: Any?) -> String? {
        switch value {
        case let string as String where string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func normalizedNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func normalizedDate(_ value: Any?) -> Date? {
        if let number = normalizedNumber(value) {
            return Date(timeIntervalSince1970: number / (number > 4_000_000_000 ? 1000 : 1))
        }

        guard let string = normalizedString(value) else {
            return nil
        }

        if let date = ISO8601DateFormatter().date(from: string) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }
}
