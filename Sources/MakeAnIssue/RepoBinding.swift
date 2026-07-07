import Foundation

struct RepoBinding: Equatable, Codable {
    let rootURL: URL
    let displayName: String
    let displayPath: String

    static func resolve(from cwd: URL, fileManager: FileManager = .default) -> RepoBinding? {
        var currentURL = cwd.standardizedFileURL

        while true {
            let gitMarkerURL = currentURL.appendingPathComponent(".git")
            if isGitMarker(at: gitMarkerURL, fileManager: fileManager) {
                return RepoBinding(
                    rootURL: currentURL,
                    displayName: currentURL.lastPathComponent,
                    displayPath: currentURL.path
                )
            }

            if currentURL.path == "/" {
                return nil
            }

            currentURL = currentURL.deletingLastPathComponent().standardizedFileURL
        }
    }

    private static func isGitMarker(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }

        return isDirectory.boolValue || isRegularFile(at: url, fileManager: fileManager)
    }

    private static func isRegularFile(at url: URL, fileManager: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }

        return values.isRegularFile == true
    }
}
