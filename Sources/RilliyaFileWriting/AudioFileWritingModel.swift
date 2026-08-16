// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import RilliyaRealtime

/// A file container supported by the public Core Audio file-writing API.
public enum AudioFileContainer: String, CaseIterable, Codable, Hashable, Sendable {
  /// A RIFF Wave file.
  case wave

  /// An Audio Interchange File Format file.
  case aiff

  /// An Apple Core Audio Format file.
  case coreAudioFormat

  /// An MPEG-4 Audio file with an `.m4a` extension.
  case m4a

  /// The preferred filename extension for the container.
  public var filenameExtension: String {
    switch self {
    case .wave: "wav"
    case .aiff: "aiff"
    case .coreAudioFormat: "caf"
    case .m4a: "m4a"
    }
  }

  /// A concise user-facing container name.
  public var displayName: String {
    switch self {
    case .wave: "WAV"
    case .aiff: "AIFF"
    case .coreAudioFormat: "CAF"
    case .m4a: "M4A"
    }
  }

  package var audioFileTypeID: AudioFileTypeID {
    switch self {
    case .wave: kAudioFileWAVEType
    case .aiff: kAudioFileAIFFType
    case .coreAudioFormat: kAudioFileCAFType
    case .m4a: kAudioFileM4AType
    }
  }
}

/// The encoded representation stored inside an audio file.
public enum AudioFileEncoding: Codable, Equatable, Hashable, Sendable {
  /// Signed integer linear PCM with the requested bit depth.
  case integerPCM(bitDepth: Int)

  /// Native Float32 linear PCM.
  case float32PCM

  /// MPEG-4 AAC at the requested target bitrate in bits per second.
  case aac(bitRate: Int)

  /// Apple Lossless with the requested source bit-depth hint.
  case appleLossless(bitDepth: Int)

  /// A concise user-facing encoding name.
  public var displayName: String {
    switch self {
    case .integerPCM(let bitDepth): "PCM \(bitDepth)-bit"
    case .float32PCM: "Float32 PCM"
    case .aac(let bitRate): "AAC · \(bitRate / 1_000) kbps"
    case .appleLossless(let bitDepth): "Apple Lossless · \(bitDepth)-bit"
    }
  }
}

/// The behavior used when a destination already exists.
public enum AudioFileCollisionPolicy: String, Codable, Hashable, Sendable {
  /// Refuses to overwrite an existing file.
  case fail

  /// Adds a numeric suffix until an unused sibling URL is found.
  case appendSequenceNumber

  /// Replaces an existing file. Hosts should expose this only after explicit user confirmation.
  case replace
}

/// Immutable controls for one bounded file-writing session.
public struct AudioFileWriterConfiguration: Codable, Equatable, Hashable, Sendable {
  /// The largest target bitrate accepted by the validation layer.
  public static let maximumBitRate = 1_536_000

  /// The base destination selected by the host.
  public let destinationURL: URL

  /// The destination file container.
  public let container: AudioFileContainer

  /// The representation stored inside the container.
  public let encoding: AudioFileEncoding

  /// The processing sample rate supplied by the producer.
  public let sampleRate: Double

  /// The number of planar Float32 channels supplied by the producer.
  public let channelCount: Int

  /// The fixed queue shared by the realtime producer and background writer.
  public let capacityFrameCount: Int

  /// The largest disk-write chunk consumed from the queue.
  public let chunkFrameCount: Int

  /// The policy used when the base destination already exists.
  public let collisionPolicy: AudioFileCollisionPolicy

  /// Creates and validates one file-writing configuration.
  public init(
    destinationURL: URL,
    container: AudioFileContainer,
    encoding: AudioFileEncoding,
    sampleRate: Double,
    channelCount: Int,
    capacityFrameCount: Int = 16_384,
    chunkFrameCount: Int = 1_024,
    collisionPolicy: AudioFileCollisionPolicy = .appendSequenceNumber
  ) throws {
    guard destinationURL.isFileURL else { throw AudioFileWriterError.nonFileURL }
    guard destinationURL.lastPathComponent.isEmpty == false else {
      throw AudioFileWriterError.invalidDestination
    }
    guard sampleRate.isFinite, sampleRate > 0 else {
      throw AudioFileWriterError.invalidSampleRate(sampleRate)
    }
    guard (1...AudioProcessingFormat.maximumChannelCount).contains(channelCount) else {
      throw AudioFileWriterError.unsupportedChannelCount(channelCount)
    }
    guard
      (2...AudioRealtimeFrameBuffer.maximumCapacityFrameCount).contains(
        capacityFrameCount
      ),
      (1...capacityFrameCount).contains(chunkFrameCount)
    else {
      throw AudioFileWriterError.invalidBufferConfiguration
    }
    try Self.validate(encoding: encoding, in: container)
    self.destinationURL = destinationURL
    self.container = container
    self.encoding = encoding
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.capacityFrameCount = capacityFrameCount
    self.chunkFrameCount = chunkFrameCount
    self.collisionPolicy = collisionPolicy
  }

  private static func validate(
    encoding: AudioFileEncoding,
    in container: AudioFileContainer
  ) throws {
    switch encoding {
    case .integerPCM(let bitDepth):
      guard [16, 24].contains(bitDepth) else {
        throw AudioFileWriterError.unsupportedBitDepth(bitDepth)
      }
      guard container != .m4a else {
        throw AudioFileWriterError.incompatibleContainerAndEncoding
      }
    case .float32PCM:
      guard container == .wave || container == .coreAudioFormat else {
        throw AudioFileWriterError.incompatibleContainerAndEncoding
      }
    case .aac(let bitRate):
      guard container == .m4a else {
        throw AudioFileWriterError.incompatibleContainerAndEncoding
      }
      guard (8_000...maximumBitRate).contains(bitRate) else {
        throw AudioFileWriterError.invalidBitRate(bitRate)
      }
    case .appleLossless(let bitDepth):
      guard container == .m4a else {
        throw AudioFileWriterError.incompatibleContainerAndEncoding
      }
      guard [16, 20, 24, 32].contains(bitDepth) else {
        throw AudioFileWriterError.unsupportedBitDepth(bitDepth)
      }
    }
  }
}

/// A file-writing setup, encoding, or background IO failure.
public enum AudioFileWriterError: Error, Equatable, LocalizedError, Sendable {
  /// The destination must be a local file URL.
  case nonFileURL

  /// The destination filename is empty.
  case invalidDestination

  /// The requested processing sample rate is invalid.
  case invalidSampleRate(Double)

  /// The channel count exceeds the bounded processing model.
  case unsupportedChannelCount(Int)

  /// The queue or write chunk is invalid.
  case invalidBufferConfiguration

  /// The selected bit depth is unsupported.
  case unsupportedBitDepth(Int)

  /// The target bitrate is invalid.
  case invalidBitRate(Int)

  /// The selected container cannot store the requested encoding.
  case incompatibleContainerAndEncoding

  /// The current system does not expose the requested public encoder.
  case encoderUnavailable(AudioFileEncoding)

  /// The destination exists and replacement was not authorized.
  case destinationExists(URL)

  /// Core Audio could not create the destination file.
  case createFailed(operation: String, status: Int32)

  /// Core Audio could not configure the client or encoder format.
  case formatConfigurationFailed(operation: String, status: Int32)

  /// Core Audio could not write a queued PCM block.
  case writeFailed(status: Int32)

  /// The session was stopped before startup completed.
  case cancelled

  /// A localized explanation suitable for host UI and logs.
  public var errorDescription: String? {
    switch self {
    case .nonFileURL:
      "Audio file output requires a local file URL."
    case .invalidDestination:
      "Audio file output requires a destination filename."
    case .invalidSampleRate(let rate):
      "The file output sample rate must be finite and positive; received \(rate)."
    case .unsupportedChannelCount(let count):
      "The file output channel count must be between 1 and 256; received \(count)."
    case .invalidBufferConfiguration:
      "The file output queue and write chunk must be positive and remain within bounded storage."
    case .unsupportedBitDepth(let bitDepth):
      "The selected \(bitDepth)-bit encoding is not supported."
    case .invalidBitRate(let bitRate):
      "The selected bitrate of \(bitRate) bits per second is not supported."
    case .incompatibleContainerAndEncoding:
      "The selected audio container cannot store that encoding."
    case .encoderUnavailable(let encoding):
      "The current macOS installation does not provide a public \(encoding.displayName) encoder."
    case .destinationExists(let url):
      "The destination already exists: \(url.lastPathComponent)."
    case .createFailed(let operation, let status):
      "Core Audio could not create the output file while performing \(operation) (status \(status))."
    case .formatConfigurationFailed(let operation, let status):
      "Core Audio could not configure the output while performing \(operation) (status \(status))."
    case .writeFailed(let status):
      "Core Audio could not write the next audio block (status \(status))."
    case .cancelled:
      "The file output session stopped before startup completed."
    }
  }
}

/// One inclusive bitrate range reported by the public Core Audio encoder registry.
public struct AudioFileBitRateRange: Equatable, Sendable {
  /// The lowest reported bitrate in bits per second.
  public let lowerBound: Int

  /// The highest reported bitrate in bits per second.
  public let upperBound: Int

  /// Creates a validated inclusive bitrate range.
  public init(lowerBound: Int, upperBound: Int) {
    precondition(lowerBound > 0)
    precondition(upperBound >= lowerBound)
    self.lowerBound = lowerBound
    self.upperBound = upperBound
  }

  /// Returns whether the encoder range contains a target bitrate.
  public func contains(_ bitRate: Int) -> Bool {
    (lowerBound...upperBound).contains(bitRate)
  }
}

/// The public encoders currently installed on the host system.
public struct AudioFileWritingCapabilities: Equatable, Sendable {
  /// Whether the system exposes the MPEG-4 AAC encoder.
  public let supportsAAC: Bool

  /// Whether the system exposes the Apple Lossless encoder.
  public let supportsAppleLossless: Bool

  /// The AAC bitrate ranges reported by the public AudioFormat API.
  ///
  /// An empty collection means the encoder registry did not provide this optional detail. It does
  /// not by itself mean AAC is unavailable.
  public let aacBitRateRanges: [AudioFileBitRateRange]

  /// Creates a capability value, primarily for deterministic host tests.
  public init(
    supportsAAC: Bool,
    supportsAppleLossless: Bool,
    aacBitRateRanges: [AudioFileBitRateRange] = []
  ) {
    self.supportsAAC = supportsAAC
    self.supportsAppleLossless = supportsAppleLossless
    self.aacBitRateRanges = aacBitRateRanges
  }

  /// Queries the public AudioToolbox encoder registry on the current system.
  public static func current() -> AudioFileWritingCapabilities {
    let identifiers = systemEncoderIdentifiers()
    return AudioFileWritingCapabilities(
      supportsAAC: identifiers.contains(kAudioFormatMPEG4AAC),
      supportsAppleLossless: identifiers.contains(kAudioFormatAppleLossless),
      aacBitRateRanges: availableBitRateRanges(for: kAudioFormatMPEG4AAC)
    )
  }

  /// Returns whether the requested encoding can be created on this system.
  public func supports(_ encoding: AudioFileEncoding) -> Bool {
    switch encoding {
    case .integerPCM, .float32PCM: true
    case .aac: supportsAAC
    case .appleLossless: supportsAppleLossless
    }
  }

  /// Filters host-provided bitrate choices through the ranges advertised by the AAC encoder.
  ///
  /// If the optional range query is unavailable, validated choices are retained so a host can
  /// still rely on the encoder's authoritative setup result.
  public func supportedAACBitRates(from candidates: [Int]) -> [Int] {
    guard supportsAAC else { return [] }
    let validated = candidates.filter {
      (8_000...AudioFileWriterConfiguration.maximumBitRate).contains($0)
    }
    guard !aacBitRateRanges.isEmpty else { return validated }
    return validated.filter { bitRate in
      aacBitRateRanges.contains { $0.contains(bitRate) }
    }
  }

  private static func availableBitRateRanges(
    for formatID: AudioFormatID
  ) -> [AudioFileBitRateRange] {
    var mutableFormatID = formatID
    var byteCount: UInt32 = 0
    let infoStatus = withUnsafePointer(to: &mutableFormatID) { specifier in
      AudioFormatGetPropertyInfo(
        kAudioFormatProperty_AvailableEncodeBitRates,
        UInt32(MemoryLayout<AudioFormatID>.size),
        specifier,
        &byteCount
      )
    }
    guard infoStatus == noErr,
      byteCount % UInt32(MemoryLayout<AudioValueRange>.stride) == 0
    else {
      return []
    }
    var ranges = [AudioValueRange](
      repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
      count: Int(byteCount) / MemoryLayout<AudioValueRange>.stride
    )
    let readStatus = withUnsafePointer(to: &mutableFormatID) { specifier in
      ranges.withUnsafeMutableBytes { bytes in
        AudioFormatGetProperty(
          kAudioFormatProperty_AvailableEncodeBitRates,
          UInt32(MemoryLayout<AudioFormatID>.size),
          specifier,
          &byteCount,
          bytes.baseAddress
        )
      }
    }
    guard readStatus == noErr else { return [] }
    return ranges.prefix(Int(byteCount) / MemoryLayout<AudioValueRange>.stride).compactMap {
      guard $0.mMinimum.isFinite, $0.mMaximum.isFinite,
        $0.mMinimum > 0, $0.mMaximum >= $0.mMinimum,
        $0.mMaximum <= Double(Int.max)
      else {
        return nil
      }
      return AudioFileBitRateRange(
        lowerBound: Int($0.mMinimum.rounded(.up)),
        upperBound: Int($0.mMaximum.rounded(.down))
      )
    }
  }

  private static func systemEncoderIdentifiers() -> Set<AudioFormatID> {
    var byteCount: UInt32 = 0
    guard
      AudioFormatGetPropertyInfo(
        kAudioFormatProperty_EncodeFormatIDs,
        0,
        nil,
        &byteCount
      ) == noErr,
      byteCount % UInt32(MemoryLayout<AudioFormatID>.stride) == 0
    else {
      return []
    }
    var identifiers = [AudioFormatID](
      repeating: 0,
      count: Int(byteCount) / MemoryLayout<AudioFormatID>.stride
    )
    let status = identifiers.withUnsafeMutableBytes { bytes in
      AudioFormatGetProperty(
        kAudioFormatProperty_EncodeFormatIDs,
        0,
        nil,
        &byteCount,
        bytes.baseAddress
      )
    }
    guard status == noErr else { return [] }
    return Set(identifiers.prefix(Int(byteCount) / MemoryLayout<AudioFormatID>.stride))
  }
}

/// A terminal event emitted away from the realtime producer.
public enum AudioFileWriterEvent: Equatable, Sendable {
  /// The file was finalized after the requested stop.
  case completed(url: URL, frameCount: UInt64)

  /// Background encoding or IO stopped after a typed failure.
  case failed(AudioFileWriterError)
}
