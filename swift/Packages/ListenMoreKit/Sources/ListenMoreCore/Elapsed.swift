/// Frame times are multiples of the frame length, and their differences round (3.56 - 3.50 is a hair
/// over 0.06, 4.40 - 3.20 a hair under 1.2). Window and cooldown checks read their elapsed time through
/// `span`, which rounds it to the microsecond, so a window holds the same number of frames anywhere on
/// the clock.
enum Elapsed {
    static let stepsPerS = 1e6

    /// An elapsed time (a difference of event times or a sum of frame lengths), rounded to the
    /// microsecond. Dividing the whole step count lands on the same double as a window parsed from
    /// milliseconds or seconds.
    static func span(_ d: Double) -> Double {
        (d * stepsPerS).rounded() / stepsPerS
    }
}
