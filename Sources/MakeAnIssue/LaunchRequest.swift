import Foundation

struct LaunchRequest: Codable, Equatable {
    let cwd: String
    let createdAtUnixSeconds: Int
}
