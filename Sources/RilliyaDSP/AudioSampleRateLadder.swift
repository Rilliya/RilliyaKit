// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Chooses the rate a source is carried at when only certain rates are available.
///
/// Resampling is not free of consequence: moving a source down throws away bandwidth it had, and
/// nothing later can put it back. So a source is carried at its own rate when that rate is
/// offered, and otherwise at the lowest offered rate above it. Only a source above everything on
/// offer is brought down, to the highest rate there is, because there is nowhere else to put it.
public enum AudioSampleRateLadder {
  /// The rate `input` should be carried at, given what is `supported`.
  ///
  /// - Parameters:
  ///   - input: the source's own sample rate.
  ///   - supported: the rates available, in any order.
  /// - Returns: the rate to carry the source at, or `nil` when nothing is on offer or the input
  ///   is not a usable rate.
  public static func resolve(input: Double, supported: [Double]) -> Double? {
    guard input.isFinite, input > 0 else { return nil }
    let usable = supported.filter { $0.isFinite && $0 > 0 }.sorted()
    guard let highest = usable.last else { return nil }
    if usable.contains(input) { return input }
    return usable.first { $0 > input } ?? highest
  }

  /// Whether carrying `input` at `resolved` loses bandwidth the source had.
  ///
  /// True only where the source sits above everything on offer, which is the one case the ladder
  /// cannot answer by going up.
  public static func loses(input: Double, resolved: Double) -> Bool {
    resolved < input
  }
}
