// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import RilliyaGraph
import RilliyaRealtime

/// Bounded buffering and overlap policy for asynchronous audio-window analysis.
public struct AudioWindowSinkConfiguration: Hashable, Sendable {
  /// A practical 2,048-frame window with 50-percent overlap and bounded backlog.
  public static let standard = AudioWindowSinkConfiguration(
    validatedWindowFrameCount: 2_048,
    hopFrameCount: 1_024,
    bufferCapacityFrameCount: 8_192
  )

  /// Frames delivered in each owned analysis window.
  public let windowFrameCount: Int

  /// New frames consumed between consecutive windows.
  public let hopFrameCount: Int

  /// Frames retained between the graph render producer and analysis worker.
  public let bufferCapacityFrameCount: Int

  /// Creates checked window and backlog bounds.
  public init(
    windowFrameCount: Int = 2_048,
    hopFrameCount: Int = 1_024,
    bufferCapacityFrameCount: Int = 8_192
  ) throws {
    guard (1...AudioRenderPreparation.maximumSupportedFrameCount).contains(windowFrameCount) else {
      throw AudioWindowSinkConfigurationError.invalidWindowFrameCount(windowFrameCount)
    }
    guard (1...windowFrameCount).contains(hopFrameCount) else {
      throw AudioWindowSinkConfigurationError.invalidHopFrameCount(hopFrameCount)
    }
    guard bufferCapacityFrameCount >= max(windowFrameCount, 2),
      bufferCapacityFrameCount <= AudioRealtimeFrameBuffer.maximumCapacityFrameCount
    else {
      throw AudioWindowSinkConfigurationError.invalidBufferCapacity(bufferCapacityFrameCount)
    }
    self.init(
      validatedWindowFrameCount: windowFrameCount,
      hopFrameCount: hopFrameCount,
      bufferCapacityFrameCount: bufferCapacityFrameCount
    )
  }

  private init(
    validatedWindowFrameCount windowFrameCount: Int,
    hopFrameCount: Int,
    bufferCapacityFrameCount: Int
  ) {
    self.windowFrameCount = windowFrameCount
    self.hopFrameCount = hopFrameCount
    self.bufferCapacityFrameCount = bufferCapacityFrameCount
  }
}

/// Invalid asynchronous analysis-window bounds.
public enum AudioWindowSinkConfigurationError: Error, Equatable, LocalizedError, Sendable {
  /// The window length is zero or exceeds the supported render-storage bound.
  case invalidWindowFrameCount(Int)

  /// The hop is zero or larger than its window.
  case invalidHopFrameCount(Int)

  /// The realtime handoff cannot retain one complete window or exceeds its fixed bound.
  case invalidBufferCapacity(Int)

  /// The channel and window request exceeds the bounded analysis allocation.
  case excessiveWindowStorage(channelCount: Int, windowFrameCount: Int)

  /// A concise explanation of the invalid analysis configuration.
  public var errorDescription: String? {
    switch self {
    case .invalidWindowFrameCount(let frameCount):
      "An analysis window must contain between 1 and 65,536 frames; received \(frameCount)."
    case .invalidHopFrameCount(let frameCount):
      "An analysis hop must be positive and no larger than its window; received \(frameCount)."
    case .invalidBufferCapacity(let frameCount):
      "Analysis buffering must retain at least one window and no more than 65,536 frames; received \(frameCount)."
    case .excessiveWindowStorage(let channelCount, let windowFrameCount):
      "An analysis window for \(channelCount) channels and \(windowFrameCount) frames exceeds the bounded storage budget."
    }
  }
}

/// One owned noninterleaved Float32 window delivered away from the graph render path.
public struct AudioAnalysisWindow: Sendable {
  /// The concrete format of the samples.
  public let format: AudioProcessingFormat

  /// A monotonic zero-based window sequence.
  public let sequence: UInt64

  /// The first source-frame position represented by this window.
  public let startFrame: UInt64

  /// Frames stored for every channel.
  public let frameCount: Int

  private let planarStorage: [Float]

  init(
    format: AudioProcessingFormat,
    sequence: UInt64,
    startFrame: UInt64,
    frameCount: Int,
    planarStorage: [Float]
  ) {
    self.format = format
    self.sequence = sequence
    self.startFrame = startFrame
    self.frameCount = frameCount
    self.planarStorage = planarStorage
  }

  /// Returns one channel's contiguous samples, or an empty slice for an invalid channel index.
  public func samples(forChannel channel: Int) -> ArraySlice<Float> {
    guard (0..<format.channelCount).contains(channel) else { return [] }
    let start = channel * frameCount
    return planarStorage[start..<(start + frameCount)]
  }
}

/// A sink runtime that hands owned overlapping windows to asynchronous consumer code.
///
/// The graph render path only writes to a bounded single-producer/single-consumer frame buffer.
/// The supplied handler runs serially on a detached task and may load models, allocate, or suspend.
/// When analysis falls behind, new render frames are dropped rather than blocking audio work.
public final class PreparedAudioWindowSink: PreparedAudioGraphNode, @unchecked Sendable {
  /// The asynchronous consumer invoked serially for complete windows.
  public typealias Handler = @Sendable (AudioAnalysisWindow) async -> Void

  /// This terminal runtime produces no graph output.
  public let outputFormats: [AudioGraphPortID: AudioProcessingFormat] = [:]

  /// Window handoff adds no output latency or tail to the audio route.
  public let timing = AudioNodeTiming.transparent

  /// The semantic input read by this sink.
  public let inputPortID: AudioGraphPortID

  /// The concrete input format.
  public let format: AudioProcessingFormat

  /// The bounded analysis-window policy.
  public let configuration: AudioWindowSinkConfiguration

  private let frameBuffer: AudioRealtimeFrameBuffer
  private let handler: Handler
  private var worker: Task<Void, Never>?
  private var hasStopped = false

  /// Creates a terminal asynchronous analyzer runtime.
  public init(
    inputPortID: AudioGraphPortID,
    format: AudioProcessingFormat,
    configuration: AudioWindowSinkConfiguration = .standard,
    handler: @escaping Handler
  ) throws {
    let sampleCount = format.channelCount.multipliedReportingOverflow(
      by: configuration.windowFrameCount
    )
    guard !sampleCount.overflow,
      sampleCount.partialValue <= AudioRealtimeFrameBuffer.maximumSampleCapacity
    else {
      throw AudioWindowSinkConfigurationError.excessiveWindowStorage(
        channelCount: format.channelCount,
        windowFrameCount: configuration.windowFrameCount
      )
    }
    self.inputPortID = inputPortID
    self.format = format
    self.configuration = configuration
    self.handler = handler
    frameBuffer = try AudioRealtimeFrameBuffer(
      format: format,
      capacityFrameCount: configuration.bufferCapacityFrameCount
    )
  }

  deinit {
    worker?.cancel()
  }

  /// Starts one serial analysis worker.
  ///
  /// Repeated starts while active are idempotent.
  public func start() async throws {
    guard worker == nil, !hasStopped else { return }
    let frameBuffer = frameBuffer
    let format = format
    let configuration = configuration
    let handler = handler
    worker = Task.detached(priority: .userInitiated) {
      await Self.consume(
        frameBuffer: frameBuffer,
        format: format,
        configuration: configuration,
        handler: handler
      )
    }
  }

  /// Copies one input quantum into bounded SPSC storage without invoking the handler.
  public func render(context: AudioGraphRenderContext) -> AudioRenderResult {
    guard let input = context.input(inputPortID), input.sources.count == 1 else {
      return .insufficientChannels
    }
    let source = input.sources[0]
    guard source.format == format else { return .insufficientChannels }
    _ = frameBuffer.writePlanar(source.channels, frameCount: context.frameCount)
    return .rendered
  }

  /// Requests cancellation without allowing an uncooperative handler to block graph shutdown.
  ///
  /// The bounded worker retains at most one in-flight window while its trusted handler returns.
  /// Handlers should observe task cancellation before beginning additional expensive work.
  public func stop() async throws {
    hasStopped = true
    let task = worker
    worker = nil
    task?.cancel()
  }

  /// Returns lock-free producer/consumer statistics away from the render path.
  public func statistics() -> AudioRealtimeFrameBufferStatistics {
    frameBuffer.statistics()
  }

  private static func consume(
    frameBuffer: AudioRealtimeFrameBuffer,
    format: AudioProcessingFormat,
    configuration: AudioWindowSinkConfiguration,
    handler: @escaping Handler
  ) async {
    let storage = AudioWindowWorkerStorage(
      channelCount: format.channelCount,
      windowFrameCount: configuration.windowFrameCount,
      hopFrameCount: configuration.hopFrameCount
    )
    var hasWindow = false
    var sequence: UInt64 = 0
    var startFrame: UInt64 = 0
    while !Task.isCancelled {
      let requestedFrameCount =
        hasWindow
        ? configuration.hopFrameCount
        : configuration.windowFrameCount
      let available = frameBuffer.statistics().availableFrameCount
      guard available >= requestedFrameCount else {
        let missing = requestedFrameCount - available
        let waitSeconds = min(max(Double(missing) / format.sampleRate, 0.001), 0.01)
        try? await Task.sleep(for: .seconds(waitSeconds))
        continue
      }

      let result: AudioRealtimeFrameBufferReadResult
      if hasWindow {
        result = frameBuffer.read(
          into: storage.hopChannels,
          frameCount: configuration.hopFrameCount
        )
      } else {
        result = frameBuffer.read(
          into: storage.windowChannels,
          frameCount: configuration.windowFrameCount
        )
      }
      guard case .read(let copied, let silenced) = result,
        copied == requestedFrameCount,
        silenced == 0
      else { continue }

      if hasWindow {
        storage.advanceWindow()
        startFrame &+= UInt64(configuration.hopFrameCount)
      } else {
        hasWindow = true
      }
      let owned = storage.copyWindow()
      await handler(
        AudioAnalysisWindow(
          format: format,
          sequence: sequence,
          startFrame: startFrame,
          frameCount: configuration.windowFrameCount,
          planarStorage: owned
        )
      )
      sequence &+= 1
    }
  }
}

private final class AudioWindowWorkerStorage {
  let windowChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>
  let hopChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>

  private let channelCount: Int
  private let windowFrameCount: Int
  private let hopFrameCount: Int
  private let windowSamples: UnsafeMutablePointer<Float>
  private let hopSamples: UnsafeMutablePointer<Float>
  private let windowPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  private let hopPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

  init(channelCount: Int, windowFrameCount: Int, hopFrameCount: Int) {
    self.channelCount = channelCount
    self.windowFrameCount = windowFrameCount
    self.hopFrameCount = hopFrameCount
    windowSamples = .allocate(capacity: channelCount * windowFrameCount)
    windowSamples.initialize(repeating: 0, count: channelCount * windowFrameCount)
    hopSamples = .allocate(capacity: channelCount * hopFrameCount)
    hopSamples.initialize(repeating: 0, count: channelCount * hopFrameCount)
    windowPointers = .allocate(capacity: channelCount)
    hopPointers = .allocate(capacity: channelCount)
    for channel in 0..<channelCount {
      windowPointers.advanced(by: channel).initialize(
        to: windowSamples.advanced(by: channel * windowFrameCount)
      )
      hopPointers.advanced(by: channel).initialize(
        to: hopSamples.advanced(by: channel * hopFrameCount)
      )
    }
    windowChannels = UnsafeBufferPointer(start: windowPointers, count: channelCount)
    hopChannels = UnsafeBufferPointer(start: hopPointers, count: channelCount)
  }

  deinit {
    hopPointers.deinitialize(count: channelCount)
    hopPointers.deallocate()
    windowPointers.deinitialize(count: channelCount)
    windowPointers.deallocate()
    hopSamples.deinitialize(count: channelCount * hopFrameCount)
    hopSamples.deallocate()
    windowSamples.deinitialize(count: channelCount * windowFrameCount)
    windowSamples.deallocate()
  }

  func advanceWindow() {
    let retainedFrameCount = windowFrameCount - hopFrameCount
    for channel in 0..<channelCount {
      let window = windowPointers[channel]
      if retainedFrameCount > 0 {
        memmove(
          window,
          window.advanced(by: hopFrameCount),
          retainedFrameCount * MemoryLayout<Float>.stride
        )
      }
      window.advanced(by: retainedFrameCount).update(
        from: hopPointers[channel],
        count: hopFrameCount
      )
    }
  }

  func copyWindow() -> [Float] {
    Array(
      UnsafeBufferPointer(
        start: UnsafePointer(windowSamples),
        count: channelCount * windowFrameCount
      )
    )
  }
}
