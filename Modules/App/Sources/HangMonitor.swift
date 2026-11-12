import Foundation
import os
import Synchronization

private let hangLog = Logger(subsystem: "com.example.paylab", category: "hang")

struct HangFrame: Sendable, Equatable {
    let address: UInt
    let image: String  // 이미지 파일 이름 (경로 없음)
    let imageBase: UInt
    let symbol: String?
}

struct HangReport: Sendable, Equatable {
    let id: Int
    let durationMs: Int
    let frames: [HangFrame]  // 가장 안쪽이 먼저, 최대 64
}

/// 감시 스레드가 메인 큐에 신호를 보내고, threshold 안에 답이 없으면 그때 메인 스레드 스택을 잡는다.
/// 메인이 답하면 지속 시간과 함께 onHang을 한 번 부른다. onHang은 감시 스레드에서 불린다.
final class HangMonitor: Sendable {
    private static let maxFrames = 64
    private let threshold: Duration
    private let onHang: @Sendable (HangReport) -> Void
    private let stopped = Atomic<Bool>(false)

    init(threshold: Duration = .milliseconds(250), onHang: @escaping @Sendable (HangReport) -> Void) {
        self.threshold = threshold
        self.onHang = onHang
    }

    /// 메인 스레드의 mach 포트와 스택 범위를 여기서 잡는다.
    @MainActor func start() {
        let mainThread = pthread_mach_thread_np(pthread_self())
        let stackTop = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        let stack = (stackTop - UInt(pthread_get_stacksize_np(pthread_self())))..<stackTop
        let watcher = Thread { [self] in watch(mainThread: mainThread, stack: stack) }
        watcher.name = "HangMonitor"
        watcher.qualityOfService = .userInteractive  // 늦게 깨면 hang을 놓치거나 지속 시간이 짧게 찍힌다
        watcher.start()
    }

    func stop() {
        stopped.store(true, ordering: .relaxed)
    }

    static func logLines(_ report: HangReport) -> [String] {
        ["hang id=\(report.id) duration=\(report.durationMs)ms frames=\(report.frames.count)"]
            + report.frames.enumerated().map { index, frame in
                "hang frame id=\(report.id) #\(index) \(frame.image) 0x\(String(frame.address, radix: 16))"
                    + " base=0x\(String(frame.imageBase, radix: 16)) \(frame.symbol ?? "?")"
            }
    }

    static func log(_ report: HangReport) {
        for line in logLines(report) {
            hangLog.error("\(line, privacy: .public)")
        }
    }

    private func watch(mainThread: thread_act_t, stack: Range<UInt>) {
        let interval = threshold / 5  // 신호 간격이자 hang 중 stop() 확인 간격
        var hangID = 0
        while !stopped.load(ordering: .relaxed) {
            let pong = DispatchSemaphore(value: 0)
            let sent = ContinuousClock.now
            DispatchQueue.main.async { pong.signal() }
            if pong.wait(timeout: .now() + threshold / .seconds(1)) == .timedOut {
                let frames = Self.mainStackAddresses(mainThread: mainThread, stack: stack).map(Self.frame)
                while pong.wait(timeout: .now() + interval / .seconds(1)) == .timedOut {
                    if stopped.load(ordering: .relaxed) { return }
                }
                hangID += 1
                onHang(HangReport(id: hangID, durationMs: Int((ContinuousClock.now - sent) / .milliseconds(1)), frames: frames))
            }
            Thread.sleep(forTimeInterval: interval / .seconds(1))
        }
    }

    /// 메인 스레드를 멈추고 pc, lr, 프레임 포인터 체인의 복귀 주소를 읽는다.
    /// 멈춘 동안에는 미리 준비한 메모리·값만 쓰고 Swift 런타임(메타데이터·제네릭·지연 초기화)과 malloc을 부르지 않는다.
    /// 메인이 그 잠금을 쥔 채 멈췄다면 감시 스레드가 영원히 기다려 메인을 풀지 못한다.
    /// Debug(-Onone) 기계어에서 thread_suspend와 thread_resume 사이 호출을 `otool -tV`로 확인한다.
    private static func mainStackAddresses(mainThread: thread_act_t, stack: Range<UInt>) -> [UInt] {
        #if arch(arm64)
        let addressMask: UInt = 0x0000_7FFF_FFFF_FFFF  // 포인터 인증·async 프레임 표시 비트를 지운다
        let capacity = maxFrames
        let (stackLow, stackHigh) = (stack.lowerBound, stack.upperBound)
        let addresses = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
        defer { addresses.deallocate() }
        let state = UnsafeMutablePointer<arm_thread_state64_t>.allocate(capacity: 1)
        defer { state.deallocate() }
        let stateWords = UnsafeMutableRawPointer(state).assumingMemoryBound(to: natural_t.self)
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let flavor = thread_state_flavor_t(ARM_THREAD_STATE64)
        var count = 0
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
        if thread_get_state(mainThread, flavor, stateWords, &stateCount) == KERN_SUCCESS {
            addresses[0] = UInt(state.pointee.__pc) & addressMask
            addresses[1] = UInt(state.pointee.__lr) & addressMask
            count = 2
            var fp = UInt(state.pointee.__fp) & addressMask
            while count < capacity, fp % 8 == 0, fp >= stackLow, fp + 16 <= stackHigh,
                  let record = UnsafePointer<UInt>(bitPattern: fp) {  // [0] 바깥 프레임 fp, [1] 복귀 주소
                let returnAddress = record[1] & addressMask
                if returnAddress == 0 { break }
                addresses[count] = returnAddress
                count += 1
                let next = record[0] & addressMask
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        return Array(UnsafeBufferPointer(start: addresses, count: count))
        #else
        return []
        #endif
    }

    private static func frame(_ address: UInt) -> HangFrame {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let path = info.dli_fname else {
            return HangFrame(address: address, image: "?", imageBase: 0, symbol: nil)
        }
        return HangFrame(address: address,
                         image: (String(cString: path) as NSString).lastPathComponent,
                         imageBase: UInt(bitPattern: info.dli_fbase),
                         symbol: info.dli_sname.map { String(cString: $0) })
    }
}
