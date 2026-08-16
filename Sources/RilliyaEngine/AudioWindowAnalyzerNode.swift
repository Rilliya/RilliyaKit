// SPDX-License-Identifier: Apache-2.0

import RilliyaGraph

/// A terminal graph node that delivers bounded audio windows to asynchronous application code.
///
/// The node has no output port. Its handler runs away from the audio render path, so it may
/// allocate, suspend, or invoke a model as long as it observes task cancellation during shutdown.
public struct AudioWindowAnalyzerNode: AudioGraphExecutableNode {
  /// Named ports exposed by an analyzer node handle.
  public struct Ports: AudioGraphNodePorts {
    /// The one audio bus analyzed by this node.
    public let input = AudioGraphPortID(rawValue: "input")

    /// Creates the stable analyzer port set.
    public init() {}
  }

  /// The stable public node identity.
  public static let typeID = AudioGraphNodeTypeID(
    rawValue: "moe.uwucocoa.rilliyakit.engine.audio-window-analyzer"
  )

  /// Stable named ports for typed graph handles.
  public static let ports = Ports()

  /// Bounded window, overlap, and backlog policy.
  public let configuration: AudioWindowSinkConfiguration

  private let handler: PreparedAudioWindowSink.Handler

  /// Creates a terminal analyzer with a standard 2,048-frame overlapping window.
  public init(
    configuration: AudioWindowSinkConfiguration = .standard,
    handler: @escaping PreparedAudioWindowSink.Handler
  ) {
    self.configuration = configuration
    self.handler = handler
  }

  /// Describes one single-source audio input and no output.
  public func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .input(
          Self.ports.input,
          signal: .audio(AudioGraphAudioSignalType())
        )
      ],
      activation: .sink
    )
  }

  /// Resolves the connected native format and prepares bounded asynchronous handoff storage.
  public func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    try PreparedAudioWindowSink(
      inputPortID: Self.ports.input,
      format: context.singleAudioInputFormat(for: Self.ports.input),
      configuration: configuration,
      handler: handler
    )
  }
}
