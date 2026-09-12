import Combine
import EventKit
import Foundation

/// Reads the next week of calendar events and works out which meal slots are
/// already taken. Rule-based on purpose: it runs on the phone, needs no network,
/// and a judge can read exactly why a slot was skipped.
@MainActor
final class CalendarManager: ObservableObject {
    @Published var authorized = false
    @Published var lastConflicts: [SkipSlot] = []
    private let store = EKEventStore()

    private let dinnerWords = ["dinner", "date night", "restaurant", "reservation", "party", "banquet", "takeout", "take-out", "eat out", "eating out",
                               "bbq", "barbecue", "cookout", "potluck", "happy hour", "drinks", "supper", "gala", "wedding", "birthday dinner"]
    private let lunchWords = ["lunch", "brunch", "luncheon"]
    private let breakfastWords = ["breakfast", "brunch"]
    private let socialWords = ["with ", "meet ", "meetup", "hang", "birthday", "celebration", "catch up", "catch-up", "hangout", "night out", "game night", "movie"]

    func checkAuthorization() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17, *) { authorized = status == .fullAccess } else { authorized = status == .authorized }
    }

    func requestAccess() async -> Bool {
        do {
            if #available(iOS 17, *) { authorized = try await store.requestFullAccessToEvents() }
            else { authorized = try await store.requestAccess(to: .event) }
        } catch { authorized = false }
        return authorized
    }

    /// Slots to leave open over the next `days`, starting today.
    func conflicts(days: Int, mealsPerDay: Int) -> [SkipSlot] {
        guard authorized else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: days, to: start) else { return [] }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        var out: [SkipSlot] = []
        for e in events where !e.isAllDay {
            let title = (e.title ?? "").lowercased()
            let day = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: e.startDate)).day ?? 0
            guard day >= 0, day < days else { continue }
            let hour = Double(cal.component(.hour, from: e.startDate)) + Double(cal.component(.minute, from: e.startDate)) / 60
            let minutes = e.endDate.timeIntervalSince(e.startDate) / 60
            let social = socialWords.contains { title.contains($0) }
            var slot: String?
            if dinnerWords.contains(where: { title.contains($0) }) { slot = "dinner" }
            else if lunchWords.contains(where: { title.contains($0) }) { slot = "lunch" }
            else if breakfastWords.contains(where: { title.contains($0) }) { slot = "breakfast" }
            else if social, hour >= 17.5, hour <= 21, minutes >= 60 { slot = "dinner" }
            else if social, hour >= 11.5, hour <= 14, minutes >= 60 { slot = "lunch" }
            guard let s = slot else { continue }
            let allowed: [String] = mealsPerDay == 1 ? ["dinner"] : (mealsPerDay == 2 ? ["lunch", "dinner"] : ["breakfast", "lunch", "dinner"])
            guard allowed.contains(s) else { continue }
            let skip = SkipSlot(day: day, slot: s, reason: e.title ?? "Calendar event")
            if !out.contains(where: { $0.day == skip.day && $0.slot == skip.slot }) { out.append(skip) }
        }
        lastConflicts = out
        return out
    }
}
