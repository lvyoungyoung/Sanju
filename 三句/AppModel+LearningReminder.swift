import Foundation

extension AppModel {
    var learningReminderDisplayText: String {
        formattedLearningReminderTime(hour: learningReminderHour, minute: learningReminderMinute)
    }

    var learningReminderDate: Date {
        dateForLearningReminder(hour: learningReminderHour, minute: learningReminderMinute)
    }

    func configureLearningReminder(at date: Date) async throws {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else {
            throw LearningReminderError.invalidTime
        }

        try await LearningReminderScheduler.scheduleDailyReminder(hour: hour, minute: minute)
        learningReminderHour = hour
        learningReminderMinute = minute
        isLearningReminderEnabled = true
        persistLearningReminderSettings()
    }

    func disableLearningReminder() {
        LearningReminderScheduler.cancelDailyReminder()
        isLearningReminderEnabled = false
        persistLearningReminderSettings()
    }

    func loadLearningReminderSettings() {
        isLearningReminderEnabled = defaults.bool(forKey: AppStorageKey.learningReminderEnabled)
        if defaults.object(forKey: AppStorageKey.autoSpeakSolvedSentence) != nil {
            isAutoSpeakingSolvedSentenceEnabled = defaults.bool(forKey: AppStorageKey.autoSpeakSolvedSentence)
        } else {
            isAutoSpeakingSolvedSentenceEnabled = true
        }

        if defaults.object(forKey: AppStorageKey.learningReminderHour) != nil {
            learningReminderHour = defaults.integer(forKey: AppStorageKey.learningReminderHour)
        }

        if defaults.object(forKey: AppStorageKey.learningReminderMinute) != nil {
            learningReminderMinute = defaults.integer(forKey: AppStorageKey.learningReminderMinute)
        }
    }

    func setAutoSpeakingSolvedSentenceEnabled(_ isEnabled: Bool) {
        isAutoSpeakingSolvedSentenceEnabled = isEnabled
        defaults.set(isEnabled, forKey: AppStorageKey.autoSpeakSolvedSentence)
    }

    private func persistLearningReminderSettings() {
        defaults.set(isLearningReminderEnabled, forKey: AppStorageKey.learningReminderEnabled)
        defaults.set(learningReminderHour, forKey: AppStorageKey.learningReminderHour)
        defaults.set(learningReminderMinute, forKey: AppStorageKey.learningReminderMinute)
    }

    private func dateForLearningReminder(hour: Int, minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? .now
    }

    private func formattedLearningReminderTime(hour: Int, minute: Int) -> String {
        let date = dateForLearningReminder(hour: hour, minute: minute)
        return Self.learningReminderTimeFormatter.string(from: date)
    }

    private static let learningReminderTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
