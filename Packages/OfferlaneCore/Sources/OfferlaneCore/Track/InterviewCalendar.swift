import Foundation

/// Interview calendar export: an RFC 5545 .ics file the user saves and opens in their own calendar app. Nothing is sent anywhere.
public enum InterviewCalendar {
    public static let defaultMinutes = 60

    static let utc: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f
    }()

    /// The stored interview time, or nil when it's missing or unreadable.
    public static func date(_ job: Job) -> Date? { job.interviewAt.flatMap { Dates.isoSeconds.date(from: String($0.prefix(19))) } }

    /// One VEVENT per role with a readable interview time; undated roles are left out.
    public static func ics(_ jobs: [Job], now: Date = Date(), minutes: Int = defaultMinutes) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Offerlane//Interviews//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH"]
        for j in jobs {
            guard let start = date(j) else { continue }
            let stage = j.status == .screen ? "Screening call" : "Interview"
            lines += ["BEGIN:VEVENT",
                      "UID:\(j.id)-interview@offerlane.app",   // stable, so re-importing updates rather than duplicates
                      "DTSTAMP:\(utc.string(from: now))",
                      "DTSTART:\(utc.string(from: start))",
                      "DTEND:\(utc.string(from: start.addingTimeInterval(Double(minutes) * 60)))",
                      "SUMMARY:" + escape("\(stage): \(j.title) at \(j.company)"),
                      "DESCRIPTION:" + escape("\(stage) stage in Offerlane." + (j.url.isEmpty ? "" : "\nPosting: \(j.url)")),
                      "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// TEXT escaping (RFC 5545 §3.3.11).
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n")
    }

    /// Lines longer than 75 octets continue on the next line after CRLF + space, never inside a character (§3.1).
    static func fold(_ line: String) -> String {
        var out = "", count = 0
        for ch in line {
            let n = String(ch).utf8.count
            if count + n > 75 { out += "\r\n "; count = 1 }
            out.append(ch); count += n
        }
        return out
    }
}
