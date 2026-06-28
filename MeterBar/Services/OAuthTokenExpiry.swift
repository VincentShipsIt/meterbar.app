import Foundation

enum OAuthTokenExpiry {
    static func isExpired(jwt token: String, graceInterval: TimeInterval = 60, now: Date = Date()) -> Bool {
        // If the token has no parseable `exp` claim we cannot prove it is expired,
        // so we treat it as not-expired and let the server be the source of truth
        // (a truly invalid token simply 401s on the next request). This is a
        // deliberate availability choice: failing to introspect a token must not
        // lock out a session whose token format we don't fully understand.
        guard let expirationDate = expirationDate(fromJWT: token) else {
            return false
        }

        return expirationDate <= now.addingTimeInterval(graceInterval)
    }

    static func isExpired(unixTimestamp rawTimestamp: Int64, graceInterval: TimeInterval = 60, now: Date = Date()) -> Bool {
        expirationDate(fromUnixTimestamp: rawTimestamp) <= now.addingTimeInterval(graceInterval)
    }

    static func expirationDate(fromUnixTimestamp rawTimestamp: Int64) -> Date {
        let timestamp = Double(rawTimestamp)
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }

    static func expirationDate(fromJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = decodeBase64URL(String(parts[1])),
              let payload = try? JSONDecoder().decode(JWTPayload.self, from: payloadData),
              let expiration = payload.exp else {
            return nil
        }

        return Date(timeIntervalSince1970: expiration)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: base64)
    }
}

private struct JWTPayload: Decodable {
    let exp: TimeInterval?
}
