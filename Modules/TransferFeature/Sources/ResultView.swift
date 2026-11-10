import SwiftUI
import Domain
import DesignSystem

struct ResultView: View {
    let model: TransferModel
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: PaySpacing.medium) {
            Spacer()
            switch model.outcome {
            case .success(let receipt):
                Text("보냈어요").font(PayFont.title)
                Text("남은 잔액 \(formatWon(receipt.balanceAfter))")
                    .font(PayFont.body).foregroundStyle(PayColor.textSecondary)
            default:
                Text("송금 실패").font(PayFont.title).foregroundStyle(PayColor.danger)
            }
            Spacer()
            PrimaryButton("확인", action: onFinish)
        }
        .padding(PaySpacing.medium)
        .background(PayColor.background)
        .navigationBarBackButtonHidden(true)
    }
}
