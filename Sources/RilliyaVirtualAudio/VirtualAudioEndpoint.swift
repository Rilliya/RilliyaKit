// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A stable identity for one Rilliya-managed virtual Core Audio device.
///
/// Persist this value in workflows and user settings. Never persist a HAL `AudioObjectID`, which
/// is meaningful only while one Core Audio process is running.
public struct VirtualAudioEndpointID: RawRepresentable, Codable, Hashable, Sendable {
  /// The persistent UUID representation.
  public let rawValue: UUID

  /// Creates an identity from a persistent UUID.
  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  /// Creates a new stable identity.
  public init() {
    rawValue = UUID()
  }
}

/// The direction in which a virtual device appears to other Core Audio clients.
public enum VirtualAudioEndpointDirection: String, Codable, CaseIterable, Hashable, Sendable {
  /// Other applications capture audio that Rilliya supplies to this device.
  case input

  /// Other applications play audio into this device for Rilliya to consume.
  case output
}

/// A validated PCM format published by a virtual audio endpoint.
public struct VirtualAudioEndpointFormat: Codable, Equatable, Hashable, Sendable {
  /// A common default suitable for voice and general-purpose routing.
  public static let stereo48kHz = VirtualAudioEndpointFormat(
    validatedSampleRate: 48_000,
    channelCount: 2
  )

  /// The number of complete sample frames per second.
  public let sampleRate: Double

  /// The number of noninterleaved Float32 channels.
  public let channelCount: Int

  /// Creates a validated endpoint format.
  public init(sampleRate: Double = 48_000, channelCount: Int = 2) throws {
    guard Self.isValid(sampleRate: sampleRate) else {
      throw VirtualAudioEndpointValidationError.invalidSampleRate(sampleRate)
    }
    guard (1...256).contains(channelCount) else {
      throw VirtualAudioEndpointValidationError.invalidChannelCount(channelCount)
    }
    self.sampleRate = sampleRate
    self.channelCount = channelCount
  }

  private init(validatedSampleRate sampleRate: Double, channelCount: Int) {
    self.sampleRate = sampleRate
    self.channelCount = channelCount
  }

  private static func isValid(sampleRate: Double) -> Bool {
    sampleRate.isFinite
      && (1...768_000).contains(sampleRate)
      && abs(sampleRate.rounded() - sampleRate) < 0.001
  }

  private enum CodingKeys: String, CodingKey {
    case sampleRate
    case channelCount
  }

  /// Decodes and revalidates a persisted endpoint format.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      sampleRate: container.decode(Double.self, forKey: .sampleRate),
      channelCount: container.decode(Int.self, forKey: .channelCount)
    )
  }
}

/// User-controlled properties for one virtual audio endpoint.
public struct VirtualAudioEndpointConfiguration: Codable, Equatable, Hashable, Sendable {
  /// The maximum UTF-8 storage accepted for a display name.
  public static let maximumNameByteCount = 128

  /// The normalized, nonempty name published to Core Audio clients.
  public let name: String

  /// The direction exposed to other Core Audio clients.
  public let direction: VirtualAudioEndpointDirection

  /// The endpoint's native PCM format.
  public let format: VirtualAudioEndpointFormat

  /// Creates a validated endpoint configuration.
  public init(
    name: String,
    direction: VirtualAudioEndpointDirection,
    format: VirtualAudioEndpointFormat = .stereo48kHz
  ) throws {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw VirtualAudioEndpointValidationError.emptyName
    }
    guard normalizedName.utf8.count <= Self.maximumNameByteCount else {
      throw VirtualAudioEndpointValidationError.nameTooLong(
        maximumByteCount: Self.maximumNameByteCount
      )
    }
    guard
      !normalizedName.unicodeScalars.contains(where: { scalar in
        CharacterSet.controlCharacters.contains(scalar)
      })
    else {
      throw VirtualAudioEndpointValidationError.nameContainsControlCharacter
    }
    self.name = normalizedName
    self.direction = direction
    self.format = format
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case direction
    case format
  }

  /// Decodes and revalidates a persisted endpoint configuration.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      name: container.decode(String.self, forKey: .name),
      direction: container.decode(VirtualAudioEndpointDirection.self, forKey: .direction),
      format: container.decode(VirtualAudioEndpointFormat.self, forKey: .format)
    )
  }
}

/// One persistent virtual device managed by Rilliya.
public struct VirtualAudioEndpoint: Codable, Equatable, Hashable, Identifiable, Sendable {
  /// The stable identity referenced by workflows.
  public let id: VirtualAudioEndpointID

  /// The current user-controlled endpoint properties.
  public let configuration: VirtualAudioEndpointConfiguration

  /// Creates an endpoint from a stable identity and validated configuration.
  public init(
    id: VirtualAudioEndpointID = VirtualAudioEndpointID(),
    configuration: VirtualAudioEndpointConfiguration
  ) {
    self.id = id
    self.configuration = configuration
  }
}

/// A validation failure that is safe to surface at an application boundary.
public enum VirtualAudioEndpointValidationError: Error, Equatable, LocalizedError, Sendable {
  /// A display name contains only whitespace.
  case emptyName

  /// A display name exceeds the bounded UTF-8 representation.
  case nameTooLong(maximumByteCount: Int)

  /// A display name contains a control character.
  case nameContainsControlCharacter

  /// A sample rate is nonfinite, fractional, or outside the supported safety bound.
  case invalidSampleRate(Double)

  /// A channel count is outside the processing bound.
  case invalidChannelCount(Int)

  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .emptyName:
      "A virtual audio device name cannot be empty."
    case .nameTooLong(let maximumByteCount):
      "A virtual audio device name cannot exceed \(maximumByteCount) UTF-8 bytes."
    case .nameContainsControlCharacter:
      "A virtual audio device name cannot contain control characters."
    case .invalidSampleRate(let sampleRate):
      "A virtual audio device sample rate must be a whole value between 1 and 768,000 Hz; received \(sampleRate)."
    case .invalidChannelCount(let channelCount):
      "A virtual audio device channel count must be between 1 and 256; received \(channelCount)."
    }
  }
}
