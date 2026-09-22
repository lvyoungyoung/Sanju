import SwiftUI

struct LearningReminderSetupCard: View {
    @Binding var reminderTime: Date
    let isEnabled: Bool
    let isSaving: Bool
    let statusMessage: String?
    let statusIsError: Bool
    let onSave: () -> Void
    let onDisable: () -> Void
    let onEditTime: () -> Void

    private var reminderEnabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { isOn in
                if isOn {
                    onSave()
                } else {
                    onDisable()
                }
            }
        )
    }

    private var reminderTimeText: String {
        Self.timeFormatter.string(from: reminderTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.medium) {
                Toggle("", isOn: reminderEnabledBinding)
                    .labelsHidden()
                    .tint(AppPalette.accentText)
                    .disabled(isSaving)

                Spacer(minLength: 0)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppPalette.accentText)
                } else if isEnabled {
                    Button(action: onEditTime) {
                        Text(reminderTimeText)
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color(red: 0.74, green: 0.39, blue: 0.10))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AppPalette.apricot)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: AppFontSize.caption))
                    .foregroundStyle(statusIsError ? Color.red.opacity(0.75) : AppTextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppSurfaceColor.card)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
