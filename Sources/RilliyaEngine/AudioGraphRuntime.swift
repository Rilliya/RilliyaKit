// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaGraph
import RilliyaRealtime

/// Configuration for preparing and driving one executable audio graph.
public struct AudioGraphEngineConfiguration: Hashable, Sendable {
  /// The standard bounded engine configuration.
  public static let standard = AudioGraphEngineConfiguration(
    validatedDefaultFormat: .stereo48kHz,
    renderQuantumFrameCount: 512,
    maximumScratchByteCount: 64 * 1_024 * 1_024,
    driver: .background
  )

  /// The format proposed to sources whose format is not externally determined.
  public let defaultFormat: AudioProcessingFormat

  /// The fixed frame count rendered by the background driver.
  public let renderQuantumFrameCount: Int

  /// The maximum planar scratch storage allocated while preparing the graph.
  public let maximumScratchByteCount: Int

  /// The execution driver used after the engine starts.
  public let driver: AudioGraphEngineDriver

  /// Creates checked engine configuration with practical defaults.
  public init(
    defaultFormat: AudioProcessingFormat,
    renderQuantumFrameCount: Int = 512,
    maximumScratchByteCount: Int = 64 * 1_024 * 1_024,
    driver: AudioGraphEngineDriver = .background
  ) throws {
    guard
      (1...AudioRenderPreparation.maximumSupportedFrameCount).contains(
        renderQuantumFrameCount
      )
    else {
      throw AudioGraphEngineConfigurationError.invalidRenderQuantumFrameCount(
        renderQuantumFrameCount
      )
    }
    guard (1...(1_024 * 1_024 * 1_024)).contains(maximumScratchByteCount) else {
      throw AudioGraphEngineConfigurationError.invalidScratchByteCount(maximumScratchByteCount)
    }
    self.defaultFormat = defaultFormat
    self.renderQuantumFrameCount = renderQuantumFrameCount
    self.maximumScratchByteCount = maximumScratchByteCount
    self.driver = driver
  }

  private init(
    validatedDefaultFormat defaultFormat: AudioProcessingFormat,
    renderQuantumFrameCount: Int,
    maximumScratchByteCount: Int,
    driver: AudioGraphEngineDriver
  ) {
    self.defaultFormat = defaultFormat
    self.renderQuantumFrameCount = renderQuantumFrameCount
    self.maximumScratchByteCount = maximumScratchByteCount
    self.driver = driver
  }
}

/// The execution clock used by an audio graph engine.
public enum AudioGraphEngineDriver: String, Hashable, Codable, Sendable {
  /// A bounded high-priority task drives analysis and other non-device graphs.
  case background

  /// The host explicitly calls `AudioGraphEngine.renderOnce()`.
  case manual
}

/// Invalid engine resource or scheduling configuration.
public enum AudioGraphEngineConfigurationError: Error, Equatable, LocalizedError, Sendable {
  /// The render quantum is outside the supported preparation bound.
  case invalidRenderQuantumFrameCount(Int)

  /// The scratch-memory budget is zero, negative, or unreasonably large.
  case invalidScratchByteCount(Int)

  /// A concise explanation of the invalid configuration.
  public var errorDescription: String? {
    switch self {
    case .invalidRenderQuantumFrameCount(let frameCount):
      "The engine render quantum must be between 1 and 65,536 frames; received \(frameCount)."
    case .invalidScratchByteCount(let byteCount):
      "The engine scratch-memory budget must be between 1 byte and 1 GiB; received \(byteCount)."
    }
  }
}

/// Resolved, immutable preparation information supplied to one executable node.
public struct AudioGraphNodePreparationContext: Sendable {
  /// The stable identity of the node being prepared.
  public let nodeID: AudioGraphNodeID

  /// The default format proposed to unconstrained source nodes.
  public let defaultFormat: AudioProcessingFormat

  /// The largest render quantum the prepared node may receive.
  public let maximumFrameCount: Int

  private let inputFormats: [AudioGraphPortID: [AudioProcessingFormat]]

  init(
    nodeID: AudioGraphNodeID,
    defaultFormat: AudioProcessingFormat,
    maximumFrameCount: Int,
    inputFormats: [AudioGraphPortID: [AudioProcessingFormat]]
  ) {
    self.nodeID = nodeID
    self.defaultFormat = defaultFormat
    self.maximumFrameCount = maximumFrameCount
    self.inputFormats = inputFormats
  }

  /// Returns every connected audio format feeding the named input port.
  public func audioInputFormats(for portID: AudioGraphPortID) -> [AudioProcessingFormat] {
    inputFormats[portID, default: []]
  }

  /// Returns the one connected format required by a single-source input.
  public func singleAudioInputFormat(
    for portID: AudioGraphPortID
  ) throws -> AudioProcessingFormat {
    let formats = audioInputFormats(for: portID)
    guard formats.count == 1, let format = formats.first else {
      throw AudioGraphNodePreparationContextError.expectedSingleAudioInput(
        portID,
        actualCount: formats.count
      )
    }
    return format
  }
}

/// Invalid assumptions made by a node while reading its preparation context.
public enum AudioGraphNodePreparationContextError: Error, Equatable, LocalizedError, Sendable {
  /// A node expected exactly one connected audio bus at the selected input.
  case expectedSingleAudioInput(AudioGraphPortID, actualCount: Int)

  /// A concise explanation of the invalid input topology.
  public var errorDescription: String? {
    switch self {
    case .expectedSingleAudioInput(let portID, let actualCount):
      "Audio input '\(portID.rawValue)' expected one source but received \(actualCount)."
    }
  }
}

/// A graph node that can prepare an executable runtime after upstream formats are known.
///
/// Preparation runs away from the graph render path and may perform asynchronous setup. The
/// returned runtime is then called serially by exactly one graph driver.
public protocol AudioGraphExecutableNode: AudioGraphNode {
  /// Creates bounded runtime state for this configured node value.
  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode
}

/// One read-only planar Float32 bus supplied to a prepared graph node.
public struct AudioGraphRenderInputBus: @unchecked Sendable {
  /// The immutable format of this bus.
  public let format: AudioProcessingFormat

  /// Channel pointers valid only for the current render call.
  public let channels: UnsafeBufferPointer<UnsafePointer<Float>>
}

/// One input port and every enabled upstream bus connected to it.
public struct AudioGraphRenderInputPort: @unchecked Sendable {
  /// The node-local semantic port identity.
  public let id: AudioGraphPortID

  /// Source buses in stable graph connection order.
  public let sources: UnsafeBufferPointer<AudioGraphRenderInputBus>
}

/// One caller-owned planar Float32 output bus.
public struct AudioGraphRenderOutputBus: @unchecked Sendable {
  /// The immutable format of this bus.
  public let format: AudioProcessingFormat

  /// Mutable channel pointers valid only for the current render call.
  public let channels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>
}

/// One output port and its prepared caller-owned bus.
public struct AudioGraphRenderOutputPort: @unchecked Sendable {
  /// The node-local semantic port identity.
  public let id: AudioGraphPortID

  /// The output bus that the node must fill completely.
  public let bus: AudioGraphRenderOutputBus
}

/// A bounded render quantum supplied to one prepared graph node.
public struct AudioGraphRenderContext: @unchecked Sendable {
  /// Connected audio inputs in the descriptor's stable port order.
  public let inputs: UnsafeBufferPointer<AudioGraphRenderInputPort>

  /// Prepared audio outputs in the descriptor's stable port order.
  public let outputs: UnsafeBufferPointer<AudioGraphRenderOutputPort>

  /// The number of frames to process in every bus.
  public let frameCount: Int

  /// Finds one input without allocating or building a dictionary on the render path.
  public func input(_ portID: AudioGraphPortID) -> AudioGraphRenderInputPort? {
    inputs.first { $0.id == portID }
  }

  /// Finds one output without allocating or building a dictionary on the render path.
  public func output(_ portID: AudioGraphPortID) -> AudioGraphRenderOutputPort? {
    outputs.first { $0.id == portID }
  }
}

/// Bounded runtime state for one prepared graph node.
///
/// `render(context:)` can run from a Core Audio callback in a future device-driven engine. It must
/// not allocate, block, log, invoke application callbacks, or perform unbounded work. Lifecycle
/// methods run away from that render path and may suspend.
public protocol PreparedAudioGraphNode: AnyObject, Sendable {
  /// Concrete formats produced by every prepared audio output.
  var outputFormats: [AudioGraphPortID: AudioProcessingFormat] { get }

  /// Latency and tail behavior used by graph scheduling and teardown.
  var timing: AudioNodeTiming { get }

  /// Starts external resources and non-render workers owned by this node.
  func start() async throws

  /// Renders one bounded quantum using only prepared storage.
  @discardableResult
  func render(context: AudioGraphRenderContext) -> AudioRenderResult

  /// Stops external resources, attempting complete cleanup before returning.
  func stop() async throws
}

extension PreparedAudioGraphNode {
  /// Default lifecycle for nodes without external resources.
  public func start() async throws {}

  /// Default lifecycle for nodes without external resources.
  public func stop() async throws {}
}

/// Adapts one existing prepared pull source into a single-output graph runtime.
public final class PreparedAudioSourceGraphNode: PreparedAudioGraphNode, @unchecked Sendable {
  /// The source called by this graph runtime.
  public let source: any PreparedAudioSource

  /// The semantic output receiving the rendered source.
  public let outputPortID: AudioGraphPortID

  /// The source's concrete output format.
  public let outputFormats: [AudioGraphPortID: AudioProcessingFormat]

  /// Latency and tail behavior inherited from the source.
  public var timing: AudioNodeTiming { source.timing }

  /// Creates a single-output runtime without adding another sample copy.
  public init(source: any PreparedAudioSource, outputPortID: AudioGraphPortID) {
    self.source = source
    self.outputPortID = outputPortID
    outputFormats = [outputPortID: source.preparation.format]
  }

  /// Pulls source samples directly into the graph-owned output bus.
  public func render(context: AudioGraphRenderContext) -> AudioRenderResult {
    guard let output = context.output(outputPortID) else {
      return .insufficientChannels
    }
    return source.render(
      outputChannels: output.bus.channels,
      frameCount: context.frameCount
    )
  }
}

/// Adapts one existing prepared single-bus processor into a graph runtime.
public final class PreparedAudioProcessorGraphNode: PreparedAudioGraphNode, @unchecked Sendable {
  /// The processor called by this graph runtime.
  public let processor: any PreparedAudioProcessor

  /// The semantic input read by the processor.
  public let inputPortID: AudioGraphPortID

  /// The semantic output filled by the processor.
  public let outputPortID: AudioGraphPortID

  /// The processor's concrete output format.
  public let outputFormats: [AudioGraphPortID: AudioProcessingFormat]

  /// Latency and tail behavior inherited from the processor.
  public var timing: AudioNodeTiming { processor.timing }

  /// Creates a single-input, single-output runtime without adding another sample copy.
  public init(
    processor: any PreparedAudioProcessor,
    inputPortID: AudioGraphPortID,
    outputPortID: AudioGraphPortID
  ) {
    self.processor = processor
    self.inputPortID = inputPortID
    self.outputPortID = outputPortID
    outputFormats = [outputPortID: processor.preparation.format]
  }

  /// Processes the one connected input directly into graph-owned output storage.
  public func render(context: AudioGraphRenderContext) -> AudioRenderResult {
    guard let input = context.input(inputPortID),
      input.sources.count == 1,
      let output = context.output(outputPortID),
      input.sources[0].format == processor.preparation.format,
      output.bus.format == processor.preparation.format
    else {
      return .insufficientChannels
    }
    return processor.process(
      inputChannels: input.sources[0].channels,
      outputChannels: output.bus.channels,
      frameCount: context.frameCount
    )
  }
}
