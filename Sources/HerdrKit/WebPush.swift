import CryptoKit
import Foundation

/// Web Push message encryption (RFC 8291, "aes128gcm" content coding of RFC 8188) and VAPID (RFC 8292), with CryptoKit
/// only. The push service (FCM, Apple, Mozilla) sees the size and time, never the text.
public enum WebPush {
    /// Record size written in the header. One record: a push message is at most 4 KB.
    static let recordSize: UInt32 = 4096

    /// The longest plaintext: the whole body (86-byte header, the text, the 0x02 delimiter, the 16-byte tag) stays
    /// within 4096 bytes, the size every push service takes.
    public static let maxPlaintext = 4096 - 86 - 1 - 16

    /// The request body for one push message to a subscription (`uaPublic`: the subscription's p256dh key, 65 bytes
    /// uncompressed; `authSecret`: its 16-byte auth). `sender` and `salt` are fresh per message; tests fix them.
    public static func encrypt(_ plaintext: Data, uaPublic: Data, authSecret: Data,
                               sender: P256.KeyAgreement.PrivateKey = .init(), salt: Data? = nil) throws -> Data {
        guard authSecret.count == 16 else { throw WebPushError.badKey }
        guard plaintext.count <= maxPlaintext else { throw WebPushError.tooLong }
        guard let ua = try? P256.KeyAgreement.PublicKey(x963Representation: uaPublic) else { throw WebPushError.badKey }
        let salt = salt ?? Data(SymmetricKey(size: .init(bitCount: 128)).withUnsafeBytes { Array($0) })
        let asPublic = sender.publicKey.x963Representation
        let (cek, nonce) = try keys(shared: sender.sharedSecretFromKeyAgreement(with: ua), uaPublic: ua.x963Representation,
                                    asPublic: asPublic, authSecret: authSecret, salt: salt)
        let sealed = try AES.GCM.seal(plaintext + [0x02], using: cek, nonce: nonce)
        var header = salt
        withUnsafeBytes(of: recordSize.bigEndian) { header.append(contentsOf: $0) }
        header.append(UInt8(asPublic.count))
        header.append(asPublic)
        return header + sealed.ciphertext + sealed.tag
    }

    /// The receiver's side, for checks and the local fake push service.
    public static func decrypt(_ body: Data, uaPrivate: P256.KeyAgreement.PrivateKey, authSecret: Data) throws -> Data {
        let b = Data(body)
        guard b.count > 21 else { throw WebPushError.badBody }
        let salt = b.prefix(16), idLen = Int(b[b.startIndex + 20])
        guard b.count >= 21 + idLen + 16 else { throw WebPushError.badBody }
        let asPublic = b.subdata(in: b.startIndex + 21 ..< b.startIndex + 21 + idLen)
        guard let sender = try? P256.KeyAgreement.PublicKey(x963Representation: asPublic) else { throw WebPushError.badKey }
        let (cek, nonce) = try keys(shared: uaPrivate.sharedSecretFromKeyAgreement(with: sender),
                                    uaPublic: uaPrivate.publicKey.x963Representation, asPublic: asPublic,
                                    authSecret: authSecret, salt: Data(salt))
        let rest = b.subdata(in: b.startIndex + 21 + idLen ..< b.endIndex)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: rest.dropLast(16), tag: rest.suffix(16))
        var plain = try AES.GCM.open(box, using: cek)
        while plain.last == 0 { plain.removeLast() }   // padding
        guard plain.last == 0x02 else { throw WebPushError.badBody }
        return plain.dropLast()
    }

    /// RFC 8291 section 3.4 and RFC 8188 section 2.2: the content key and the nonce of the only record.
    private static func keys(shared: SharedSecret, uaPublic: Data, asPublic: Data, authSecret: Data, salt: Data) throws -> (SymmetricKey, AES.GCM.Nonce) {
        let keyInfo = Data("WebPush: info\u{0}".utf8) + uaPublic + asPublic
        let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: authSecret, sharedInfo: keyInfo, outputByteCount: 32)
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\u{0}".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\u{0}".utf8), outputByteCount: 12)
        return (cek, try AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))
    }
}

public enum WebPushError: Error, Sendable, Hashable {
    case badKey, tooLong, badBody
}

/// base64url without padding (Web Push keys, VAPID tokens).
public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ s: String) -> Data? {
        var t = s.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// VAPID: the application server's identity on each push request (RFC 8292).
public enum VAPID {
    /// `Authorization: vapid t=<jwt>, k=<public key>`. `audience`: the endpoint's origin ("https://fcm.googleapis.com").
    /// `subject`: a contact ("mailto:…" or "https://…"). The token expires after `lifetime` (at most 24 h).
    public static func authorization(audience: String, subject: String, key: P256.Signing.PrivateKey,
                                     now: Date = Date(), lifetime: TimeInterval = 12 * 3600) -> String {
        let exp = Int(now.timeIntervalSince1970 + min(lifetime, 24 * 3600))
        let json: ([String: Any]) -> String = { Base64URL.encode(try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])) }
        let input = json(["typ": "JWT", "alg": "ES256"]) + "." + json(["aud": audience, "exp": exp, "sub": subject])
        let sig = (try? key.signature(for: Data(input.utf8)))?.rawRepresentation ?? Data()
        return "vapid t=\(input).\(Base64URL.encode(sig)), k=\(Base64URL.encode(key.publicKey.x963Representation))"
    }
}
