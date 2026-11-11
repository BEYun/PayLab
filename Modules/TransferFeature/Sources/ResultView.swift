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
                if let receipt {
                    Text("남은 잔액 \(formatWon(receipt.balanceAfter))")
                        .font(PayFont.body).foregroundStyle(PayColor.textSecondary)
                }
            case .failure(let reason):
                Text("송금 실패").font(PayFont.title).foregroundStyle(PayColor.danger)
                Text(reason.message).font(PayFont.body).foregroundStyle(PayColor.textSecondary)
            case .unknown:
                Text("결과를 확인하지 못했어요").font(PayFont.title)
                Text("홈에서 잔액을 확인해 주세요.")
                    .font(PayFont.body).foregroundStyle(PayColor.textSecondary)
            case nil:
                EmptyView()
            }
            Spacer()
            PrimaryButton("확인", action: onFinish)
        }
        .padding(PaySpacing.medium)
        .background(PayColor.background)
        .navigationBarBackButtonHidden(true)
    }
}
