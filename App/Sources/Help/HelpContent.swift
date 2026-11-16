import Foundation
import OfferlaneCore

/// In-app help: short answers to the questions people actually ask. Replaces docs/USER_GUIDE.md.
struct HelpTopic: Identifiable, Hashable {
    enum Action: Hashable { case setupCenter, tour, diagnostics, settings }
    let id: String
    let section: String
    let question: String
    /// Markdown (bold, links) is allowed.
    let answer: String
    var action: Action? = nil

    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let text = (section + " " + question + " " + answer).lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}

enum HelpContent {
    static let sections = ["Getting started", "Finding jobs", "Applying", "Tracking", "AI", "Privacy and data", "Troubleshooting"]

    static let topics: [HelpTopic] = [
        // Getting started
        .init(id: "what", section: "Getting started", question: "What does Offerlane do?",
              answer: Brand.shortDescription + "\n\nOfferlane searches free job sites and company career sites, scores each role against your resume, tailors your resume for the roles you approve, and fills in the application at a human pace. It always stops before **Submit**, so you submit every application yourself.\n\nNothing is tailored, applied for or created without your say-so. Offerlane never solves CAPTCHAs and never logs in to LinkedIn."),
        .init(id: "first", section: "Getting started", question: "How do I get started?",
              answer: "There are four steps: **sign in**, **connect an AI**, **add your resume**, then **Find Jobs**. Offerlane picks job titles and companies from your resume. You can change them on the last step, or later in **Settings → Edit Search…**."),
        .init(id: "tour", section: "Getting started", question: "Can I see the tour again?",
              answer: "Yes. Choose **Help → Take the Tour**.", action: .tour),
        .init(id: "multiple", section: "Getting started", question: "Can I use more than one resume?",
              answer: "Yes. Add as many as you like (PDF, Word, text or LaTeX) and name each one, such as \"IC\" or \"Manager\". Offerlane picks the best one for each role. Manage them in **Resumes**."),
        .init(id: "profiles", section: "Getting started", question: "Can two people share this Mac?",
              answer: "Yes. Each person signs in with their own profile. Profiles have separate data, saved passwords and career-site logins. **Sign Out** keeps your data."),

        // Finding
        .init(id: "find", section: "Finding jobs", question: "How do I find jobs?",
              answer: "Click **Find Jobs** (⌘F). Offerlane checks every company on your list and scores new roles out of 100. It takes about a minute. Roles above your score threshold appear in **Find**."),
        .init(id: "approve", section: "Finding jobs", question: "What happens when I approve or decline a role?",
              answer: "**Approve** asks Offerlane to tailor your resume for that role in the background. You're notified when it's ready to review. **Decline** hides the role for good, and you can undo it from the message that appears."),
        .init(id: "companies", section: "Finding jobs", question: "How do I add a company or change job titles?",
              answer: "Go to **Settings → Edit Search…**. Add a company by name, or paste its careers-page link. Offerlane reads Greenhouse, Lever, Ashby, Workable, SmartRecruiters and Workday sites.", action: .settings),
        .init(id: "weak", section: "Finding jobs", question: "Where are the lower-scoring roles?",
              answer: "Under **Show weaker matches** at the bottom of Discover. To see more roles everywhere, lower the score threshold in **Edit Search…**."),

        // Applying
        .init(id: "review", section: "Applying", question: "How do I check a tailored resume?",
              answer: "Open it from **Review**. Every change is shown with your original in red and the new text in green. If the AI tried to add a number that isn't in your resume, that change was blocked and your original kept. **Edit** lets you change the wording; then **Rebuild PDF**. When it's right, click **Approve & Apply**."),
        .init(id: "apply", section: "Applying", question: "What happens when Offerlane applies?",
              answer: "An Apply window opens the job and fills in every page. If the site needs an account, Offerlane asks first and saves the new password in your Keychain. It stops on the page with **Submit**: check everything, then click Submit yourself."),
        .init(id: "needsyou", section: "Applying", question: "The apply window says \"Needs you\". What do I do?",
              answer: "Something needs a person: a CAPTCHA, an unusual question, or a failed sign-in. The banner says what. Do it in the window, then press **Continue**."),

        // Tracking
        .init(id: "board", section: "Tracking", question: "How do I track my applications?",
              answer: "**Pipeline** shows a board of everything you've submitted. To change a status, drag a card, or right-click it and choose **Move to**. Rejections are hidden but counted; tick **Show removed** to see them."),
        .init(id: "email", section: "Tracking", question: "How do replies from employers update my applications?",
              answer: "Connect your inbox in **Settings → Email** using an *app password*; the screen links to instructions for your email provider. Offerlane then reads replies from employers and moves cards along (interview, assessment, offer). It only looks at sender and subject first."),

        // AI
        .init(id: "which-ai", section: "AI", question: "Which AI should I choose?",
              answer: "Offerlane suggests three options that suit your Mac; the rest are under **More options**. **Easiest:** sign in with OpenRouter. There's no key to copy, and you can pick a free model, or a paid one from many AI companies once you add OpenRouter credit. **Free:** Ollama runs on this Mac and nothing leaves it, but it's slower and needs a few GB of disk. Google Gemini, Groq and Cloudflare have free API keys with daily limits. **Paid:** a Claude API key charges per use, typically a few cents per Find Jobs run. You can also enter your own endpoint. Each option says what it does with your data before you connect it. Change it any time in the **Setup Center**.", action: .setupCenter),
        .init(id: "install-safe", section: "AI", question: "Is it safe to let Offerlane install Ollama?",
              answer: "Yes. Offerlane downloads it only from the official release server over a secure connection, shows you what it will download and from where first, and checks the file's code signature before anything runs. It deletes the download if any check fails."),
        .init(id: "ollama-space", section: "AI", question: "How do I free up space used by Ollama?",
              answer: "Open the **Setup Center**, choose Ollama, then **Manage Ollama**. You can remove a model or uninstall Ollama; both go to the Trash.", action: .setupCenter),

        // Privacy
        .init(id: "where", section: "Privacy and data", question: "Where is my data kept?",
              answer: "Everything stays on this Mac, in your profile's folder under Application Support. Passwords and keys are kept only in your Mac's Keychain. Only your resume text and job descriptions go to your AI, and only form answers go to the career sites you apply to. There's no tracking or telemetry. Your profile's password and Touch ID stop other people using this Mac account from opening it in Offerlane, but they don't encrypt files: turn on **FileVault** (System Settings → Privacy & Security) to protect everything on the disk."),
        .init(id: "ai-privacy", section: "Privacy and data", question: "What does each AI do with my data?",
              answer: aiPrivacy(), action: .setupCenter),
        .init(id: "export", section: "Privacy and data", question: "How do I export or delete my data?",
              answer: "**Settings → Your data**: **Export Everything…** saves your data and all PDFs (passwords aren't included). **Delete All My Data…** removes everything from this Mac.", action: .settings),
        .init(id: "diagnostics", section: "Privacy and data", question: "What's in \"Send Diagnostics\"?",
              answer: "A short text report: app and macOS version, the kind of Mac, free disk space, which AI you use, counts of roles and applications, the Setup Center checks, and recent log lines. Names, emails, phone numbers, web addresses, passwords and keys are removed. You see the whole report before you save or copy it, and nothing is sent automatically.", action: .diagnostics),

        // Troubleshooting
        .init(id: "health", section: "Troubleshooting", question: "Something isn't working. Where do I start?",
              answer: "Click the status at the bottom of the sidebar to open the **Setup Center**, then **Repair Everything**. It starts what's stopped, finishes interrupted downloads and tells you anything it can't fix by itself.", action: .setupCenter),
        .init(id: "offline", section: "Troubleshooting", question: "It says I'm offline.",
              answer: "Finding jobs, applying and online AIs all need the internet. Connect to Wi-Fi, then click **Try Again** in the Setup Center. Ollama keeps working offline."),
        .init(id: "ai-refused", section: "Troubleshooting", question: "The AI says my key was refused or I hit a limit.",
              answer: "Free keys have daily limits; the message says which. Wait for the limit to reset, or add a second AI in the **Setup Center** so Offerlane can switch. If the key was refused, copy it again from the provider's key page and paste it in.", action: .setupCenter),
        .init(id: "site-fails", section: "Troubleshooting", question: "A career site couldn't be checked.",
              answer: "Sites are sometimes down or change their pages. Offerlane tries again on the next **Find Jobs**. If one keeps failing, remove it in **Edit Search…** and add it again by pasting its careers-page link."),
        .init(id: "forgot", section: "Troubleshooting", question: "I forgot my Offerlane password.",
              answer: "Offerlane has no server, so nobody can reset it. On the sign-in screen, choose **Forgot password?** to erase that profile and start again. If you used **Continue with Google**, just sign in with Google again."),
    ]

    /// Built from providers.json so it changes when the registry does, not hard-coded here.
    static func aiPrivacy(_ specs: [ProviderSpec] = (try? ProviderRegistry.visible()) ?? []) -> String {
        let lines = specs.filter { !$0.privacyNote.isEmpty }.map { "- **\($0.name):** \($0.privacyNote)" }
        return "Your resume text and job posts go only to the AI you connect, and only after you connect it.\n\n" + lines.joined(separator: "\n")
    }
}
