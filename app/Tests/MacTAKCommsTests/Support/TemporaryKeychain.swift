// A throwaway keychain file for the identity tests: never the login
// keychain, never on the user's search list, deleted after each test.
// SecKeychainCreate is deprecated, but it is the only way to make one, so
// it lives here rather than in the library.

import Foundation
import Security
@testable import MacTAKComms

final class TemporaryKeychain {
    let store: IdentityStore
    private let keychain: SecKeychain

    init() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactak-test-\(UUID().uuidString.prefix(8)).keychain-db").path
        let password = UUID().uuidString
        var keychain: SecKeychain?
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychain)
        guard status == errSecSuccess, let keychain else { throw IdentityError("creating a keychain", status) }
        self.keychain = keychain
        store = IdentityStore(keychain: keychain)
    }

    func delete() {
        SecKeychainDelete(keychain)
    }
}
