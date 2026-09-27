import Foundation

private final class LocalizationBundleMarker {}

enum AppStrings {
    private static let bundle = Bundle(for: LocalizationBundleMarker.self)

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let localized = NSLocalizedString(
            key,
            tableName: nil,
            bundle: bundle,
            value: key,
            comment: ""
        )
        guard !arguments.isEmpty else { return localized }
        return String(format: localized, locale: Locale.current, arguments: arguments)
    }
}
