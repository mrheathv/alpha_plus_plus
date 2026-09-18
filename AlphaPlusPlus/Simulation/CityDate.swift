import Foundation

/// What day it is in the city.
///
/// **One tick is one day**, and that mapping is the whole of this type. It was
/// not chosen to make a nice number; it was chosen because nearly every
/// constant already in the simulation lands on a sensible real duration under
/// it. A storey of construction takes 8 to 40 days
/// (`CitySimulator.constructionTicks`), a lot goes from bare ground to maximum
/// density in about four months, a city settles in five, one hazard strikes a
/// given building every eight or so, and `RegionalEconomy`'s boom-and-bust
/// cycle comes out at ten to fourteen months — a roughly annual economy, which
/// is the reading that settled it.
///
/// **Why the player needed this at all.** The simulation counts ticks, and the
/// cockpit said so: "+$1,798/tick". Nobody lives in ticks. People build things
/// in weeks and watch economies turn over years, and a city builder that
/// cannot tell you how old your city is has made its own bookkeeping the
/// player's problem.
///
/// **No hours**, and for a better reason than resolution. The simulation has
/// no sub-day grain, but more to the point this city is permanently night by
/// design — every building is lit, every street glows. A clock showing the
/// time of day would promise a day/night cycle the art direction deliberately
/// does not have.
struct CityDate: Equatable, Comparable {

    /// Days since the city was founded. The only stored value; everything else
    /// here is arithmetic on it.
    let day: Int

    /// **1985.** The art direction is retrowave, so the city is founded in the
    /// decade it is dressed as. It costs nothing and it means the first thing
    /// a player reads on the dashboard is in on the joke.
    static let foundingYear = 1985

    /// Thirty-day months, twelve of them. A real calendar would need month
    /// lengths and leap years to produce a date nobody checks against an
    /// almanac — this keeps the arithmetic exact and the year a clean 360
    /// days, which also makes "a cycle is about a year" a statement you can
    /// verify rather than approximate.
    static let daysPerMonth = 30
    static let monthsPerYear = 12
    static let daysPerYear = daysPerMonth * monthsPerYear

    var year: Int { Self.foundingYear + day / Self.daysPerYear }

    /// 1 through 12.
    var month: Int { (day % Self.daysPerYear) / Self.daysPerMonth + 1 }

    /// 1 through 30.
    var dayOfMonth: Int { day % Self.daysPerMonth + 1 }

    /// How old the city is, in whole years — what a player means by "how long
    /// have I been at this".
    var age: Int { day / Self.daysPerYear }

    static func < (lhs: CityDate, rhs: CityDate) -> Bool { lhs.day < rhs.day }
}
