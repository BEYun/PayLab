import SwiftUI
import DesignSystem

public struct HistoryView: View {
    @State private var model: HistoryModel

    public init(model: HistoryModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            if model.loadFailed {
                Text("거래 내역을 불러오지 못했어요")
                    .font(PayFont.body)
                    .foregroundStyle(PayColor.danger)
            }
            if model.sections.isEmpty && model.isLoading {
                ProgressView()
            }
            ForEach(model.sections) { section in
                Section(section.id) {
                    ForEach(section.rows) { row in
                        HistoryRow(row: row)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("거래 내역")
        .task { await model.load() }
    }
}

private struct HistoryRow: View {
    let row: HistoryModel.Row

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: PaySpacing.small) {
                Text(row.title)
                    .font(PayFont.body)
                    .foregroundStyle(PayColor.textPrimary)
                Text(row.time)
                    .font(PayFont.caption)
                    .foregroundStyle(PayColor.textSecondary)
            }
            Spacer()
            Text(row.amount)
                .font(PayFont.body)
                .foregroundStyle(PayColor.textPrimary)
        }
    }
}
