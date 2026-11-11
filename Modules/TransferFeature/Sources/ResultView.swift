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
            case .pending:
                Text("확인 중이에요").font(PayFont.title)
                Text("송금이 처리됐는지 아직 몰라요. 잠시 후 다시 확인해 주세요.")
                    .font(PayFont.body).foregroundStyle(PayColor.textSecondary)
                    .multilineTextAlignment(.center)
            case nil:
                EmptyView()
            }
            Spacer()
            if model.outcome == .pending {
                PrimaryButton("다시 확인", isEnabled: !model.isChecking) { Task { await model.recheck() } }
            }
            PrimaryButton("확인", action: onFinish)
        }
        .padding(PaySpacing.medium)
        .background(PayColor.background)
        .navigationBarBackButtonHidden(true)
    }
}
