import CryptoKit
import Foundation
@testable import HerdrKit

/// Web Push encryption against RFC 8291 section 5 / appendix A, and the VAPID token (RFC 8292).
func checksWebPush() async throws {
    func b(_ s: String) -> Data { Base64URL.decode(s)! }
    let plaintext = Data("When I grow up, I want to be a watermelon".utf8)
    let asPrivate = b("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")
    let uaPublic = b("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
    let uaPrivate = b("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")
    let salt = b("DGv6ra1nlYgDCS1FRnbzlw"), auth = b("BTBZMqHH6r4Tts7J_aSIgg")
    let expected = b("""
        DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml
        mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT
        pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN
        """)
    check(expected.count == 144, "webpush: RFC body is 144 bytes (86 header + 42 record + 16 tag)")
    let sender = try P256.KeyAgreement.PrivateKey(rawRepresentation: asPrivate)
    let body = try? WebPush.encrypt(plaintext, uaPublic: uaPublic, authSecret: auth, sender: sender, salt: salt)
    check(body == expected, "webpush: RFC 8291 example body, byte for byte")

    // Fresh keys and salt: the receiver (the RFC's user agent key) decrypts it back.
    let fresh = try? WebPush.encrypt(plaintext, uaPublic: uaPublic, authSecret: auth)
    check(fresh != nil && fresh != expected && fresh?.prefix(16) != salt, "webpush: a fresh sender key and salt per message")
    if let fresh {
        let back = try? WebPush.decrypt(fresh, uaPrivate: P256.KeyAgreement.PrivateKey(rawRepresentation: uaPrivate), authSecret: auth)
        check(back == plaintext, "webpush: the receiver decrypts a fresh message")
    }
    check((try? WebPush.encrypt(plaintext, uaPublic: Data(repeating: 4, count: 65), authSecret: auth)) == nil, "webpush: a key off the curve is refused")
    check((try? WebPush.encrypt(plaintext, uaPublic: uaPublic, authSecret: Data(count: 3))) == nil, "webpush: a short auth secret is refused")
    check((try? WebPush.encrypt(Data(count: WebPush.maxPlaintext + 1), uaPublic: uaPublic, authSecret: auth)) == nil
          && (try? WebPush.encrypt(Data(count: WebPush.maxPlaintext), uaPublic: uaPublic, authSecret: auth))?.count == 4096,
          "webpush: the body is at most 4096 bytes")

    // VAPID: the header's key is the signing key's public key; the token is an ES256 JWT for the endpoint's origin.
    let key = P256.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let header = VAPID.authorization(audience: "https://fcm.googleapis.com", subject: "mailto:push@example.com", key: key, now: now)
    let parts = header.firstMatch(of: /^vapid t=([^,]+), k=(.+)$/)
    check(parts != nil, "vapid: header form 'vapid t=…, k=…' (\(header.prefix(40)))")
    if let parts {
        check(b(String(parts.2)) == key.publicKey.x963Representation, "vapid: k is the public key, uncompressed")
        let jwt = String(parts.1).split(separator: ".").map(String.init)
        check(jwt.count == 3, "vapid: three JWT parts")
        if jwt.count == 3 {
            let head = try? JSONSerialization.jsonObject(with: b(jwt[0])) as? [String: Any]
            let claims = try? JSONSerialization.jsonObject(with: b(jwt[1])) as? [String: Any]
            check(head?["alg"] as? String == "ES256" && head?["typ"] as? String == "JWT", "vapid: ES256 JWT header")
            check(claims?["aud"] as? String == "https://fcm.googleapis.com" && claims?["sub"] as? String == "mailto:push@example.com",
                  "vapid: aud and sub")
            check((claims?["exp"] as? Int) == 1_800_000_000 + 12 * 3600, "vapid: exp = now + 12 h")
            let sig = b(jwt[2])
            let valid = sig.count == 64 && (try? P256.Signing.ECDSASignature(rawRepresentation: sig)).map {
                key.publicKey.isValidSignature($0, for: Data((jwt[0] + "." + jwt[1]).utf8))
            } == true
            check(valid, "vapid: signature (raw r||s, 64 bytes) verifies with k")
        }
    }
    let long = VAPID.authorization(audience: "https://fcm.googleapis.com", subject: "mailto:a@b.c", key: key, now: now, lifetime: 48 * 3600)
    let exp = long.firstMatch(of: /t=[^.]+\.([^.]+)\./).flatMap { (try? JSONSerialization.jsonObject(with: b(String($0.1)))) as? [String: Any] }?["exp"] as? Int
    check(exp == 1_800_000_000 + 24 * 3600, "vapid: lifetime capped at 24 h")
}
