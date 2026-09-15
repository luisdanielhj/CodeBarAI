import Foundation

/// A changed file that looks like it holds a secret.
nonisolated struct SensitiveFile: Identifiable, Hashable, Sendable {
    var path: String
    /// Why it was flagged, e.g. "private key".
    var reason: String

    var id: String { path }
}

/// Flags credentials and keys that `git add -A` would sweep into a commit.
///
/// This is a deliberately conservative name-based check: it warns, it never blocks.
nonisolated enum SensitiveFileScanner {
    /// File extensions that almost always mean key material.
    private static let secretExtensions: [String: String] = [
        "pem": "private key or certificate",
        "key": "private key",
        "p12": "certificate bundle",
        "pfx": "certificate bundle",
        "keystore": "keystore",
        "jks": "Java keystore",
        "ppk": "PuTTY private key",
        "mobileprovision": "provisioning profile",
        "cer": "certificate",
        "der": "certificate"
    ]

    /// Exact file names, matched case-insensitively.
    private static let secretNames: [String: String] = [
        ".env": "environment file",
        ".netrc": "stored credentials",
        ".npmrc": "may contain an auth token",
        ".pgpass": "stored credentials",
        "id_rsa": "SSH private key",
        "id_dsa": "SSH private key",
        "id_ecdsa": "SSH private key",
        "id_ed25519": "SSH private key",
        "credentials": "stored credentials",
        "credentials.json": "service account credentials",
        "secrets.json": "secrets file",
        "secrets.yaml": "secrets file",
        "secrets.yml": "secrets file"
    ]

    static func scan(_ changes: [GitFileChange]) -> [SensitiveFile] {
        changes.compactMap { change in
            // A file being removed from the repository is a fix, not a leak.
            guard change.kind != .deleted else { return nil }
            guard let reason = reason(forFileNamed: change.fileName) else { return nil }
            return SensitiveFile(path: change.path, reason: reason)
        }
    }

    private static func reason(forFileNamed fileName: String) -> String? {
        let lowercased = fileName.lowercased()

        if let reason = secretNames[lowercased] { return reason }

        // `.env.local`, `.env.production` and friends.
        if lowercased.hasPrefix(".env.") && !lowercased.hasSuffix(".example") && !lowercased.hasSuffix(".sample") {
            return "environment file"
        }

        let fileExtension = (lowercased as NSString).pathExtension
        if !fileExtension.isEmpty, let reason = secretExtensions[fileExtension] {
            // A public certificate is common and harmless in a repository.
            if lowercased.contains("public") { return nil }
            return reason
        }

        return nil
    }
}
