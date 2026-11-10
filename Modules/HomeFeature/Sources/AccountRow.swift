import SwiftUI
import Domain
import DesignSystem

struct AccountRow: View {
    let account: Account
    let onTransfer: (Account) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: PaySpacing.small) {
                Text(account.name)
                    .font(PayFont.body)
                    .foregroundStyle(PayColor.textPrimary)
                Text(account.maskedNumber)
                    .font(PayFont.caption)
                    .foregroundStyle(PayColor.textSecondary)
                Text(formatWon(account.balance))
                    .font(PayFont.title)
                    .foregroundStyle(PayColor.textPrimary)
            }
            Spacer()
            Button { onTransfer(account) } label: {
                Text("송금")
                    .font(PayFont.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, PaySpacing.medium)
                    .frame(minHeight: 44)
                    .background(PayColor.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(PaySpacing.medium)
        .background(PayColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
