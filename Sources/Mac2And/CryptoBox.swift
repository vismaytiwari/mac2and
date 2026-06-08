import CryptoKit
import Foundation

struct EncryptedPayload: Codable {
  let data: String
  let iv: String
}

enum CryptoBox {
  enum Error: Swift.Error {
    case invalidBase64
    case payloadTooShort
  }

  static func encrypt(_ plaintext: String, password: String) throws -> EncryptedPayload {
    let key = keyFromPassword(password)
    let nonce = AES.GCM.Nonce()
    let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce)

    var combined = sealed.ciphertext
    combined.append(sealed.tag)

    return EncryptedPayload(
      data: combined.base64EncodedString(),
      iv: Data(nonce).base64EncodedString()
    )
  }

  static func decrypt(_ payload: EncryptedPayload, password: String) throws -> String {
    guard let combined = Data(base64Encoded: payload.data),
          let iv = Data(base64Encoded: payload.iv) else {
      throw Error.invalidBase64
    }

    guard combined.count >= 16 else {
      throw Error.payloadTooShort
    }

    let ciphertext = combined.prefix(combined.count - 16)
    let tag = combined.suffix(16)
    let nonce = try AES.GCM.Nonce(data: iv)
    let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
    let opened = try AES.GCM.open(box, using: keyFromPassword(password))
    return String(decoding: opened, as: UTF8.self)
  }

  private static func keyFromPassword(_ password: String) -> SymmetricKey {
    let digest = SHA256.hash(data: Data(password.utf8))
    return SymmetricKey(data: Data(digest))
  }
}
