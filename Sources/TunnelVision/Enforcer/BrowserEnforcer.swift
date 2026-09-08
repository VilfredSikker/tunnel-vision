import AppKit
import Foundation
import os

// MARK: - Model

struct BrowserTab: Equatable, Sendable {
    /// 1-based, as the browser numbers it.
    let index: Int
    let url: String
}

/// One browser window as its scripting dictionary reports it.
struct BrowserWindowState: Equatable, Sendable {
    /// The browser's own window id, stable for the window's life.
    let id: Int
    let name: String
    let isMinimized: Bool
    let activeTabIndex: Int
    let tabs: [BrowserTab]

    var activeTab: BrowserTab? {
        tabs.first { $0.index == activeTabIndex }
    }
}

/// What to do about a window whose active tab left the allowlist.
enum BrowserAction: Equatable, Sendable {
    /// Another tab of the window is allowed: show that one.
    case activateTab(index: Int)
    /// No allowed tab: send the active tab back to an allowed page.
    case navigate(tabIndex: Int, url: String)
}

/// The rules a managed browser runs under.
struct BrowserRuleSet: Equatable, Sendable {
    /// Site patterns (`host[/path]`).
    var urlPatterns: [String] = []
    /// Window-title patterns, lowercased; a matching window is compliant
    /// whatever its tab shows.
    var titlePatterns: [String] = []
}

// MARK: - Policy

/// Layer 3b (FEASIBILITY.md): inside a browser allowed through site rules,
/// a window showing a page off the allowlist is steered back. Pure so the
/// decisions are testable without a browser.
enum BrowserLockPolicy {
    /// Rule sets per browser: only browsers Tunnel Vision manages, with URL rules
    /// and without an app rule (an app rule allows the browser whole).
    static func ruleSets(rules: [Rule], managed: Set<String>) -> [String: BrowserRuleSet] {
        var wholeApp = Set<String>()
        for rule in rules where rule.effect == .allow && rule.scope == .app {
            wholeApp.insert(rule.bundleID.trimmingCharacters(in: .whitespaces))
        }
        var sets: [String: BrowserRuleSet] = [:]
        for rule in rules where rule.effect == .allow {
            let bundle = rule.bundleID.trimmingCharacters(in: .whitespaces)
            guard !bundle.isEmpty, managed.contains(bundle), !wholeApp.contains(bundle) else { continue }
            let pattern = rule.pattern.trimmingCharacters(in: .whitespaces).lowercased()
            guard !pattern.isEmpty else { continue }
            switch rule.scope {
            case .url:
                guard URLPattern.parse(pattern) != nil else { continue }
                sets[bundle, default: BrowserRuleSet()].urlPatterns.append(pattern)
            case .window:
                sets[bundle, default: BrowserRuleSet()].titlePatterns.append(pattern)
            case .app, .herdr:
                break
            }
        }
        return sets.filter { !$0.value.urlPatterns.isEmpty }
    }

    /// The window's active page is allowed, or is no web page at all (new
    /// tab page, settings, blank), or the window's title matches a rule.
    static func isCompliant(_ window: BrowserWindowState, ruleSet: BrowserRuleSet) -> Bool {
        guard let active = window.activeTab, URLPattern.isWeb(active.url) else { return true }
        if WindowLockPolicy.matches(title: window.name, patterns: ruleSet.titlePatterns) { return true }
        return URLPattern.matchesAny(ruleSet.urlPatterns, url: active.url)
    }

    /// Nil for a compliant or minimised window. Otherwise the least
    /// destructive way back: another allowed tab, else the page the window
    /// last showed while allowed, else the first site rule as a URL.
    static func plan(window: BrowserWindowState, ruleSet: BrowserRuleSet, lastAllowedURL: String?) -> BrowserAction? {
        guard !window.isMinimized, !isCompliant(window, ruleSet: ruleSet), let active = window.activeTab else { return nil }
        if let other = window.tabs.first(where: { $0.index != active.index && URLPattern.matchesAny(ruleSet.urlPatterns, url: $0.url) }) {
            return .activateTab(index: other.index)
        }
        let target = lastAllowedURL ?? ruleSet.urlPatterns.lazy.compactMap(URLPattern.url(forPattern:)).first
        guard let target else { return nil }
        return .navigate(tabIndex: active.index, url: target)
    }
}

// MARK: - Scripting facade

/// The browser calls the enforcer needs, so the loop is testable.
@MainActor
protocol BrowserScripting: AnyObject {
    func isRunning(_ bundleID: String) -> Bool
    func displayName(of bundleID: String) -> String
    /// Every window with its tabs; nil when the browser did not answer
    /// (Automation declined, or busy).
    func windows(of bundleID: String) async -> [BrowserWindowState]?
    func activateTab(bundleID: String, windowID: Int, index: Int) async -> Bool
    func navigate(bundleID: String, windowID: Int, tabIndex: Int, url: String) async -> Bool
}

/// AppleScript sources, pure for tests.
enum BrowserScripts {
    /// One line per tab: `windowID TAB tabIndex TAB activeIndex TAB minimized TAB windowName TAB url`.
    static func state(forBundle bundleID: String) -> String {
        let safari = Browsers.isSafari(bundleID)
        let activeIndex = safari ? "index of current tab of w" : "active tab index of w"
        let minimized = safari ? "miniaturized of w" : "minimized of w"
        return """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                set out to ""
                repeat with w in windows
                    set wid to id of w
                    set ai to 0
                    try
                        set ai to \(activeIndex)
                    end try
                    set mini to false
                    try
                        set mini to \(minimized)
                    end try
                    set wname to ""
                    try
                        set wname to name of w
                    end try
                    set i to 1
                    repeat with t in tabs of w
                        set u to ""
                        try
                            set u to URL of t
                        end try
                        set out to out & wid & tab & i & tab & ai & tab & mini & tab & wname & tab & u & linefeed
                        set i to i + 1
                    end repeat
                end repeat
                return out
            end tell
        end timeout
        """
    }

    static func activateTab(bundleID: String, windowID: Int, index: Int) -> String {
        let body = Browsers.isSafari(bundleID)
            ? "tell window id \(windowID) to set current tab to tab \(index)"
            : "set active tab index of window id \(windowID) to \(index)"
        return """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                \(body)
            end tell
        end timeout
        """
    }

    static func navigate(bundleID: String, windowID: Int, tabIndex: Int, url: String) -> String {
        """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                set URL of tab \(tabIndex) of window id \(windowID) to \(OSAScript.quoted(url))
            end tell
        end timeout
        """
    }

    static func parseState(_ output: String) -> [BrowserWindowState] {
        struct Partial {
            var name = ""
            var minimized = false
            var active = 0
            var tabs: [BrowserTab] = []
        }
        var order: [Int] = []
        var partials: [Int: Partial] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6,
                  let windowID = Int(parts[0]), let index = Int(parts[1]), let active = Int(parts[2]) else { continue }
            let url = parts[parts.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = parts[4..<(parts.count - 1)].joined(separator: "\t")
            var partial = partials[windowID] ?? Partial()
            if partials[windowID] == nil {
                order.append(windowID)
            }
            partial.name = name
            partial.minimized = parts[3] == "true"
            partial.active = active
            partial.tabs.append(BrowserTab(index: index, url: url))
            partials[windowID] = partial
        }
        return order.compactMap { id in
            guard let partial = partials[id] else { return nil }
            return BrowserWindowState(
                id: id,
                name: partial.name,
                isMinimized: partial.minimized,
                activeTabIndex: partial.active,
                tabs: partial.tabs
            )
        }
    }
}

@MainActor
final class AppleScriptBrowserScripting: BrowserScripting {
    func isRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    func displayName(of bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? AppCatalog.displayName(forBundleID: bundleID)
            ?? bundleID
    }

    func windows(of bundleID: String) async -> [BrowserWindowState]? {
        guard let output = await OSAScript.run(BrowserScripts.state(forBundle: bundleID)) else { return nil }
        return BrowserScripts.parseState(output)
    }

    func activateTab(bundleID: String, windowID: Int, index: Int) async -> Bool {
        await OSAScript.run(BrowserScripts.activateTab(bundleID: bundleID, windowID: windowID, index: index)) != nil
    }

    func navigate(bundleID: String, windowID: Int, tabIndex: Int, url: String) async -> Bool {
        await OSAScript.run(BrowserScripts.navigate(bundleID: bundleID, windowID: windowID, tabIndex: tabIndex, url: url)) != nil
    }
}

// MARK: - Enforcer

/// Polls each managed browser that has site rules while a session runs and
/// steers windows that drift off the allowlist. Nothing is persisted: if
/// Tunnel Vision dies, the browser is simply left alone.
@MainActor
final class BrowserEnforcer: LockListener {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "browser-enforcer")
    static let pollInterval: Duration = .seconds(1)

    private let scripting: BrowserScripting
    private let unmanagedBrowsers: () -> Set<String>
    private let autoPoll: Bool

    private(set) var ruleSets: [String: BrowserRuleSet] = [:]
    /// Sites allowed for the rest of the session, per browser.
    private var sessionSites: [String: [String]] = [:]
    /// The last allowed page each window showed, per browser and window id.
    private var lastAllowedURL: [String: [Int: String]] = [:]
    private var pollTask: Task<Void, Never>?
    private var generation = 0
    private var lastNoticeAt: [String: Date] = [:]
    private var unansweredBundles: Set<String> = []

    private(set) var isActive = false

    /// A page was steered away: (browser name, bundle id, site host).
    var onBlockedSite: ((_ appName: String, _ bundleID: String, _ host: String) -> Void)?

    init(
        scripting: BrowserScripting = AppleScriptBrowserScripting(),
        unmanagedBrowsers: @escaping () -> Set<String> = { [] },
        autoPoll: Bool = true
    ) {
        self.scripting = scripting
        self.unmanagedBrowsers = unmanagedBrowsers
        self.autoPoll = autoPoll
    }

    // MARK: LockListener

    func lockStateChanged(active: Bool, rules: [Rule], mode: Mode) {
        if active {
            lock(rules: rules)
        } else {
            unlock()
        }
    }

    // MARK: Session lock

    func lock(rules: [Rule]) {
        let next = BrowserLockPolicy.ruleSets(rules: rules, managed: Browsers.managed(unmanaged: unmanagedBrowsers()))
        guard !next.isEmpty else {
            unlock()
            return
        }
        for bundle in ruleSets.keys where next[bundle] == nil {
            sessionSites[bundle] = nil
            lastAllowedURL[bundle] = nil
        }
        ruleSets = next
        isActive = true
        generation += 1
        Self.log.info("browser lock: \(next.keys.sorted().joined(separator: ", "), privacy: .public)")
        if autoPoll {
            startPolling()
        }
    }

    func unlock() {
        guard isActive else { return }
        Self.log.info("browser unlock")
        isActive = false
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        ruleSets = [:]
        sessionSites = [:]
        lastAllowedURL = [:]
        lastNoticeAt = [:]
        unansweredBundles = []
    }

    /// "Allow for this session" from the notice: the site joins the
    /// browser's patterns until the session ends.
    func allowForSession(bundleID: String, site: String) {
        let pattern = site.trimmingCharacters(in: .whitespaces).lowercased()
        guard isActive, URLPattern.parse(pattern) != nil else { return }
        sessionSites[bundleID, default: []].append(pattern)
        Self.log.info("allow-for-session: \(bundleID, privacy: .public) site \(pattern, privacy: .public)")
    }

    /// The patterns a browser runs under right now, session additions included.
    func effectiveRuleSet(for bundleID: String) -> BrowserRuleSet? {
        guard var set = ruleSets[bundleID] else { return nil }
        set.urlPatterns += sessionSites[bundleID] ?? []
        return set
    }

    // MARK: Sweeps

    /// One pass over every managed browser that is running.
    func sweep() async {
        guard isActive else { return }
        let current = generation
        for bundle in ruleSets.keys.sorted() where scripting.isRunning(bundle) {
            guard let ruleSet = effectiveRuleSet(for: bundle) else { continue }
            guard let windows = await scripting.windows(of: bundle) else {
                if unansweredBundles.insert(bundle).inserted {
                    Self.log.info("\(bundle, privacy: .public) did not answer — Automation declined, or the browser is busy")
                }
                continue
            }
            guard isActive, generation == current else { return }
            unansweredBundles.remove(bundle)
            for window in windows {
                await judge(window, bundle: bundle, ruleSet: ruleSet)
                guard isActive, generation == current else { return }
            }
        }
    }

    private func judge(_ window: BrowserWindowState, bundle: String, ruleSet: BrowserRuleSet) async {
        if BrowserLockPolicy.isCompliant(window, ruleSet: ruleSet) {
            if let active = window.activeTab, URLPattern.matchesAny(ruleSet.urlPatterns, url: active.url) {
                lastAllowedURL[bundle, default: [:]][window.id] = active.url
            }
            return
        }
        guard let action = BrowserLockPolicy.plan(
            window: window, ruleSet: ruleSet, lastAllowedURL: lastAllowedURL[bundle]?[window.id]
        ) else { return }
        let host = window.activeTab.flatMap { URLPattern.site(fromURL: $0.url) } ?? "that page"
        let done: Bool
        switch action {
        case .activateTab(let index):
            done = await scripting.activateTab(bundleID: bundle, windowID: window.id, index: index)
            Self.log.info("\(bundle, privacy: .public): \(host, privacy: .public) off the allowlist — switched to tab \(index)")
        case .navigate(let tabIndex, let url):
            done = await scripting.navigate(bundleID: bundle, windowID: window.id, tabIndex: tabIndex, url: url)
            Self.log.info("\(bundle, privacy: .public): \(host, privacy: .public) off the allowlist — sent back to \(url, privacy: .public)")
        }
        if done {
            notifyBlocked(bundle: bundle, host: host)
        }
    }

    private func notifyBlocked(bundle: String, host: String) {
        let key = bundle + "|" + host
        let now = Date()
        if let last = lastNoticeAt[key], now.timeIntervalSince(last) < 4 { return }
        lastNoticeAt[key] = now
        onBlockedSite?(scripting.displayName(of: bundle), bundle, host)
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                await self.sweep()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }
}
