import Foundation

/// A Google Calendar event, the subset meeting-card reads. Unknown keys are ignored.
/// Port of the Python dict access in events.py (all fields optional, like `ev.get`).
public struct EventTime: Codable, Equatable, Sendable {
    public var date: String?
    public var dateTime: String?
    public var timeZone: String?
    public init(date: String? = nil, dateTime: String? = nil, timeZone: String? = nil) {
        self.date = date; self.dateTime = dateTime; self.timeZone = timeZone
    }
}

public struct Attendee: Codable, Equatable, Sendable {
    public var isSelf: Bool?
    public var responseStatus: String?
    enum CodingKeys: String, CodingKey { case isSelf = "self", responseStatus }
    public init(isSelf: Bool? = nil, responseStatus: String? = nil) {
        self.isSelf = isSelf; self.responseStatus = responseStatus
    }
}

/// The event organizer. `self` is true only when Scott organized it.
public struct Organizer: Codable, Equatable, Sendable {
    public var isSelf: Bool?
    public var email: String?
    enum CodingKeys: String, CodingKey { case isSelf = "self", email }
    public init(isSelf: Bool? = nil, email: String? = nil) { self.isSelf = isSelf; self.email = email }
}

public struct EntryPoint: Codable, Equatable, Sendable {
    public var entryPointType: String?
    public var uri: String?
    public init(entryPointType: String? = nil, uri: String? = nil) {
        self.entryPointType = entryPointType; self.uri = uri
    }
}

public struct ConferenceData: Codable, Equatable, Sendable {
    public var entryPoints: [EntryPoint]?
    public init(entryPoints: [EntryPoint]? = nil) { self.entryPoints = entryPoints }
}

public struct Event: Codable, Equatable, Sendable {
    public var kind: String?
    public var id: String?
    public var status: String?
    public var summary: String?
    public var eventType: String?
    public var start: EventTime?
    public var end: EventTime?
    public var attendees: [Attendee]?
    public var location: String?
    public var hangoutLink: String?
    public var conferenceData: ConferenceData?
    public var description: String?
    public var htmlLink: String?
    public var organizer: Organizer?

    public init(kind: String? = nil, id: String? = nil, status: String? = nil, summary: String? = nil,
                eventType: String? = nil, start: EventTime? = nil, end: EventTime? = nil,
                attendees: [Attendee]? = nil, location: String? = nil, hangoutLink: String? = nil,
                conferenceData: ConferenceData? = nil, description: String? = nil, htmlLink: String? = nil,
                organizer: Organizer? = nil) {
        self.kind = kind; self.id = id; self.status = status; self.summary = summary
        self.eventType = eventType; self.start = start; self.end = end; self.attendees = attendees
        self.location = location; self.hangoutLink = hangoutLink; self.conferenceData = conferenceData
        self.description = description; self.htmlLink = htmlLink
        self.organizer = organizer
    }

    public static func decode(_ data: Data) throws -> Event {
        try JSONDecoder().decode(Event.self, from: data)
    }
}
