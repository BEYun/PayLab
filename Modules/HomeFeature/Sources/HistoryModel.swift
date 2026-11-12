import DesignSystem
import Domain
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.example.paylab", category: "history")

@MainActor @Observable
public final class HistoryModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String      // 거래 id
        public let title: String
        public let time: String    // "21:30"
        public let amount: String  // "+12,000원" / "-3,500원"
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let id: String  // 날짜 제목 "11월 12일 목요일"
        public let rows: [Row]
    }

    public let account: Account
    public private(set) var sections: [Section] = []
    public private(set) var isLoading = false
    public private(set) var loadFailed = false

    private let repository: any BankingRepository

    public init(account: Account, repository: any BankingRepository) {
        self.account = account
        self.repository = repository
    }

    /// fetchTransactions 성공 시 sections 교체. 실패 시 기존 sections 유지, loadFailed = true.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        log.debug("load start account=\(self.account.id, privacy: .public)")
        do {
            let transactions = try await repository.fetchTransactions(accountID: account.id)
            sections = await Self.makeSections(transactions)
            log.info("load ok account=\(self.account.id, privacy: .public) count=\(transactions.count, privacy: .public) sections=\(self.sections.count, privacy: .public)")
        } catch {
            loadFailed = true
            log.error("load failed account=\(self.account.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// 날짜(서울) 내림차순으로 묶고, 묶음 안은 시각 내림차순.
    /// 거래가 수천 건이라 메인 밖에서 하고, 포맷터는 한 번만 만든다.
    @concurrent nonisolated static func makeSections(_ transactions: [Transaction]) async -> [Section] {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "ko_KR")
        dayFormatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        dayFormatter.dateFormat = "M월 d일 EEEE"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "ko_KR")
        timeFormatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        timeFormatter.dateFormat = "HH:mm"
        var groups: [(day: String, rows: [Row])] = []
        for transaction in transactions.sorted(by: { $0.date > $1.date }) {
            let day = dayFormatter.string(from: transaction.date)
            let row = Row(id: transaction.id, title: transaction.title,
                          time: timeFormatter.string(from: transaction.date),
                          amount: (transaction.amount < 0 ? "-" : "+") + formatWon(abs(transaction.amount)))
            if groups.last?.day == day {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append((day, [row]))
            }
        }
        return groups.map { Section(id: $0.day, rows: $0.rows) }
    }
}
