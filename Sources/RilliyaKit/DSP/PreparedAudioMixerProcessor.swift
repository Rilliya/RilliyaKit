// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The immutable bus layout used to prepare a realtime audio mixer.
public struct AudioMixerRenderPreparation: Equatable, Hashable, Sendable {
  /// Input buses in stable graph order.
  public let inputFormats: [AudioProcessingFormat]

  /// The output format and maximum render quantum.
  public let output: AudioRenderPreparation

  /// The number of channel pointers expected across every flattened input bus.
  public let flattenedInputChannelCount: Int

  /// Creates a mixer preparation after validating that every bus shares one clock rate.
  ///
  /// Input channel pointers are supplied in input-bus order, then channel order within each bus.
  public init(
    inputFormats: [AudioProcessingFormat],
    output: AudioRenderPreparation
  ) throws {
    guard inputFormats.allSatisfy({ $0.sampleRate == output.format.sampleRate }) else {
      throw AudioDSPConfigurationError.incompatibleMixerSampleRates
    }
    self.inputFormats = inputFormats
    self.output = output
    flattenedInputChannelCount = inputFormats.reduce(0) { $0 + $1.channelCount }
  }
}

/// A prepared matrix mixer with click-free output controls.
///
/// Routes and storage are compiled before rendering. `process` clears and reuses internal planar
/// Float32 mix buffers, sums every route with vDSP, and then applies atomically published output
/// gain and mute controls. It performs no allocation, locking, logging, or user callback work.
/// Calls for one instance must remain serialized on one render thread; control updates are safe
/// from other threads.
public final class PreparedAudioMixerProcessor: @unchecked Sendable {
  private struct CompiledRoute: Sendable {
    let flattenedSourceChannel: Int
    let destinationChannel: Int
    let gain: Float
  }

  /// The immutable preparation used by this mixer.
  public let preparation: AudioMixerRenderPreparation

  /// A matrix mixer has no algorithmic latency or tail.
  public let timing = AudioNodeTiming.transparent

  /// Atomically updateable gain and mute controls for every output channel.
  public let outputControls: AudioChannelGainControlBank

  private let compiledRoutes: [CompiledRoute]
  private let rampDurationFrames: Int
  private let mixStorage: UnsafeMutablePointer<Float>
  private let envelope: UnsafeMutablePointer<Float>
  private var rampStates: [AudioGainRampState]

  /// Prepares a matrix mixer and validates every route against its input and output bus.
  public init(
    preparation: AudioMixerRenderPreparation,
    routes: [AudioChannelRoute],
    outputControls: AudioChannelGainControlBank? = nil,
    rampDurationSeconds: Double = 0.005
  ) throws {
    guard rampDurationSeconds.isFinite, rampDurationSeconds >= 0 else {
      throw AudioDSPConfigurationError.invalidTiming
    }
    let controls =
      try outputControls
      ?? AudioChannelGainControlBank(channelCount: preparation.output.format.channelCount)
    guard controls.channelCount == preparation.output.format.channelCount else {
      throw AudioDSPConfigurationError.invalidChannelCount(controls.channelCount)
    }

    var inputChannelOffsets: [Int] = []
    inputChannelOffsets.reserveCapacity(preparation.inputFormats.count)
    var nextOffset = 0
    for format in preparation.inputFormats {
      inputChannelOffsets.append(nextOffset)
      nextOffset += format.channelCount
    }
    let compiledRoutes = try routes.map { route -> CompiledRoute in
      guard preparation.inputFormats.indices.contains(route.inputIndex),
        preparation.inputFormats[route.inputIndex].channelCount > route.sourceChannel,
        preparation.output.format.channelCount > route.destinationChannel
      else {
        throw AudioDSPConfigurationError.invalidChannelRoute
      }
      return CompiledRoute(
        flattenedSourceChannel: inputChannelOffsets[route.inputIndex] + route.sourceChannel,
        destinationChannel: route.destinationChannel,
        gain: route.gain
      )
    }
    let requestedRampFrames = rampDurationSeconds * preparation.output.format.sampleRate
    guard requestedRampFrames.isFinite, requestedRampFrames <= Double(Int.max) else {
      throw AudioDSPConfigurationError.invalidTiming
    }

    self.preparation = preparation
    self.outputControls = controls
    self.compiledRoutes = compiledRoutes
    rampDurationFrames = max(0, Int(requestedRampFrames.rounded()))
    let outputSampleCapacity =
      preparation.output.format.channelCount
      * preparation.output.maximumFrameCount
    mixStorage = .allocate(capacity: outputSampleCapacity)
    mixStorage.initialize(repeating: 0, count: outputSampleCapacity)
    envelope = .allocate(capacity: preparation.output.maximumFrameCount)
    envelope.initialize(repeating: 1, count: preparation.output.maximumFrameCount)
    rampStates = (0..<preparation.output.format.channelCount).map { _ in
      AudioGainRampState(gain: 1)
    }
  }

  deinit {
    let outputSampleCapacity =
      preparation.output.format.channelCount
      * preparation.output.maximumFrameCount
    mixStorage.deinitialize(count: outputSampleCapacity)
    mixStorage.deallocate()
    envelope.deinitialize(count: preparation.output.maximumFrameCount)
    envelope.deallocate()
  }

  /// Renders flattened input buses into caller-owned output channels.
  ///
  /// Inputs and outputs may alias because accumulation occurs in prepared internal storage. Output
  /// remains unclipped Float32; limiting and saturation belong to explicit downstream processors.
  @discardableResult
  public func process(
    inputChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    let outputPreparation = preparation.output
    guard (0...outputPreparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    let outputChannelCount = outputPreparation.format.channelCount
    guard inputChannels.count >= preparation.flattenedInputChannelCount,
      outputChannels.count >= outputChannelCount
    else {
      return .insufficientChannels
    }
    guard frameCount > 0 else { return .rendered }

    for destinationChannel in 0..<outputChannelCount {
      AudioMixerDSP.clear(
        mixStorage.advanced(by: destinationChannel * outputPreparation.maximumFrameCount),
        frameCount: frameCount
      )
    }
    for route in compiledRoutes {
      AudioMixerDSP.accumulate(
        input: inputChannels[route.flattenedSourceChannel],
        gain: route.gain,
        output: mixStorage.advanced(
          by: route.destinationChannel * outputPreparation.maximumFrameCount
        ),
        frameCount: frameCount
      )
    }
    for destinationChannel in 0..<outputChannelCount {
      let targetGain = outputControls.effectiveGain(at: destinationChannel)
      if targetGain != rampStates[destinationChannel].targetGain {
        rampStates[destinationChannel].setTarget(
          targetGain,
          durationFrames: rampDurationFrames
        )
      }
      rampStates[destinationChannel].writeEnvelope(to: envelope, frameCount: frameCount)
      AudioGainDSP.apply(
        input: UnsafePointer(
          mixStorage.advanced(by: destinationChannel * outputPreparation.maximumFrameCount)
        ),
        envelope: UnsafePointer(envelope),
        output: outputChannels[destinationChannel],
        frameCount: frameCount
      )
    }
    return .rendered
  }
}
