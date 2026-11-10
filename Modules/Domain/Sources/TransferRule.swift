import Foundation

public enum TransferRule {
    /// amount > 0 && amount <= balance
    public static func isValidAmount(_ amount: Int, balance: Int) -> Bool {
        amount > 0 && amount <= balance
    }
}
