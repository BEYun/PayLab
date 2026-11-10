import Testing
import DesignSystem

@Test(arguments: zip([0, 1_250_000, -1_000], ["0원", "1,250,000원", "-1,000원"]))
func formatWon(amount: Int, expected: String) {
    #expect(DesignSystem.formatWon(amount) == expected)
}
