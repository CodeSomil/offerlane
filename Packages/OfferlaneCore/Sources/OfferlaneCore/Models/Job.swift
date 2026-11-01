import Foundation
import GRDB

/// One posting and its whole lifecycle. Declined/rejected rows keep only their fingerprint fields.
public struct Job: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "job"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: String
    public var company: String
    public var title: String
    public var location: String = ""
    public var url: String = ""
    public var applyUrl: String = ""
    public var ats: String = ""
    public var atsSlug: String = ""
    public var source: String = ""
    public var posted: String?
    public var description: String = ""
    public var status: JobStatus = .found
    public var firstSeen: String = Dates.now()
    public var updated: String = Dates.now()
    public var lastSeen: String = Dates.now()
    public var localScore: Double?
    public var llmScore: Int?
    public var llmReason: String = ""
    public var variant: String = ""
    public var visa: String = ""
    public var minYears: Int?
    /// Folder under Applications/ with the tailored PDF, plan.json, answers.md.
    public var folder: String = ""
    public var keywords: [String] = []
    public var changesSummary: String = ""
    public var tailorNote: String = ""
    public var error: String = ""
    /// The apply agent's latest message ("Filled 14 fields. Please complete: …").
    public var autofill: String = ""
    public var site: String = ""
    public var notes: String = ""
    /// "Use my resume as-is": skip the tailoring call.
    public var quick = false

    public init(company: String, title: String, location: String = "", url: String = "", id: String? = nil) {
        self.company = company; self.title = title; self.location = location; self.url = url
        self.id = id ?? Text.jobID(company: company, title: title, location: location)
    }

    public var score: Double { llmScore.map(Double.init) ?? localScore ?? 0 }

    /// Hide but remember: drop everything except what de-duplication and stats need.
    public mutating func stripForHiding() {
        description = ""; keywords = []; llmReason = ""; autofill = ""
    }
}

public struct JobEvent: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "event"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: Int64?
    public var jobId: String
    public var ts: String
    public var status: String
    public var source: String
    public var detail: String
    public init(jobId: String, status: String, source: String, detail: String, ts: String = Dates.now()) {
        self.jobId = jobId; self.status = status; self.source = source; self.detail = detail; self.ts = ts
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A career-site account. The password is only in Keychain.
public struct SiteAccount: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "account"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: String { host }
    public var host: String
    public var company: String
    public var email: String
    public var approved: Bool
    public var approvedAt: String?
    public var created: String?
    public init(host: String, company: String, email: String, approved: Bool = false, approvedAt: String? = nil, created: String? = nil) {
        self.host = host; self.company = company; self.email = email; self.approved = approved; self.approvedAt = approvedAt; self.created = created
    }
}

public struct UsageDay: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "usage"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var day: String
    public var calls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cachedTokens = 0
    public var usd = 0.0
    public init(day: String) { self.day = day }
}
