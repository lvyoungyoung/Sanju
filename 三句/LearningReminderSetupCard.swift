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
                Toggle(isOn: reminderEnabledBinding) {
                    Label(L10n.string("profile.section.learning_reminder", "学习提醒"), systemImage: "bell")
                        .font(.body.weight(.medium))
                        .foregroundStyle(AppTextColor.primary)
                }
                    .tint(AppPalette.accentText)
                    .disabled(isSaving)
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppPalette.accentText)
                }
            }
            .frame(minHeight: 24)

            if isEnabled && !isSaving {
                Button(action: onEditTime) {
                    HStack {
                        Text(L10n.string("profile.learning_reminder.time", "提醒时间"))
                        Spacer(minLength: AppSpacing.small)
                        Text(reminderTimeText).monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .foregroundStyle(AppTextColor.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 32)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: AppFontSize.caption))
                    .foregroundStyle(statusIsError ? Color.red.opacity(0.75) : AppTextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
