import Foundation

/// 1250000 → "1,250,000원". ko_KR 숫자 형식 + "원".
public func formatWon(_ amount: Int) -> String {
    let number = amount.formatted(.number.locale(Locale(identifier: "ko_KR")))
    return "\(number)원"
}
