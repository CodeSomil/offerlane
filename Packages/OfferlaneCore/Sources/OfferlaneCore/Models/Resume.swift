import Foundation
import GRDB

/// A structured resume: the bullet bank every tailoring draws from. Bullet text is verbatim from the user's file.
public struct ResumeContent: Codable, Hashable, Sendable {
    public var variant = ""
    public var label = ""
    /// "html" (rendered from our template) or "tex" (the user's own LaTeX with bullets swapped).
    public var format = "html"
    @Lenient public var name: String
    @Lenient public var email: String
    @Lenient public var phone: String
    @Lenient public var location: String
    public var links: [String: String] = [:]
    @Lenient public var headline: String
    @Lenient public var summary: String
    @LenientArray public var experience: [Section]
    @LenientArray public var projects: [Section]
    @LenientArray public var education: [EducationItem]
    @LenientArray public var skills: [Skill]
    @LenientArray public var certifications: [String]
    @LenientArray public var extras: [String]
    @Lenient public var yearsExperience: String
    @Lenient public var seniority: String
    @Lenient public var field: String
    @LenientArray public var suggestedTitles: [String]
    @LenientArray public var topSkills: [String]
    public init() {}

    public struct Bullet: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var text: String
        /// Set on tailored copies: the bank's text before the rewrite.
        public var original: String?
        public init(id: String, text: String, original: String? = nil) { self.id = id; self.text = text; self.original = original }
    }
    public struct Section: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        @Lenient public var title: String
        @Lenient public var company: String
        @Lenient public var name: String
        @Lenient public var location: String
        @Lenient public var dates: String
        @LenientArray public var bullets: [Bullet]
        public init(id: String, title: String = "", company: String = "", name: String = "", location: String = "", dates: String = "", bullets: [Bullet] = []) {
            self.id = id; self.title = title; self.company = company; self.name = name; self.location = location; self.dates = dates; self.bullets = bullets
        }
        enum CodingKeys: String, CodingKey { case id, title, company, name, location, dates, bullets }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? ""
            _title = try c.decode(Lenient.self, forKey: .title); _company = try c.decode(Lenient.self, forKey: .company)
            _name = try c.decode(Lenient.self, forKey: .name); _location = try c.decode(Lenient.self, forKey: .location)
            _dates = try c.decode(Lenient.self, forKey: .dates); _bullets = try c.decode(LenientArray<Bullet>.self, forKey: .bullets)
        }
        /// "Title @ Company" for headings and prompts.
        public var heading: String {
            let t = title.isEmpty ? name : title
            return company.isEmpty ? t : "\(t) @ \(company)"
        }
    }
    public struct EducationItem: Codable, Hashable, Sendable {
        @Lenient public var school: String
        @Lenient public var degree: String
        @Lenient public var dates: String
        @Lenient public var details: String
        public init() {}
    }
    public struct Skill: Codable, Hashable, Sendable {
        public var label: String
        @Lenient public var items: String
        public init(label: String, items: String) { self.label = label; self.items = items }
    }

    public var sections: [Section] { experience + projects }
    public var bulletCount: Int { sections.reduce(0) { $0 + $1.bullets.count } }
    public var yearsValue: Double { Double(Re.first("[\\d.]+", yearsExperience) ?? "") ?? 0 }
}

/// The parsed structure of a LaTeX resume: where each itemize block, its heading and the summary/headline lines are.
public struct TexTemplate: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable { public var id: String; public var raw: String; public var text: String }
    public struct Block: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var header: Int?
        public var begin: Int
        public var end: Int
        public var bullets: [Item]
    }
    public var sections: [Block] = []
    public var headlineLine: Int?
    public var summaryLine: Int?
    public init() {}
}

/// A named resume version ("IC", "Manager"…), stored in the database.
public struct ResumeVersion: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "resume_version"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public var id: String { name }
    /// Short key: lowercase letters, digits, dashes (e.g. "ic", "lead").
    public var name: String
    public var label: String
    public var isDefault: Bool
    public var content: ResumeContent
    public var sourceText: String
    public var sourceFile: String
    public var templateTex: String?
    public var template: TexTemplate?
    public var created: String
    public init(name: String, label: String, isDefault: Bool = false, content: ResumeContent, sourceText: String, sourceFile: String,
                templateTex: String? = nil, template: TexTemplate? = nil, created: String = Dates.now()) {
        self.name = name; self.label = label; self.isDefault = isDefault; self.content = content; self.sourceText = sourceText
        self.sourceFile = sourceFile; self.templateTex = templateTex; self.template = template; self.created = created
    }

    public static func validName(_ s: String) -> Bool { Re.search("^[a-z0-9][a-z0-9_-]{0,29}$", s, []) }
    /// "Manager (Lead)" -> "manager-lead"
    public static func makeName(from label: String) -> String {
        let s = Re.sub("[^a-z0-9]+", "-", label.lowercased()).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((s.isEmpty ? "main" : s).prefix(30))
    }
}
