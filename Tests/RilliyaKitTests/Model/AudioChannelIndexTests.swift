// SPDX-License-Identifier: Apache-2.0

import RilliyaKit
import Testing

@Suite("AudioChannelIndex")
struct AudioChannelIndexTests {
  @Test("Accepts nonnegative indices", arguments: [0, 1, Int.max])
  func acceptsNonnegativeIndices(rawValue: Int) throws {
    let index = try #require(AudioChannelIndex(rawValue: rawValue))

    #expect(index.rawValue == rawValue)
  }

  @Test("Rejects negative indices", arguments: [-1, Int.min])
  func rejectsNegativeIndices(rawValue: Int) {
    #expect(AudioChannelIndex(rawValue: rawValue) == nil)
  }

  @Test("Orders indices by channel position")
  func ordersIndices() throws {
    let left = try #require(AudioChannelIndex(rawValue: 0))
    let right = try #require(AudioChannelIndex(rawValue: 1))

    #expect(left < right)
    #expect(right > left)
  }
}
