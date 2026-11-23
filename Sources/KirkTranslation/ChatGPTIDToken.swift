import Foundation
import Security

enum ChatGPTIDToken {
    struct Identity: Codable {
        let sub: String
        let email: String?
    }

    static func verify(_ token: String, keys data: Data, clientID: String, nonce: String) throws -> Identity {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let header = json(parts[0]), header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let claims = json(parts[1]), let signature = decode(parts[2]),
              let keys = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let modulus = decode(key["n"] as? String ?? ""), let exponent = decode(key["e"] as? String ?? ""),
              !modulus.isEmpty, !exponent.isEmpty,
              let publicKey = SecKeyCreateWithData(der(0x30, integer(modulus) + integer(exponent)) as CFData, [
                  kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic
              ] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              claims["iss"] as? String == "https://auth.openai.com",
              (claims["aud"] as? [String] ?? [claims["aud"] as? String ?? ""]) == [clientID],
              (claims["azp"] as? String ?? clientID) == clientID,
              claims["nonce"] as? String == nonce,
              let expiration = claims["exp"] as? TimeInterval, expiration > Date().timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw ChatGPTPlan.Failure.invalidAuthorization
        }
        return Identity(sub: subject, email: claims["email"] as? String)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ text: String) -> Data? {
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }

    private static func json(_ text: String) -> [String: Any]? {
        guard let data = decode(text) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func integer(_ bytes: Data) -> Data {
        let unsigned = Data(bytes.drop(while: { $0 == 0 }))
        return der(0x02, (unsigned.first ?? 0) >= 128 || unsigned.isEmpty ? Data([0]) + unsigned : unsigned)
    }

    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        if bytes.count < 128 { return Data([tag, UInt8(bytes.count)]) + bytes }
        var count = bytes.count
        var length: [UInt8] = []
        while count > 0 {
            length.insert(UInt8(truncatingIfNeeded: count), at: 0)
            count >>= 8
        }
        return Data([tag, 0x80 | UInt8(length.count)] + length) + bytes
    }
}
