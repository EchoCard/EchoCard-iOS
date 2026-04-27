import Foundation

/// Formats a Date as a human-friendly relative string based on the app language.
///
/// Rules:
///   - Today     → "今天 14:23"  /  "Today 2:23 PM"
///   - Yesterday → "昨天 09:11"  /  "Yesterday 9:11 AM"
///   - Within 7 days → "星期三 16:00"  /  "Wed 4:00 PM"
///   - Same year → "3月5日"  /  "Mar 5"
///   - Older     → "2024年3月5日"  /  "Mar 5, 2024"
struct RelativeDateFormatter {

    let language: Language

    private var locale: Locale {
        Locale(identifier: language == .zh ? "zh_CN" : "en_US")
    }

    func string(from date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) {
            return "\(l("今天", "Today")) \(timeString(date))"
        }
        if calendar.isDateInYesterday(date) {
            return "\(l("昨天", "Yesterday")) \(timeString(date))"
        }
        if let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day, days < 7 {
            return "\(weekdayString(date)) \(timeString(date))"
        }
        return dateString(date)
    }

    // MARK: - Private

    private func l(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    private func timeString(_ date: Date) -> String {
        if language == .zh {
            return date.formatted(
                .dateTime
                    .locale(locale)
                    .hour(.twoDigits(amPM: .omitted))
                    .minute(.twoDigits)
            )
        }
        return date.formatted(
            .dateTime
                .locale(locale)
                .hour(.defaultDigits(amPM: .abbreviated))
                .minute(.twoDigits)
        )
    }

    private func weekdayString(_ date: Date) -> String {
        if language == .zh {
            return date.formatted(.dateTime.locale(locale).weekday(.wide))
        }
        return date.formatted(.dateTime.locale(locale).weekday(.abbreviated))
    }

    private func dateString(_ date: Date) -> String {
        let year = Calendar.current.component(.year, from: date)
        let currentYear = Calendar.current.component(.year, from: Date())
        if language == .zh {
            if year == currentYear {
                return date.formatted(.dateTime.locale(locale).month().day())
            }
            return date.formatted(.dateTime.locale(locale).year().month().day())
        }
        if year == currentYear {
            return date.formatted(.dateTime.locale(locale).month(.abbreviated).day())
        }
        return date.formatted(.dateTime.locale(locale).month(.abbreviated).day().year())
    }
}
