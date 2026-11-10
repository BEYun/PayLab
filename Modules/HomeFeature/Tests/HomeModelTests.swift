import Domain
import HomeFeature
import Testing

@MainActor
struct HomeModelTests {
    let a = Account(id: "acc-a", name: "A", maskedNumber: "1", balance: 1_000)
    let b = Account(id: "acc-b", name: "B", maskedNumber: "2", balance: 2_000)

    @Test func loadReplacesAccounts() async {
        let model = HomeModel(repository: StubBankingRepository(accounts: .success([a, b])))
        await model.load()
        #expect(model.accounts == [a, b])
        #expect(model.isLoading == false)
    }

    @Test func loadFailureKeepsPreviousAccounts() async {
        let repository = StubBankingRepository(accounts: .success([a]))
        let model = HomeModel(repository: repository)
        await model.load()
        repository.setAccounts(.failure(.server(statusCode: 500)))
        await model.load()
        #expect(model.accounts == [a])
        #expect(model.isLoading == false)
    }
}
