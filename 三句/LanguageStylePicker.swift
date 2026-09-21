import SwiftUI
import UIKit

// UIKit supports disabling individual segments, including their native dimmed styling.
struct LanguageStylePicker: UIViewRepresentable {
    @Binding var selection: LanguageStyle
    let englishLevel: EnglishLevel

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: LanguageStyle.allCases.map(\.displayTitle))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setTitleTextAttributes([.foregroundColor: UIColor.tertiaryLabel], for: .disabled)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.accessibilityLabel = L10n.string("profile.preference.language_style", "语言风格")
        for (index, style) in LanguageStyle.allCases.enumerated() {
            control.setTitle(style.displayTitle, forSegmentAt: index)
            control.setEnabled(englishLevel.allows(style), forSegmentAt: index)
        }
        control.selectedSegmentIndex = LanguageStyle.allCases.firstIndex(of: englishLevel.resolvedStyle(selection)) ?? 0
    }

    final class Coordinator: NSObject {
        var parent: LanguageStylePicker

        init(_ parent: LanguageStylePicker) { self.parent = parent }

        @objc func changed(_ control: UISegmentedControl) {
            let index = control.selectedSegmentIndex
            guard LanguageStyle.allCases.indices.contains(index) else { return }
            let style = LanguageStyle.allCases[index]
            if parent.englishLevel.allows(style) { parent.selection = style }
            // The binding may reject a change because of preference rate limiting.
            control.selectedSegmentIndex = LanguageStyle.allCases.firstIndex(of: parent.englishLevel.resolvedStyle(parent.selection)) ?? 0
        }
    }
}
