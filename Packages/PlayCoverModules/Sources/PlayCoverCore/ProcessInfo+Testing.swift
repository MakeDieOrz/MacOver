import Foundation

public extension ProcessInfo {
    static var isRunningUnitTests: Bool {
        processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
