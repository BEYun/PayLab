import Foundation

public struct Account: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String          // "PayLab 통장"
    public let maskedNumber: String  // "3333-01-****21"
    public var balance: Int          // 원

    public init(id: String, name: String, maskedNumber: String, balance: Int) {
        self.id = id
        self.name = name
        self.maskedNumber = maskedNumber
        self.balance = balance
    }
}

public struct Recipient: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let bankName: String
    public let maskedNumber: String

    public init(id: String, name: String, bankName: String, maskedNumber: String) {
        self.id = id
        self.name = name
        self.bankName = bankName
        self.maskedNumber = maskedNumber
    }
}

public struct TransferRequest: Hashable, Codable, Sendable {
    public let fromAccountID: String
    public let recipientID: String
    public let amount: Int

    public init(fromAccountID: String, recipientID: String, amount: Int) {
        self.fromAccountID = fromAccountID
        self.recipientID = recipientID
        self.amount = amount
    }
}

public struct TransferReceipt: Hashable, Codable, Sendable {
    public let transferID: String
    public let amount: Int
    public let balanceAfter: Int

    public init(transferID: String, amount: Int, balanceAfter: Int) {
        self.transferID = transferID
        self.amount = amount
        self.balanceAfter = balanceAfter
    }
}

public struct Transaction: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let date: Date
    public let title: String
    public let amount: Int  // 원. 입금 +, 출금 -

    public init(id: String, date: Date, title: String, amount: Int) {
        self.id = id
        self.date = date
        self.title = title
        self.amount = amount
    }
}
