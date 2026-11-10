import Domain
import HomeFeature
import SwiftUI
import TransferFeature

struct RootView: View {
    private let repository: any BankingRepository
    @State private var homeModel: HomeModel
    @State private var transferAccount: Account?

    init(repository: any BankingRepository) {
        self.repository = repository
        _homeModel = State(initialValue: HomeModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            HomeView(model: homeModel, onTransfer: { transferAccount = $0 })
        }
        .sheet(item: $transferAccount, onDismiss: { Task { await homeModel.load() } }) { account in
            TransferFlowView(
                model: TransferModel(fromAccount: account, repository: repository),
                onFinish: { transferAccount = nil })
        }
    }
}
