import Foundation

/// Everything used to fill application forms (the prototype's profile.json, same keys).
public struct Profile: Codable, Hashable, Sendable {
    public var personal = Personal()
    public var work = Work()
    public var education = Education()
    public var authorization = Authorization()
    public var eeo = EEO()
    public var misc = Misc()
    public var prefs = Prefs()
    public init() {}

    public struct Personal: Codable, Hashable, Sendable {
        @Lenient public var firstName: String
        @Lenient public var lastName: String
        @Lenient public var fullName: String
        @Lenient public var email: String
        @Lenient public var phone: String
        @Lenient public var address: String
        @Lenient public var city: String
        @Lenient public var state: String
        @Lenient public var country: String
        @Lenient public var postalCode: String
        @Lenient public var linkedin: String
        @Lenient public var github: String
        @Lenient public var portfolio: String
        public init() {}
    }
    public struct Work: Codable, Hashable, Sendable {
        @Lenient public var currentCompany: String
        @Lenient public var currentTitle: String
        @Lenient public var yearsExperience: String
        @Lenient public var noticePeriod: String
        @Lenient public var currentSalary: String
        @Lenient public var expectedSalary: String
        @LenientBool<DefaultFalse> public var willingToRelocate: Bool
        @LenientBool<DefaultTrue> public var openToRemote: Bool
        public init() {}
    }
    public struct Education: Codable, Hashable, Sendable {
        @Lenient public var degree: String
        @Lenient public var school: String
        @Lenient public var graduationYear: String
        public init() {}
    }
    public struct Authorization: Codable, Hashable, Sendable {
        @Lenient public var citizenship: String
        @LenientArray public var authorizedCountries: [String]
        @LenientBool<DefaultFalse> public var needsSponsorship: Bool
        public init() {}
    }
    public struct EEO: Codable, Hashable, Sendable {
        public static let decline = "Decline to self-identify"
        @Lenient public var gender: String
        @Lenient public var race: String
        @Lenient public var veteran: String
        @Lenient public var disability: String
        @Lenient public var sexualOrientation: String
        public init() {
            gender = Self.decline; race = Self.decline; veteran = Self.decline; disability = Self.decline; sexualOrientation = Self.decline
        }
    }
    public struct Misc: Codable, Hashable, Sendable {
        @Lenient public var howHeard: String
        @Lenient public var startDate: String
        @Lenient public var pronouns: String
        public init() { howHeard = "Company website" }
    }
    public struct Prefs: Codable, Hashable, Sendable {
        @Lenient public var paper: String
        @Lenient public var dealbreakers: String
        @Lenient public var notes: String
        public init() { paper = "A4" }
    }

    enum CodingKeys: String, CodingKey { case personal, work, education, authorization, eeo, misc, prefs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personal = (try? c.decodeIfPresent(Personal.self, forKey: .personal)) ?? Personal()
        work = (try? c.decodeIfPresent(Work.self, forKey: .work)) ?? Work()
        education = (try? c.decodeIfPresent(Education.self, forKey: .education)) ?? Education()
        authorization = (try? c.decodeIfPresent(Authorization.self, forKey: .authorization)) ?? Authorization()
        eeo = (try? c.decodeIfPresent(EEO.self, forKey: .eeo)) ?? EEO()
        misc = (try? c.decodeIfPresent(Misc.self, forKey: .misc)) ?? Misc()
        prefs = (try? c.decodeIfPresent(Prefs.self, forKey: .prefs)) ?? Prefs()
    }

    public var displayName: String {
        personal.fullName.isEmpty ? "\(personal.firstName) \(personal.lastName)".trimmingCharacters(in: .whitespaces) : personal.fullName
    }
    /// e.g. "Jane_Doe_Resume" — the uploaded PDF's file name.
    public var fileStem: String {
        let n = "\(personal.firstName)_\(personal.lastName)".trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = n.isEmpty ? "Resume" : n.replacingOccurrences(of: " ", with: "_")
        return Re.sub("[^A-Za-z0-9_]+", "", base) + "_Resume"
    }
}

/// The search configuration (the prototype's search.json plus run settings).
public struct SearchConfig: Codable, Hashable, Sendable {
    @LenientArray public var targetTitles: [String]
    @LenientArray public var titleInclude: [String]
    @LenientArray public var titleExclude: [String]
    @LenientArray public var boostKeywords: [String]
    @LenientArray public var penaltyKeywords: [String]
    @LenientArray public var excludeCompanies: [String]
    @LenientArray public var locations: [String]
    @LenientBool<DefaultTrue> public var remoteOk: Bool
    @LenientArray public var companies: [Company]
    @LenientArray public var queries: [String]
    public var minScore: Int = 60
    public var maxAgeDays: Int = 21
    public var poolSize: Int = 25
    public init() {}

    public struct Company: Codable, Hashable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var slug: String?
        /// A verified Workday career-site URL, e.g. https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite
        public var workday: String?
        /// Set when the user pasted a careers URL whose ATS we recognised.
        public var ats: String?
        public init(name: String, slug: String? = nil, workday: String? = nil, ats: String? = nil) {
            self.name = name; self.slug = slug; self.workday = workday; self.ats = ats
        }
    }

    enum CodingKeys: String, CodingKey {
        case targetTitles, titleInclude, titleExclude, boostKeywords, penaltyKeywords, excludeCompanies, locations, remoteOk, companies, queries
        case minScore, maxAgeDays, poolSize
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _targetTitles = try c.decode(LenientArray<String>.self, forKey: .targetTitles)
        _titleInclude = try c.decode(LenientArray<String>.self, forKey: .titleInclude)
        _titleExclude = try c.decode(LenientArray<String>.self, forKey: .titleExclude)
        _boostKeywords = try c.decode(LenientArray<String>.self, forKey: .boostKeywords)
        _penaltyKeywords = try c.decode(LenientArray<String>.self, forKey: .penaltyKeywords)
        _excludeCompanies = try c.decode(LenientArray<String>.self, forKey: .excludeCompanies)
        _locations = try c.decode(LenientArray<String>.self, forKey: .locations)
        _remoteOk = try c.decode(LenientBool<DefaultTrue>.self, forKey: .remoteOk)
        _companies = try c.decode(LenientArray<Company>.self, forKey: .companies)
        _queries = try c.decode(LenientArray<String>.self, forKey: .queries)
        minScore = (try? c.decodeIfPresent(Int.self, forKey: .minScore)) ?? 60
        maxAgeDays = (try? c.decodeIfPresent(Int.self, forKey: .maxAgeDays)) ?? 21
        poolSize = (try? c.decodeIfPresent(Int.self, forKey: .poolSize)) ?? 25
    }
}

/// App settings that are not secrets (secrets live only in Keychain).
public struct AppSettings: Codable, Hashable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable { case claudeCLI = "claude_cli", anthropic, ollama, none }
    public var provider: Provider = .none
    public var claudePath: String = ""
    /// Claude CLI aliases ("haiku"/"sonnet"), Anthropic model IDs, or Ollama model names.
    public var modelFast: String = ""
    public var modelSmart: String = ""
    public var baseUrl: String = ""
    public var onboarded = false
    public var email = Email()
    public var notify = Notify()

    enum CodingKeys: String, CodingKey { case provider, claudePath, modelFast, modelSmart, baseUrl, onboarded, email, notify }
    /// Tolerant: any field missing from an older settings document keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); let d = AppSettings()
        provider = (try? c.decodeIfPresent(Provider.self, forKey: .provider)) ?? d.provider
        claudePath = (try? c.decodeIfPresent(String.self, forKey: .claudePath)) ?? d.claudePath
        modelFast = (try? c.decodeIfPresent(String.self, forKey: .modelFast)) ?? d.modelFast
        modelSmart = (try? c.decodeIfPresent(String.self, forKey: .modelSmart)) ?? d.modelSmart
        baseUrl = (try? c.decodeIfPresent(String.self, forKey: .baseUrl)) ?? d.baseUrl
        onboarded = (try? c.decodeIfPresent(Bool.self, forKey: .onboarded)) ?? d.onboarded
        email = (try? c.decodeIfPresent(Email.self, forKey: .email)) ?? d.email
        notify = (try? c.decodeIfPresent(Notify.self, forKey: .notify)) ?? d.notify
    }

    public struct Email: Codable, Hashable, Sendable {
        public var enabled = false
        public var preset = "gmail"
        public var host = "imap.gmail.com"
        public var port = 993
        public var user = ""
        public init() {}
        enum CodingKeys: String, CodingKey { case enabled, preset, host, port, user }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self); let d = Email()
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
            preset = (try? c.decodeIfPresent(String.self, forKey: .preset)) ?? d.preset
            host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? d.host
            port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? d.port
            user = (try? c.decodeIfPresent(String.self, forKey: .user)) ?? d.user
        }
    }
    public struct Notify: Codable, Hashable, Sendable {
        public var desktop = true
        public var ntfy = false
        public var ntfyTopic = "offerlane-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        public init() {}
        enum CodingKeys: String, CodingKey { case desktop, ntfy, ntfyTopic }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self); let d = Notify()
            desktop = (try? c.decodeIfPresent(Bool.self, forKey: .desktop)) ?? d.desktop
            ntfy = (try? c.decodeIfPresent(Bool.self, forKey: .ntfy)) ?? d.ntfy
            ntfyTopic = (try? c.decodeIfPresent(String.self, forKey: .ntfyTopic)) ?? d.ntfyTopic
        }
    }
    public init() {}
}

extension Profile {
    /// Fill empty fields from a parsed resume (never overwrites what the user typed).
    public mutating func prefill(from r: ResumeContent) {
        func set(_ kp: WritableKeyPath<Profile, String>, _ v: String) { if self[keyPath: kp].isEmpty && !v.isEmpty { self[keyPath: kp] = v } }
        let parts = r.name.split(separator: " ").map(String.init)
        set(\.personal.fullName, r.name)
        set(\.personal.firstName, parts.first ?? "")
        set(\.personal.lastName, parts.count > 1 ? parts.dropFirst().joined(separator: " ") : "")
        set(\.personal.email, r.email); set(\.personal.phone, r.phone)
        let loc = r.location.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        set(\.personal.city, loc.first ?? "")
        if loc.count > 1 { set(\.personal.country, loc.last == "UK" ? "United Kingdom" : loc.last == "US" || loc.last == "USA" ? "United States" : loc.last!) }
        set(\.personal.linkedin, r.links["linkedin"] ?? ""); set(\.personal.github, r.links["github"] ?? ""); set(\.personal.portfolio, r.links["portfolio"] ?? "")
        if let job = r.experience.first(where: { !$0.company.isEmpty }) {
            set(\.work.currentCompany, job.company); set(\.work.currentTitle, job.title)
        }
        set(\.work.yearsExperience, r.yearsExperience)
        if let e = r.education.first { set(\.education.school, e.school); set(\.education.degree, e.degree)
            set(\.education.graduationYear, Re.findAll("(?:19|20)\\d{2}", e.dates).last ?? "") }
        if authorization.authorizedCountries.isEmpty, !personal.country.isEmpty { authorization.authorizedCountries = [personal.country] }
    }

    /// Problems that block the About step, keyed by field.
    public var validationErrors: [String: String] {
        var e: [String: String] = [:]
        if personal.firstName.trimmingCharacters(in: .whitespaces).isEmpty { e["firstName"] = "Enter your first name." }
        if personal.lastName.trimmingCharacters(in: .whitespaces).isEmpty { e["lastName"] = "Enter your last name." }
        if !Re.search("^[\\w.+-]+@[\\w-]+(\\.[\\w-]+)+$", personal.email.trimmingCharacters(in: .whitespaces)) { e["email"] = "Enter a valid email address." }
        if !personal.phone.isEmpty && personal.phone.filter(\.isNumber).count < 7 { e["phone"] = "That phone number looks too short." }
        if !work.yearsExperience.isEmpty && Double(work.yearsExperience) == nil { e["years"] = "Use a number, e.g. 5." }
        if authorization.authorizedCountries.isEmpty { e["countries"] = "Add at least one country where you can work without sponsorship." }
        return e
    }
}
