// SPDX-License-Identifier: Apache-2.0

/// A validated zero-based index into the channels of an audio buffer or stream.
public struct AudioChannelIndex: Hashable, Comparable, RawRepresentable, Sendable {
  /// The zero-based integer represented by this index.
  public let rawValue: Int

  /// Creates an index when `rawValue` is nonnegative.
  ///
  /// - Parameter rawValue: The zero-based channel position.
  public init?(rawValue: Int) {
    guard rawValue >= 0 else { return nil }
    self.rawValue = rawValue
  }

  /// Orders channel indices by their zero-based positions.
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
