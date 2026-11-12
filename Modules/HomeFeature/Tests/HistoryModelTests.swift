import Domain
import Foundation
import HomeFeature
import Testing

@MainActor
struct HistoryModelTests {
    let account = Account(id: "acc-a", name: "A", maskedNumber: "1", balance: 1_000)
    static let nov12 = Date(timeIntervalSince1970: 1_794_409_200)  // 2026-11-12 00:00 서울 (목)

    /// 서울 기준 두 날짜에 걸친 4건, 날짜순이 아닌 순서. 11/12 00:30은 UTC로는 11/11이다.
    let transactions = [
        Transaction(id: "store", date: nov12.addingTimeInterval(30 * 60), title: "편의점", amount: -3_500),         // 11/12 00:30
        Transaction(id: "salary", date: nov12.addingTimeInterval(-15 * 3600), title: "월급", amount: 300_000),     // 11/11 09:00
        Transaction(id: "deposit", date: nov12.addingTimeInterval(21.5 * 3600), title: "김하늘", amount: 12_000),  // 11/12 21:30
        Transaction(id: "cafe", date: nov12.addingTimeInterval(-3600), title: "카페", amount: -4_800),             // 11/11 23:00
    ]

    @Test func loadGroupsByDayNewestFirst() async {
        let model = HistoryModel(account: account, repository: StubBankingRepository(
            accounts: .success([]), transactions: .success(transactions)))
        await model.load()
        #expect(model.sections.map(\.id) == ["11월 12일 목요일", "11월 11일 수요일"])
        #expect(model.sections.map { $0.rows.map(\.id) } == [["deposit", "store"], ["cafe", "salary"]])
        #expect(model.isLoading == false)
        #expect(model.loadFailed == false)
    }

    @Test func rowFormats() async throws {
        let model = HistoryModel(account: account, repository: StubBankingRepository(
            accounts: .success([]), transactions: .success(transactions)))
        await model.load()
        let rows = model.sections.flatMap(\.rows)
        let deposit = try #require(rows.first { $0.id == "deposit" })
        #expect(deposit.title == "김하늘")
        #expect(deposit.amount == "+12,000원")
        #expect(deposit.time == "21:30")
        let store = try #require(rows.first { $0.id == "store" })
        #expect(store.amount == "-3,500원")
        #expect(store.time == "00:30")  // 서울 시각, 두 자리
    }

    @Test func loadFailureKeepsSections() async {
        let repository = StubBankingRepository(accounts: .success([]), transactions: .success(transactions))
        let model = HistoryModel(account: account, repository: repository)
        await model.load()
        let loaded = model.sections
        repository.setTransactions(.failure(.server(statusCode: 500)))
        await model.load()
        #expect(loaded.count == 2)
        #expect(model.sections == loaded)
        #expect(model.loadFailed == true)
        #expect(model.isLoading == false)
    }

    @Test func loadSuccessAfterFailureClearsError() async {
        let repository = StubBankingRepository(accounts: .success([]), transactions: .failure(.server(statusCode: 500)))
        let model = HistoryModel(account: account, repository: repository)
        await model.load()
        #expect(model.loadFailed == true)
        repository.setTransactions(.success(transactions))
        await model.load()
        #expect(model.loadFailed == false)
        #expect(model.sections.count == 2)
    }

    @Test func homeMakesHistoryModelWithSameRepository() async {
        let home = HomeModel(repository: StubBankingRepository(
            accounts: .success([account]), transactions: .success(transactions)))
        let model = home.makeHistoryModel(for: account)
        await model.load()
        #expect(model.account == account)
        #expect(model.sections.flatMap(\.rows).count == transactions.count)
    }
}
