import SwiftUI

public enum PayColor {
    public static let primary = Color(red: 0.31, green: 0.27, blue: 0.90)
    public static let background = Color(.systemBackground)
    public static let surface = Color(.secondarySystemBackground)
    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary
    public static let danger = Color.red
}

public enum PaySpacing {
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 24
}

public enum PayFont {
    public static let title = Font.system(size: 26, weight: .bold)
    public static let body = Font.system(size: 17)
    public static let caption = Font.system(size: 14)
}
