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
                    .tint(Color(red: 0.91, green: 0.52, blue: 0.17))
                    .disabled(isSaving)

                Spacer(minLength: 0)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(red: 0.91, green: 0.52, blue: 0.17))
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
                                    .fill(Color(red: 1.00, green: 0.92, blue: 0.82))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: AppFontSize.caption))
                    .foregroundStyle(statusIsError ? Color.red.opacity(0.75) : Color(red: 0.35, green: 0.48, blue: 0.28))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
