import Foundation

/// How a `CityDate` is written down.
///
/// Separate from `CityDate` for the reason the project structure rule gives:
/// `Simulation/` may import Foundation only, and what a month is *called* is a
/// statement about presentation. The date carries numbers; this turns them
/// into something a player reads. Same split as
/// `RenderPalette.displayName(for:)` and `InspectorText`.
enum CalendarText {

    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// "14 Mar 1987" — the full date, for the dashboard.
    static func full(_ date: CityDate) -> String {
        "\(date.dayOfMonth) \(months[date.month - 1]) \(date.year)"
    }

    /// "Mar 1987" — month and year, for anywhere the exact day is noise.
    static func monthAndYear(_ date: CityDate) -> String {
        "\(months[date.month - 1]) \(date.year)"
    }

    /// How long the city has been going, in the units a player would use
    /// rather than always in days: "18 days", "7 months", "3 years".
    ///
    /// A number that has to stay readable while it grows by one every second
    /// cannot keep the same unit forever — four figures of days is a number
    /// nobody parses at a glance.
    static func age(_ date: CityDate) -> String {
        if date.day < CityDate.daysPerMonth * 2 {
            return date.day == 1 ? "1 day" : "\(date.day) days"
        }
        if date.day < CityDate.daysPerYear {
            return "\(date.day / CityDate.daysPerMonth) months"
        }
        let years = date.age
        return years == 1 ? "1 year" : "\(years) years"
    }

    /// A count of days as a player would say it — used for anything the
    /// simulation measures in ticks and the player thinks of as a wait.
    static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }
}
