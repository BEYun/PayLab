import Domain
import SwiftUI

@main
struct PayLabApp: App {
    private let repository = AppEnvironment.makeRepository(arguments: ProcessInfo.processInfo.arguments)

    var body: some Scene {
        WindowGroup { RootView(repository: repository) }
    }
}
