import Synchronization
import Testing
@testable import PayLab

/// 바쁜 대기로 메인 스레드를 막는다. 잡힌 스택에 이 이름이 남도록 인라인하지 않는다.
@inline(never) func blockMainThread(milliseconds: Int) {
    let end = ContinuousClock.now + .milliseconds(milliseconds)
    while ContinuousClock.now < end {}
}

/// 감시 스레드가 넘기는 보고를 모은다.
private final class Reports: Sendable {
    private let reports = Mutex<[HangReport]>([])
    func append(_ report: HangReport) { reports.withLock { $0.append(report) } }
    var all: [HangReport] { reports.withLock { $0 } }
}

// 테스트 호스트(PayLab 앱)에서도 앱 전역 감시자(250ms)가 돈다. 그 hang 로그를 남기지 않도록 메인을 막는 시간은 250ms보다 넉넉히 짧다(최대 100ms).
@MainActor @Suite(.serialized)
struct HangMonitorTests {
    @Test func reportsBlockedMainThread() async throws {
        let reports = Reports()
        let monitor = HangMonitor(threshold: .milliseconds(30), onHang: { reports.append($0) })
        monitor.start()
        defer { monitor.stop() }
        blockMainThread(milliseconds: 100)
        let deadline = ContinuousClock.now + .seconds(2)
        while reports.all.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let report = try #require(reports.all.first { $0.frames.contains { $0.symbol?.contains("blockMainThread") == true } })
        #expect(report.durationMs >= 60)  // 감시 스레드가 늦게 시작해도 40ms 여유
    }

    @Test func ignoresShortBlocks() async throws {
        let reports = Reports()
        let monitor = HangMonitor(threshold: .milliseconds(200), onHang: { reports.append($0) })
        monitor.start()
        defer { monitor.stop() }
        blockMainThread(milliseconds: 50)
        try await Task.sleep(for: .milliseconds(500))
        #expect(reports.all.isEmpty)
    }

    @Test func logLinesFormat() {
        let report = HangReport(id: 3, durationMs: 412, frames: [
            HangFrame(address: 0x1a2b, image: "PayLab.debug.dylib", imageBase: 0x1000, symbol: "$s4main"),
            HangFrame(address: 0x10, image: "libsystem_kernel.dylib", imageBase: 0x0, symbol: nil),
        ])
        #expect(HangMonitor.logLines(report) == [
            "hang id=3 duration=412ms frames=2",
            "hang frame id=3 #0 PayLab.debug.dylib 0x1a2b base=0x1000 $s4main",
            "hang frame id=3 #1 libsystem_kernel.dylib 0x10 base=0x0 ?",
        ])
    }
}
