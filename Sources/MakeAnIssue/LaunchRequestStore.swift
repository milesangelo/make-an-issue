import Foundation

struct LaunchRequestStore {
    let requestDirectory: URL

    var requestFileURL: URL {
        requestDirectory.appendingPathComponent("launch-request.json", isDirectory: false)
    }

    init(requestDirectory: URL? = nil) {
        self.requestDirectory = requestDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/make-an-issue", isDirectory: true)
    }

    func write(_ request: LaunchRequest) throws {
        try FileManager.default.createDirectory(
            at: requestDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try JSONEncoder().encode(request)
        try data.write(to: requestFileURL, options: .atomic)
    }

    func consumeLatest() throws -> LaunchRequest? {
        guard FileManager.default.fileExists(atPath: requestFileURL.path) else {
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: requestFileURL)
        }

        do {
            let data = try Data(contentsOf: requestFileURL)
            return try JSONDecoder().decode(LaunchRequest.self, from: data)
        } catch DecodingError.dataCorrupted,
                DecodingError.keyNotFound,
                DecodingError.typeMismatch,
                DecodingError.valueNotFound {
            return nil
        }
    }
}
