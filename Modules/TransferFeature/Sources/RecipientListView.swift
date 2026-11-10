import SwiftUI
import Domain
import DesignSystem

struct RecipientListView: View {
    let model: TransferModel
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: PaySpacing.small) {
                ForEach(model.recipients) { recipient in
                    Button { model.select(recipient) } label: {
                        VStack(alignment: .leading, spacing: PaySpacing.small) {
                            Text(recipient.name).font(PayFont.body).foregroundStyle(PayColor.textPrimary)
                            Text("\(recipient.bankName) \(recipient.maskedNumber)")
                                .font(PayFont.caption).foregroundStyle(PayColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(PaySpacing.medium)
                        .background(PayColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(PaySpacing.medium)
        }
        .background(PayColor.background)
        .navigationTitle("누구에게 보낼까요?")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("닫기", action: onFinish) }
        }
        .task { await model.loadRecipients() }
    }
}
