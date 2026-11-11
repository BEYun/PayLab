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
            PrimaryButton("보내기") { Task { await model.submit() } }
        }
        .padding(PaySpacing.medium)
        .background(PayColor.background)
        .overlay {
            if model.isSubmitting || model.outcome != nil {  // 결과 화면으로 넘어가는 동안에도 덮어 둔다
                VStack(spacing: PaySpacing.medium) {
                    ProgressView()
                    Text("보내는 중이에요").font(PayFont.title)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PayColor.background)
            }
        }
        .navigationTitle("송금 확인")
        .navigationBarBackButtonHidden(model.isSubmitting || model.outcome != nil)
    }
}
