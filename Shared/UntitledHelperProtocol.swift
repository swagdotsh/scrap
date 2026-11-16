import Foundation

nonisolated let untitledHelperServiceName = "com.swagrelated.scrap.untitled-helper"

@objc nonisolated protocol UntitledHelperProtocol {
    func currentPlayback(reply: @escaping @Sendable (Data?) -> Void)
    func diagnostics(header: String, reply: @escaping @Sendable (String) -> Void)
}
