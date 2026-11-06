import Foundation
import IlliquidPlaybackModel
import IlliquidPlaybackStateSpace
import Testing

/// The production migration oracle (Tests/IlliquidPlaybackModelTests) froze
/// the reachable search seeds built by the legacy core in P0. The seed builder
/// now drives the production model; it must still reach exactly those states.
@Suite("Production seed oracle")
struct ProductionSeedOracleTests {
  struct Start: Codable { var name: String; var state: String }
  struct Fixture: Codable { var starts: [Start] }

  @Test func reachableSeedsMatchTheFrozenLegacyStarts() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("IlliquidPlaybackModelTests/Fixtures/production-migration-oracle-v1.json")
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    let frozen = Dictionary(uniqueKeysWithValues: fixture.starts.map { ($0.name, $0.state) })
    var checked = 0
    for model in PlaybackSearchModel.allCases {
      let definition = PlaybackSearchModelDefinition(model: model)
      for profile in definition.inventory.seedProfiles {
        let name = "\(model.rawValue)/\(profile)"
        let seed = try definition.makeSeed(profile: profile)
        let encoded = Data(try CanonicalJSON.encode(seed.coreState)).base64EncodedString()
        #expect(frozen[name] == encoded, "\(name)")
        checked += 1
      }
    }
    #expect(checked == fixture.starts.count - 2, "fresh and exhausted-ids are not search seeds")
  }
}
