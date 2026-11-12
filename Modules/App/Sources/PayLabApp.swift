import Domain
import SwiftUI

@main
struct PayLabApp: App {
    private let repository = AppEnvironment.makeRepository(arguments: ProcessInfo.processInfo.arguments)
    #if DEBUG
    private let hangMonitor = HangMonitor(onHang: HangMonitor.log)
    #endif

    init() {
        #if DEBUG
        hangMonitor.start()
        #endif
    }

    var body: some Scene {
        WindowGroup { RootView(repository: repository) }
    }
}
