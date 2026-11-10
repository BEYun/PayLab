import SwiftUI
import Domain
import DesignSystem

struct AmountInputView: View {
    @Bindable var model: TransferModel

    var body: some View {
        VStack(alignment: .leading, spacing: PaySpacing.medium) {
            Text("출금: \(model.fromAccount.name) · 잔액 \(formatWon(model.fromAccount.balance))")
                .font(PayFont.caption).foregroundStyle(PayColor.textSecondary)
            TextField("금액", text: $model.amountText)
                .keyboardType(.numberPad)
                .font(PayFont.title)
            Spacer()
            PrimaryButton("다음", isEnabled: model.canProceed) { model.proceedToConfirm() }
        }
        .padding(PaySpacing.medium)
        .background(PayColor.background)
        .navigationTitle("얼마를 보낼까요?")
    }
}
