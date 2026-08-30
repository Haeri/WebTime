import Foundation

public enum UnlockChallenge {
  private static let words = [
    "amber", "anchor", "apricot", "atlas", "badger", "bamboo", "beacon", "birch",
    "bison", "bluebird", "bramble", "bronze", "cactus", "canyon", "cedar", "cinder",
    "cobalt", "comet", "coral", "cricket", "dahlia", "delta", "driftwood", "ember",
    "falcon", "fern", "fjord", "fossil", "foxglove", "garnet", "glacier", "granite",
    "harbor", "hazel", "heron", "hickory", "indigo", "island", "ivory", "juniper",
    "kelp", "lagoon", "lantern", "lilac", "linden", "lotus", "marble", "meadow",
    "mercury", "moss", "nebula", "nectar", "nickel", "oasis", "obsidian", "olive",
    "onyx", "orchid", "otter", "pebble", "pepper", "pine", "plover", "prairie",
    "quartz", "raven", "redwood", "river", "robin", "saffron", "sage", "sequoia",
    "silver", "sparrow", "spruce", "starling", "stone", "summit", "thistle", "timber",
    "topaz", "tundra", "valley", "velvet", "violet", "walnut", "willow", "wren",
  ]

  /// Generates a deliberately long, readable challenge. It is returned to the caller only and is
  /// never persisted by the limiter.
  public static func generate(wordCount: Int = 12) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<max(1, wordCount))
      .map { _ in words.randomElement(using: &generator)! }
      .joined(separator: " ")
  }

  public static func matches(typed: String, challenge: String) -> Bool {
    typed.trimmingCharacters(in: .whitespacesAndNewlines) == challenge
  }
}
