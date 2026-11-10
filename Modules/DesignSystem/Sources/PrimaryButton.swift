import SwiftUI

/// 화면 너비를 채우는 기본 버튼. 비활성이면 회색 배경, 탭 무시.
public struct PrimaryButton: View {
    private let title: String
    private let isEnabled: Bool
    private let action: () -> Void

    public init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(PayFont.body)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(PaySpacing.medium)
                .background(isEnabled ? PayColor.primary : Color.gray)
        }
        .disabled(!isEnabled)
    }
}

#Preview {
    VStack(spacing: PaySpacing.medium) {
        PrimaryButton("다음") {}
        PrimaryButton("다음", isEnabled: false) {}
    }
    .padding(PaySpacing.large)
}
