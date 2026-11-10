import Testing
import Domain

@Test(arguments: zip([0, -1, 1, 50_000, 50_001], [false, false, true, true, false]))
func isValidAmount(amount: Int, expected: Bool) {
    #expect(TransferRule.isValidAmount(amount, balance: 50_000) == expected)
}
