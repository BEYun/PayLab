import SwiftUI
import DesignSystem

public struct TransferFlowView: View {
    @State private var model: TransferModel
    private let onFinish: () -> Void

    /// model은 @State로 보관한다 (부모가 다시 그려져도 진행 상태 유지).
    public init(model: TransferModel, onFinish: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onFinish = onFinish
    }

    public var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            RecipientListView(model: model, onFinish: onFinish)
                .navigationDestination(for: TransferModel.Step.self) { step in
                    switch step {
                    case .amount: AmountInputView(model: model)
                    case .confirm: ConfirmView(model: model)
                    case .result: ResultView(model: model, onFinish: onFinish)
                    }
                }
        }
    }
}
