import Foundation

public struct SignalKDelta: Codable {
    public struct Update: Codable {
        public struct Value: Codable {
            public let path: String? // Some servers put path only at update-level
            public let value: CodableValue
        }
        public let path: String? // Optional update-level path
        public let values: [Value]
    }
    public let context: String?
    public let updates: [Update]
}

public struct SignalKRequestResponse: Decodable {
    public let requestId: String
    public let state: String
    public let statusCode: Int?
    public let message: String?

    private enum CodingKeys: String, CodingKey {
        case requestId
        case state
        case statusCode
        case result
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        state = try container.decode(String.self, forKey: .state)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        ?? container.decodeIfPresent(Int.self, forKey: .result)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    var isAcceptedPending: Bool {
        #if DEBUG
        state == "PENDING" && statusCode == 202
        #else
        false
        #endif
    }

    var isSuccessful: Bool {
        guard let statusCode, (200...299).contains(statusCode) else { return false }
        return state == "COMPLETED" || isAcceptedPending
    }
}

public enum SignalKWebSocketRequestError: Error, LocalizedError {
    case notConnected
    case encodingFailed
    case timedOut
    case failed(statusCode: Int?, state: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Signal K WebSocket is not connected."
        case .encodingFailed:
            return "Signal K WebSocket request could not be encoded."
        case .timedOut:
            return "Signal K WebSocket request timed out."
        case .failed(let statusCode, let state, let message):
            let status = statusCode.map(String.init) ?? "unknown"
            let stateText = state ?? "unknown"
            if let message {
                return "Signal K WebSocket request failed with status \(status), state \(stateText): \(message)"
            }
            return "Signal K WebSocket request failed with status \(status), state \(stateText)."
        }
    }
}

public enum CodableValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case dict([String: Double])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let dict = try? container.decode([String: Double].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.typeMismatch(CodableValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown type"))
        }
    }

    public func doubleValue() -> Double? {
        switch self {
        case .double(let d):
            return d
        case .int(let i):
            return Double(i)
        case .string(let s):
            return Double(s)
        default:
            return nil
        }
    }
}

// Represents a subscription request for one Signal K path.
public struct SignalKSubscriptionRequest: Codable, Equatable {
    public let path: String
    public let policy: String? // e.g., "instant", "fixed"
    public let period: Double? // seconds for fixed policy
    public let minPeriod: Double? // minimum interval for updates

    public init(path: String, policy: String? = nil, period: Double? = nil, minPeriod: Double? = nil) {
        self.path = path
        self.policy = policy
        self.period = period
        self.minPeriod = minPeriod
    }

    // Convert to a Signal K subscribe dict
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = ["path": path]
        if let policy { dict["policy"] = policy }
        if let period { dict["period"] = period }
        if let minPeriod { dict["minPeriod"] = minPeriod }
        return dict
    }
}

// MARK: - Signal K API Models

public struct SignalKAccessRequest: Codable {
    public let clientId: String
    public let description: String
}

public struct SignalKAccessResponse: Codable {
    public let state: String
    public let href: String?
    public let requestId: String?
    public let statusCode: Int?
    public let message: String?
}

public struct SignalKAccessStatus: Codable {
    public let state: String
    public let statusCode: Int?
    public let accessRequest: SignalKAccessRequestResult?
    public let message: String?
}

public struct SignalKAccessRequestResult: Codable {
    public let permission: String
    public let token: String?
    public let expirationTime: String?
}
