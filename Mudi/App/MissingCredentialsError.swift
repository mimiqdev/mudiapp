import Foundation

struct MissingCredentialsError: LocalizedError {
    var errorDescription: String? {
        "No saved SSH credentials. Edit this host to add a password or private key."
    }
}
