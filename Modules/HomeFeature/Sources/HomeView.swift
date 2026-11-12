import SwiftUI
import Domain
import DesignSystem

public struct HomeView: View {
    private let model: HomeModel
    private let onTransfer: (Account) -> Void
    @State private var historyAccount: Account?

    public init(model: HomeModel, onTransfer: @escaping (Account) -> Void) {
        self.model = model
        self.onTransfer = onTransfer
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: PaySpacing.medium) {
                if model.accounts.isEmpty && model.isLoading {
                    ProgressView()
                }
                ForEach(model.accounts) { account in
                    AccountRow(account: account, onOpenHistory: { historyAccount = $0 }, onTransfer: onTransfer)
                }
            }
            .padding(PaySpacing.medium)
        }
        .background(PayColor.background)
        .navigationTitle("내 계좌")
        .navigationDestination(item: $historyAccount) { account in
            HistoryView(model: model.makeHistoryModel(for: account))
        }
        .task { await model.load() }
    }
}
