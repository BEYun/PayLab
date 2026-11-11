import SwiftUI
import Domain
import DesignSystem

struct ConfirmView: View {
    let model: TransferModel

    var body: some View {
        VStack(alignment: .leading, spacing: PaySpacing.medium) {
            Text("\(model.selectedRecipient?.name ?? "")님에게 \(formatWon(model.amount ?? 0))을 보낼까요?")
                .font(PayFont.title)
            Text("출금 계좌 \(model.fromAccount.name)")
                .font(PayFont.caption).foregroundStyle(PayColor.textSecondary)
            Spacer()
            PrimaryButton("보내기", isEnabled: !model.isSubmitting) { Task { await model.submit() } }
        }
        .padding(PaySpacing.medium)
        .background(PayColor.background)
        .navigationTitle("송금 확인")
        .navigationBarBackButtonHidden(model.isSubmitting)
    }
}
