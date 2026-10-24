import CryptoKit
import Foundation
import SwiftUI

// Compiled with the production AppPreferences.swift in an isolated temp folder.
// All persistent domain operations use this fake; no user preferences are read
// or changed. Shared-domain pollution is deliberately present in the fake.
private final class MemoryPreferenceDomains: PreferenceDomainAccess {
    var domains: [String: [String: Any]] = [
        "com.example.IlliquidBenchmark": ["Illiquid.polluted": true, "Illiquid.width": 999.0,
            "Illiquid.interface-scale.v1": 150, "Illiquid.controls-auto-hide-timeout": 59.0],
        "NSGlobalDomain": ["Illiquid.polluted": true],
    ]
    var reads: [String] = []
    var writes: [String] = []
    func read(_ name: String) -> [String: Any]? { reads.append(name); return domains[name] }
    func write(_ values: [String: Any], to name: String) {
        writes.append(name); domains[name] = values
    }
}

private final class PreferenceKVOObserver: NSObject {
    var changes = 0
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        changes += 1
    }
}

@main
private struct PreferenceControls {
    @MainActor
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        func rejects(_ message: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(message) } catch { checks += 1 }
        }
        let bundle = BenchmarkPreferenceConfiguration.bundleIdentifier
        let suite = bundle + ".AgentUI.test-session"
        let environment = [
            "ILLIQUID_ENABLE_BENCHMARK_OVERRIDES": "1",
            "ILLIQUID_BENCHMARK_CONTROL_SESSION": "test-session",
            "ILLIQUID_BENCHMARK_CONTROL_FILE": "/tmp/test-session/control.json",
            "ILLIQUID_BENCHMARK_SESSION_FILE": "/tmp/test-session/session.json",
            BenchmarkPreferenceConfiguration.suiteKey: suite,
            BenchmarkPreferenceConfiguration.receiptKey: "/tmp/test-session/preferences.json",
        ]
        let configuration = try BenchmarkPreferenceConfiguration.resolve(
            environment: environment, bundleIdentifier: bundle)!
        check(configuration.suite == suite, "exact suite")
        for identifier in [nil, "io.github.jagalite.illiquid", bundle + ".other"] {
            check(try BenchmarkPreferenceConfiguration.resolve(environment: environment,
                bundleIdentifier: identifier) == nil, "production launch ignores benchmark overrides")
        }
        for override in ["true", "0", ""] {
            var changed = environment; changed["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] = override
            check(try BenchmarkPreferenceConfiguration.resolve(environment: changed,
                bundleIdentifier: bundle) == nil, "override is exact")
        }
        for key in environment.keys where key != "ILLIQUID_ENABLE_BENCHMARK_OVERRIDES" {
            var changed = environment; changed.removeValue(forKey: key)
            rejects("missing session isolation field must fail") {
                _ = try BenchmarkPreferenceConfiguration.resolve(environment: changed, bundleIdentifier: bundle)
            }
        }
        for (key, value) in [
            (BenchmarkPreferenceConfiguration.suiteKey, bundle),
            (BenchmarkPreferenceConfiguration.suiteKey, suite + "-other"),
            ("ILLIQUID_BENCHMARK_CONTROL_SESSION", "bad session"),
            ("ILLIQUID_BENCHMARK_CONTROL_SESSION", String(repeating: "x", count: 97)),
            (BenchmarkPreferenceConfiguration.receiptKey, "relative.json"),
            (BenchmarkPreferenceConfiguration.receiptKey, environment["ILLIQUID_BENCHMARK_SESSION_FILE"]!),
            (BenchmarkPreferenceConfiguration.seedKey, "relative.json"),
        ] {
            var changed = environment; changed[key] = value
            rejects("bad or overlapping isolation field must fail") {
                _ = try BenchmarkPreferenceConfiguration.resolve(environment: changed, bundleIdentifier: bundle)
            }
        }

        let seedData = Data(#"{"Illiquid.width":42.5,"Illiquid.flag":true,"Illiquid.name":"fresh","Illiquid.list":["a","b"],"player.shortcut-overrides.v1":{"pause":"K"}}"#.utf8)
        let seed = try BenchmarkPreferenceSeed.decode(seedData)
        check(seed.sha256?.count == 64, "seed hash")
        check(try BenchmarkPreferenceSeed.decode(nil).values.isEmpty, "default seed empty")
        for text in ["[]", "null", "{} trailing", #"{"Other.key":true}"#,
                     #"{"Illiquid.null":null}"#, #"{"Illiquid.list":[null]}"#,
                     #"{"Illiquid.agent-ui-preference-suite.v1":"forged"}"#] {
            rejects("invalid seed rejected") { _ = try BenchmarkPreferenceSeed.decode(Data(text.utf8)) }
        }
        rejects("oversized seed rejected") {
            _ = try BenchmarkPreferenceSeed.decode(Data(repeating: 32, count: 1_048_577))
        }
        let domain = MemoryPreferenceDomains()
        let oldDomains = domain.domains
        let defaults = try BenchmarkSuiteDefaults(suite: suite, seed: seed.values, domain: domain)
        check(defaults.object(forKey: "Illiquid.polluted") == nil, "object cannot inherit polluted domain")
        check(!defaults.bool(forKey: "Illiquid.polluted"), "bool cannot inherit polluted domain")
        check(defaults.double(forKey: "Illiquid.width") == 42.5, "seed wins")
        check(defaults.float(forKey: "Illiquid.width") == 42.5, "float reads own domain")
        check(defaults.integer(forKey: "Illiquid.width") == 42, "integer reads own domain")
        check(defaults.string(forKey: "Illiquid.width") == "42.5", "number string conversion preserved")
        check(defaults.double(forKey: "Illiquid.flag") == 0, "bool is not a floating point preference")
        check(defaults.string(forKey: "Illiquid.name") == "fresh", "string reads own domain")
        check(defaults.stringArray(forKey: "Illiquid.list") == ["a", "b"], "array reads own domain")
        check(!defaults.dictionaryRepresentation().keys.contains("Illiquid.polluted"), "snapshot cannot inherit")
        defaults.register(defaults: ["Illiquid.registered": 7, "Illiquid.width": 55.0])
        check(defaults.integer(forKey: "Illiquid.registered") == 7, "local registration honored")
        check(defaults.double(forKey: "Illiquid.width") == 42.5, "registration cannot replace seed")
        defaults.set(23, forKey: "Illiquid.int")
        defaults.set(Float(1.5), forKey: "Illiquid.float")
        defaults.set(false, forKey: "Illiquid.flag")
        defaults.set(Data([1, 2, 3]), forKey: "Illiquid.data")
        defaults.set(["value": "own"], forKey: "Illiquid.dictionary")
        defaults.set(URL(fileURLWithPath: "/tmp/owned"), forKey: "Illiquid.url")
        check(defaults.integer(forKey: "Illiquid.int") == 23, "typed int write")
        check(defaults.float(forKey: "Illiquid.float") == 1.5, "typed float write")
        check(!defaults.bool(forKey: "Illiquid.flag"), "typed bool write")
        check(defaults.data(forKey: "Illiquid.data") == Data([1, 2, 3]), "data write")
        check(defaults.dictionary(forKey: "Illiquid.dictionary")?["value"] as? String == "own", "dictionary write")
        check(defaults.url(forKey: "Illiquid.url")?.path == "/tmp/owned", "url write")
        let remoteURL = URL(string: "https://example.invalid/owned")!
        defaults.set(remoteURL, forKey: "Illiquid.remote-url")
        check(defaults.url(forKey: "Illiquid.remote-url") == remoteURL, "non-file url write")
        defaults.removeObject(forKey: "Illiquid.width")
        check(defaults.double(forKey: "Illiquid.width") == 55, "remove reveals local registration only")
        defaults.removeObject(forKey: "Illiquid.polluted")
        check(defaults.object(forKey: "Illiquid.polluted") == nil, "remove cannot reveal shared value")
        let scale = PlayerInterfaceScaleStore(defaults: defaults)
        check(scale.percentage == 90, "scale store ignores shared suite pollution")
        scale.select(110)
        check(defaults.integer(forKey: PlayerInterfaceScaleStore.storageKey) == 110, "scale store writes own suite")
        check(PlaybackChromePreferences.load(defaults: defaults) == 2.5, "chrome loader ignores shared suite pollution")
        defaults.set(4.5, forKey: PlaybackChromePreferences.storageKey)
        check(PlaybackChromePreferences.load(defaults: defaults) == 4.5, "chrome loader reads own suite")

        // A real AppStorage binding uses the adapter, without a window or input.
        @AppStorage("Illiquid.app-storage", store: defaults) var stored = 12.0
        check(stored == 12, "AppStorage starts from code default")
        $stored.wrappedValue = 18.0
        check(defaults.double(forKey: "Illiquid.app-storage") == 18, "AppStorage writes own suite")
        let observer = PreferenceKVOObserver()
        defaults.addObserver(observer, forKeyPath: "observedControl", options: [.new], context: nil)
        defaults.set(true, forKey: "observedControl")
        defaults.removeObserver(observer, forKeyPath: "observedControl")
        check(observer.changes == 1, "adapter emits a KVO change for observers")
        check(domain.reads == [suite], "only chosen suite read")
        check(Set(domain.writes) == [suite], "only chosen suite written")
        for name in oldDomains.keys {
            check(NSDictionary(dictionary: domain.domains[name]!).isEqual(to: oldDomains[name]!), "shared domains untouched")
        }
        rejects("reuse must never reset existing suite") {
            _ = try BenchmarkSuiteDefaults(suite: suite, seed: [:], domain: domain)
        }
        let emptySuite = suite + "-empty"
        _ = try BenchmarkSuiteDefaults(suite: emptySuite, seed: [:], domain: domain)
        rejects("even empty seed reserves suite") {
            _ = try BenchmarkSuiteDefaults(suite: emptySuite, seed: [:], domain: domain)
        }

        let clean = try BenchmarkSuiteDefaults(suite: suite, seed: seed.values, domain: MemoryPreferenceDomains())
        let receiptData = try BenchmarkPreferenceReceipt.data(configuration: configuration, seed: seed, defaults: clean)
        let receipt = try JSONSerialization.jsonObject(with: receiptData) as! [String: Any]
        check(receipt["isolation_mode"] as? String == "session-suite-only", "receipt mode")
        check(receipt["suite"] as? String == suite, "receipt suite")
        check(receipt["seed_sha256"] as? String == seed.sha256, "receipt seed identity")
        let canonical = try JSONSerialization.data(withJSONObject: receipt["effective_initial_values"]!, options: [.sortedKeys])
        let hash = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        check(receipt["effective_initial_sha256"] as? String == hash, "receipt effective hash")
        let canonicalText = receipt["effective_initial_canonical_json"] as! String
        check(Data(canonicalText.utf8) == canonical, "cross-language hash input retained verbatim")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("preferences.json")
        try BenchmarkPreferenceReceipt.write(receiptData, to: destination)
        rejects("receipt overwrite refused") { try BenchmarkPreferenceReceipt.write(Data("other".utf8), to: destination) }
        check(try Data(contentsOf: destination) == receiptData, "original receipt retained")
        check(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["preferences.json"], "temporary receipt cleaned")
        print("Preference controls passed: \(checks); memory-backed domains, no GUI or userprefs mutation")
    }
}
