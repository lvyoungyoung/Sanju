import SwiftUI

struct EnglishLevelPicker: View {
    @Binding var selection: EnglishLevel

    var body: some View {
        PreferenceSegmentedControl(
            titles: EnglishLevel.allCases.map(\.displayTitle),
            selection: Binding(
                get: { EnglishLevel.allCases.firstIndex(of: selection) ?? 0 },
                set: { index in
                    guard EnglishLevel.allCases.indices.contains(index) else { return }
                    selection = EnglishLevel.allCases[index]
                }
            ),
            accessibilityTitle: L10n.string("profile.preference.english_level", "难度")
        )
        .frame(height: 44)
    }
}
