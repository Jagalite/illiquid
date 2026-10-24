import CryptoKit
import CoreFoundation
import Foundation

enum BenchmarkPreferenceError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case reusedSuite
    case invalidSeed

    var description: String {
        switch self {
        case .invalidConfiguration(let field): "Invalid benchmark preference configuration: \(field)"
        case .reusedSuite: "Benchmark preference suite already exists; choose a fresh session"
        case .invalidSeed: "Preference seed must be a JSON object of app-owned property-list values, at most 1 MiB"
        }
    }
}

/// A benchmark session must opt in to a fresh domain. Invalid/missing isolation
/// fails closed before any application preference store is constructed.
struct BenchmarkPreferenceConfiguration: Equatable {
    static let bundleIdentifier = "com.example.IlliquidBenchmark"
    static let suiteKey = "ILLIQUID_BENCHMARK_PREFERENCES_SUITE"
    static let seedKey = "ILLIQUID_BENCHMARK_PREFERENCES_SEED_FILE"
    static let receiptKey = "ILLIQUID_BENCHMARK_PREFERENCES_RECEIPT"

    let session: String
    let suite: String
    let seedURL: URL?
    let receiptURL: URL
    let sessionFileURL: URL

    static func resolve(environment: [String: String], bundleIdentifier: String?) throws -> Self? {
        let hasPreferenceOverride = [suiteKey, seedKey, receiptKey].contains { environment[$0] != nil }
        let hasSession = environment["ILLIQUID_BENCHMARK_CONTROL_SESSION"] != nil
        guard bundleIdentifier == self.bundleIdentifier,
              environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1"
        else {
            // Production launches ignore benchmark-only variables entirely.
            return nil
        }
        guard hasSession || hasPreferenceOverride else { return nil }
        guard let session = environment["ILLIQUID_BENCHMARK_CONTROL_SESSION"],
              isValidToken(session)
        else { throw BenchmarkPreferenceError.invalidConfiguration("control session") }
        let suite = self.bundleIdentifier + ".AgentUI." + session
        guard environment[suiteKey] == suite else {
            throw BenchmarkPreferenceError.invalidConfiguration(suiteKey)
        }
        func absoluteURL(_ key: String) throws -> URL {
            guard let path = environment[key], path.hasPrefix("/"), !path.contains("\0") else {
                throw BenchmarkPreferenceError.invalidConfiguration(key)
            }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        let control = try absoluteURL("ILLIQUID_BENCHMARK_CONTROL_FILE")
        let receipt = try absoluteURL(receiptKey)
        let sessionFile = try absoluteURL("ILLIQUID_BENCHMARK_SESSION_FILE")
        let seed = try environment[seedKey].map { _ in try absoluteURL(seedKey) }
        let paths = [control, receipt, sessionFile] + (seed.map { [$0] } ?? [])
        guard Set(paths).count == paths.count else {
            throw BenchmarkPreferenceError.invalidConfiguration("overlapping state files")
        }
        return Self(session: session, suite: suite, seedURL: seed,
                    receiptURL: receipt, sessionFileURL: sessionFile)
    }

    private static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 96 && token.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

/// Injected by portable tests, which never create, clear, or seed a user domain.
protocol PreferenceDomainAccess: AnyObject {
    func read(_ name: String) -> [String: Any]?
    func write(_ values: [String: Any], to name: String)
}

private final class PersistentPreferenceDomains: PreferenceDomainAccess {
    private let defaults: UserDefaults
    init(suite: String) throws {
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw BenchmarkPreferenceError.invalidConfiguration("suite unavailable")
        }
        self.defaults = defaults
    }
    func read(_ name: String) -> [String: Any]? { defaults.persistentDomain(forName: name) }
    func write(_ values: [String: Any], to name: String) {
        defaults.setPersistentDomain(values, forName: name)
    }
}

/// All read paths deliberately use this domain's snapshot, including typed
/// getters used by AppStorage. A plain named UserDefaults also searches the
/// application/global domains and therefore cannot provide this guarantee.
final class BenchmarkSuiteDefaults: UserDefaults, @unchecked Sendable {
    static let reservationKey = "Illiquid.agent-ui-preference-suite.v1"
    private let domain: PreferenceDomainAccess
    private let suite: String
    private let stateLock = NSRecursiveLock()
    private var values: [String: Any]
    private var registered: [String: Any] = [:]

    init(suite: String, seed: [String: Any], domain: PreferenceDomainAccess) throws {
        guard domain.read(suite) == nil else { throw BenchmarkPreferenceError.reusedSuite }
        self.suite = suite
        self.domain = domain
        values = seed.merging([Self.reservationKey: suite]) { _, reserved in reserved }
        super.init(suiteName: suite)!
        // Creating even an empty suite reserves it. Never remove/reset a domain.
        domain.write(values, to: suite)
    }

    override func object(forKey key: String) -> Any? {
        stateLock.lock(); defer { stateLock.unlock() }
        return values[key] ?? registered[key]
    }
    override func string(forKey key: String) -> String? {
        if let value = object(forKey: key) as? String { return value }
        return (object(forKey: key) as? NSNumber)?.stringValue
    }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func bool(forKey key: String) -> Bool {
        if let value = object(forKey: key) as? NSNumber { return value.boolValue }
        return (object(forKey: key) as? NSString)?.boolValue ?? false
    }
    override func integer(forKey key: String) -> Int {
        if let value = object(forKey: key) as? NSNumber { return value.intValue }
        return (object(forKey: key) as? NSString)?.integerValue ?? 0
    }
    override func double(forKey key: String) -> Double {
        if let value = object(forKey: key) as? NSNumber {
            return CFGetTypeID(value) == CFBooleanGetTypeID() ? 0 : value.doubleValue
        }
        return (object(forKey: key) as? NSString)?.doubleValue ?? 0
    }
    override func float(forKey key: String) -> Float { Float(double(forKey: key)) }
    override func url(forKey key: String) -> URL? {
        if let value = string(forKey: key) { return URL(fileURLWithPath: value) }
        if let data = data(forKey: key) {
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL?
        }
        return nil
    }
    override func dictionaryRepresentation() -> [String: Any] {
        stateLock.lock(); defer { stateLock.unlock() }
        return registered.merging(values) { _, value in value }
    }
    override func register(defaults registrationDictionary: [String: Any]) {
        stateLock.lock(); defer { stateLock.unlock() }
        registered.merge(registrationDictionary) { _, value in value }
    }
    override func set(_ value: Any?, forKey key: String) {
        // AppStorage observes changes on this object, rather than the private
        // UserDefaults object used solely to write the named persistent domain.
        willChangeValue(forKey: key)
        stateLock.lock()
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
        domain.write(values, to: suite)
        stateLock.unlock()
        didChangeValue(forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: URL?, forKey key: String) {
        guard let value else { removeObject(forKey: key); return }
        if value.isFileURL { set(value.path as Any, forKey: key) }
        else { set(try? NSKeyedArchiver.archivedData(withRootObject: value as NSURL,
            requiringSecureCoding: true), forKey: key) }
    }
    override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }
}

struct BenchmarkPreferenceSeed {
    let values: [String: Any]
    let sha256: String?

    static func decode(_ data: Data?) throws -> Self {
        guard let data else { return Self(values: [:], sha256: nil) }
        guard data.count <= 1_048_576,
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              values.keys.allSatisfy({
                  ($0.hasPrefix("Illiquid.") || $0 == "player.shortcut-overrides.v1")
                      && $0 != BenchmarkSuiteDefaults.reservationKey
              }),
              PropertyListSerialization.propertyList(values, isValidFor: .binary)
        else { throw BenchmarkPreferenceError.invalidSeed }
        return Self(values: values, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

enum BenchmarkPreferenceReceipt {
    static func data(configuration: BenchmarkPreferenceConfiguration,
                     seed: BenchmarkPreferenceSeed, defaults: UserDefaults) throws -> Data {
        let effective = defaults.dictionaryRepresentation()
        let effectiveData = try JSONSerialization.data(withJSONObject: effective, options: [.sortedKeys])
        let receipt: [String: Any] = [
            "schema_version": 1, "session": configuration.session,
            "suite": configuration.suite, "fallback_domains": [],
            "isolation_mode": "session-suite-only",
            "seed_path": configuration.seedURL?.path as Any? ?? NSNull(),
            "seed_sha256": seed.sha256 as Any? ?? NSNull(),
            "seed_values": seed.values,
            "effective_initial_values": effective,
            "effective_initial_canonical_json": String(decoding: effectiveData, as: UTF8.self),
            "effective_initial_sha256": SHA256.hash(data: effectiveData).map { String(format: "%02x", $0) }.joined(),
            "session_file": configuration.sessionFileURL.path,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "scope": "preference initialization; no live UI qualification",
        ]
        return try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
    }

    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".preferences-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        // Publishing a same-directory hard link is atomic and fails if the
        // destination exists. No check-then-overwrite window, even on a race.
        try FileManager.default.linkItem(at: temporary, to: destination)
    }
}

/// Shared by app stores, the startup loader, delegate, and both SwiftUI scenes.
/// Immutable lazy initialization also covers entry points before App.init.
enum AppPreferences {
    private final class Context: @unchecked Sendable {
        let defaults: UserDefaults
        let configuration: BenchmarkPreferenceConfiguration?
        let seed: BenchmarkPreferenceSeed

        init() throws {
            configuration = try BenchmarkPreferenceConfiguration.resolve(
                environment: ProcessInfo.processInfo.environment,
                bundleIdentifier: Bundle.main.bundleIdentifier)
            if let configuration {
                guard !FileManager.default.fileExists(atPath: configuration.receiptURL.path) else {
                    throw BenchmarkPreferenceError.invalidConfiguration("receipt already exists")
                }
                seed = try BenchmarkPreferenceSeed.decode(try configuration.seedURL.map { try Data(contentsOf: $0) })
                defaults = try BenchmarkSuiteDefaults(suite: configuration.suite, seed: seed.values,
                    domain: PersistentPreferenceDomains(suite: configuration.suite))
            } else {
                seed = try BenchmarkPreferenceSeed.decode(nil)
                defaults = .standard
            }
        }
    }

    private static let context: Context = {
        do { return try Context() }
        catch {
            FileHandle.standardError.write(Data("[agent-ui-preferences] refused: \(error)\n".utf8))
            exit(78)
        }
    }()

    static var defaults: UserDefaults { context.defaults }
    static var sessionFileURL: URL? { context.configuration?.sessionFileURL }

    static func recordDiagnostics() throws {
        guard let configuration = context.configuration else { return }
        let data = try BenchmarkPreferenceReceipt.data(configuration: configuration,
            seed: context.seed, defaults: defaults)
        try BenchmarkPreferenceReceipt.write(data, to: configuration.receiptURL)
    }
}
