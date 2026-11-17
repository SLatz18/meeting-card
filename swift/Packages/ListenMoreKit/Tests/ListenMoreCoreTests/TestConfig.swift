import Foundation
@testable import ListenMoreCore

/// The Kit's built-in generic config. Kit tests never read a host's tuned config file.
enum TestConfig {
    static func load(overrideURL: URL? = nil) throws -> ListenMoreConfig {
        try ListenMoreConfig.load(overrideURL: overrideURL)
    }
}
