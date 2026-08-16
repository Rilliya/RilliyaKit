// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A channel-count constraint carried by an audio signal port.
public enum AudioGraphChannelCount: Hashable, Codable, Sendable {
  /// The port requires a concrete positive channel count.
  case fixed(Int)

  /// The port accepts or produces a channel count resolved during graph preparation.
  case any
}

/// A sample-rate constraint carried by an audio signal port.
public enum AudioGraphSampleRate: Hashable, Codable, Sendable {
  /// The port requires a concrete finite sample rate.
  case fixed(Double)

  /// The port accepts or produces a rate resolved during graph preparation.
  case any
}

/// The format constraints of one noninterleaved Float32 audio bus.
public struct AudioGraphAudioSignalType: Hashable, Codable, Sendable {
  /// The required or deferred channel count.
  public let channelCount: AudioGraphChannelCount

  /// The required or deferred sample rate.
  public let sampleRate: AudioGraphSampleRate

  /// Creates an audio signal constraint.
  public init(
    channelCount: AudioGraphChannelCount = .any,
    sampleRate: AudioGraphSampleRate = .any
  ) {
    self.channelCount = channelCount
    self.sampleRate = sampleRate
  }
}

/// A scalar value carried outside the audio sample stream.
public enum AudioGraphScalarType: String, Hashable, Codable, Sendable {
  /// A signed integer value.
  case integer

  /// A floating-point value without additional semantic bounds.
  case floatingPoint

  /// A floating-point confidence value conventionally bounded to zero through one.
  case confidence
}

/// The semantic value carried by a graph port.
public enum AudioGraphSignalType: Hashable, Codable, Sendable {
  /// A realtime audio bus.
  case audio(AudioGraphAudioSignalType)

  /// A scalar control or analysis value.
  case scalar(AudioGraphScalarType)

  /// A category label. A `nil` domain on an input is a wildcard accepting any category domain.
  case category(domain: AudioGraphCategoryDomainID?)

  /// A nominal structured value. Structure compatibility requires the same schema identity.
  case structure(AudioGraphStructureID)
}

/// A lossless implicit conversion selected while connecting compatible ports.
public enum AudioGraphImplicitConversion: String, Hashable, Codable, Sendable {
  /// Widens an integer value to floating point.
  case integerToFloatingPoint

  /// Exposes a confidence value as an ordinary floating-point value.
  case eraseConfidenceSemantic
}

/// The reason two signal types cannot be connected directly.
public enum AudioGraphSignalIncompatibility: Equatable, Sendable {
  /// The source and target carry different signal families.
  case differentSignalFamilies

  /// The source cannot prove the target's channel-count requirement.
  case incompatibleChannelCount

  /// The source and target require different sample rates.
  case incompatibleSampleRate

  /// The scalar conversion would narrow or change semantic meaning.
  case incompatibleScalarTypes

  /// The category domains are incompatible.
  case incompatibleCategoryDomains

  /// The nominal structure identities differ.
  case incompatibleStructures
}

/// The direct compatibility result for two signal types.
public enum AudioGraphSignalCompatibility: Equatable, Sendable {
  /// The connection is valid, optionally through one lossless implicit conversion.
  case compatible(conversion: AudioGraphImplicitConversion?)

  /// The connection is invalid for the reported reason.
  case incompatible(AudioGraphSignalIncompatibility)
}

extension AudioGraphSignalType {
  /// Evaluates whether this source signal can feed the supplied target signal.
  public func compatibility(
    with target: AudioGraphSignalType
  ) -> AudioGraphSignalCompatibility {
    switch (self, target) {
    case (.audio(let source), .audio(let target)):
      guard Self.channelCount(source.channelCount, satisfies: target.channelCount) else {
        return .incompatible(.incompatibleChannelCount)
      }
      guard Self.sampleRate(source.sampleRate, satisfies: target.sampleRate) else {
        return .incompatible(.incompatibleSampleRate)
      }
      return .compatible(conversion: nil)

    case (.scalar(let source), .scalar(let target)):
      if source == target {
        return .compatible(conversion: nil)
      }
      switch (source, target) {
      case (.integer, .floatingPoint):
        return .compatible(conversion: .integerToFloatingPoint)
      case (.confidence, .floatingPoint):
        return .compatible(conversion: .eraseConfidenceSemantic)
      default:
        return .incompatible(.incompatibleScalarTypes)
      }

    case (.category(let source), .category(let target)):
      if source == target || target == nil {
        return .compatible(conversion: nil)
      }
      return .incompatible(.incompatibleCategoryDomains)

    case (.structure(let source), .structure(let target)):
      return source == target
        ? .compatible(conversion: nil)
        : .incompatible(.incompatibleStructures)

    default:
      return .incompatible(.differentSignalFamilies)
    }
  }

  private static func channelCount(
    _ source: AudioGraphChannelCount,
    satisfies target: AudioGraphChannelCount
  ) -> Bool {
    switch (source, target) {
    case (.fixed(let source), .fixed(let target)):
      return source == target
    case (.fixed, .any), (.any, .any):
      return true
    case (.any, .fixed):
      return false
    }
  }

  private static func sampleRate(
    _ source: AudioGraphSampleRate,
    satisfies target: AudioGraphSampleRate
  ) -> Bool {
    switch (source, target) {
    case (.fixed(let source), .fixed(let target)):
      return source == target
    case (.fixed, .any), (.any, .any):
      return true
    case (.any, .fixed):
      return false
    }
  }
}
