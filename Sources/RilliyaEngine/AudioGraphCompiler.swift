// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaGraph
import RilliyaRealtime

/// A failure while validating, preparing, starting, or rendering an executable graph.
public enum AudioGraphEngineError: AudioGraphContextualError, LocalizedError, @unchecked Sendable {
  /// No node is a terminal sink, so none of the graph has observable work.
  case noActiveSink

  /// An active node supplies semantics but no executable runtime factory.
  case nodeIsNotExecutable(AudioGraphNodeID, AudioGraphNodeTypeID)

  /// The first runtime release supports audio connections but not control/event execution.
  case unsupportedSignalConnection(
    AudioGraphConnectionID,
    source: AudioGraphPortAddress,
    target: AudioGraphPortAddress
  )

  /// Runtime scheduling does not yet support an executable feedback loop.
  case unsupportedFeedbackCycle(
    nodeIDs: [AudioGraphNodeID],
    connectionIDs: [AudioGraphConnectionID]
  )

  /// A runtime did not publish a concrete format for one connected output.
  case missingOutputFormat(AudioGraphPortAddress)

  /// A runtime published an output that is absent or incompatible with its descriptor.
  case invalidOutputFormat(AudioGraphPortAddress, actual: AudioProcessingFormat)

  /// Two prepared ports require incompatible concrete audio formats.
  case incompatiblePreparedFormats(
    AudioGraphConnectionID,
    source: AudioGraphPortAddress,
    target: AudioGraphPortAddress,
    sourceFormat: AudioProcessingFormat,
    targetConstraint: AudioGraphAudioSignalType
  )

  /// A background-driven graph resolved more than one sample clock.
  case incompatibleDriverSampleRates([Double])

  /// Active output buffers would exceed the configured scratch-memory budget.
  case scratchMemoryLimitExceeded(requiredByteCount: Int, limit: Int)

  /// A node failed during preparation, startup, or cleanup while retaining its typed error.
  case nodeFailure(AudioGraphNodeFailure)

  /// A prepared node rejected one render quantum.
  case nodeRenderFailed(AudioGraphNodeID, AudioGraphNodeTypeID, AudioRenderResult)

  /// A manual render was requested from a background-driven engine.
  case manualRenderUnavailable

  /// A stopped engine is intentionally terminal.
  case alreadyStopped

  /// A concise explanation of the engine failure.
  public var errorDescription: String? {
    switch self {
    case .noActiveSink:
      "The graph has no active sink. Connect a terminal analyzer or destination before preparing it."
    case .nodeIsNotExecutable(_, let typeID):
      "Active node '\(typeID.rawValue)' does not provide an executable runtime."
    case .unsupportedSignalConnection(let connectionID, _, _):
      "Connection \(connectionID.rawValue.uuidString) carries a signal this engine release does not execute."
    case .unsupportedFeedbackCycle(let nodeIDs, _):
      "Executable feedback scheduling is not available for the \(nodeIDs.count) involved nodes."
    case .missingOutputFormat(let address):
      "The runtime did not prepare audio output '\(address.portID.rawValue)'."
    case .invalidOutputFormat(let address, let actual):
      "The runtime prepared invalid format \(actual.channelCount) ch at \(actual.sampleRate) Hz for output '\(address.portID.rawValue)'."
    case .incompatiblePreparedFormats(_, _, _, let sourceFormat, let targetConstraint):
      "Prepared source format \(sourceFormat.channelCount) ch at \(sourceFormat.sampleRate) Hz does not satisfy target constraint \(targetConstraint). Insert an explicit converter."
    case .incompatibleDriverSampleRates(let sampleRates):
      "A background-driven graph resolved multiple sample rates \(sampleRates). Insert explicit sample-rate conversion."
    case .scratchMemoryLimitExceeded(let requiredByteCount, let limit):
      "The graph requires at least \(requiredByteCount) bytes of scratch storage, exceeding its \(limit)-byte limit."
    case .nodeFailure(let failure):
      failure.errorDescription
    case .nodeRenderFailed(_, let typeID, let result):
      "Node '\(typeID.rawValue)' rejected a render quantum: \(result)."
    case .manualRenderUnavailable:
      "Only a manually driven engine accepts renderOnce()."
    case .alreadyStopped:
      "A stopped audio graph engine cannot be restarted."
    }
  }

  /// A practical next step suitable for developer tools and workflow UI.
  public var recoverySuggestion: String? {
    switch self {
    case .noActiveSink:
      "Connect the graph to a terminal analyzer, playback destination, or another sink."
    case .nodeIsNotExecutable:
      "Remove the node from the active path or provide an AudioGraphExecutableNode implementation."
    case .unsupportedSignalConnection:
      "Keep this connection semantic-only or use a runtime that executes its signal family."
    case .unsupportedFeedbackCycle:
      "Break the runtime cycle with an executable stateful delay node."
    case .missingOutputFormat, .invalidOutputFormat:
      "Correct the node runtime so every connected audio output publishes a valid declared format."
    case .incompatiblePreparedFormats:
      "Insert an explicit channel or sample-rate converter between these ports."
    case .incompatibleDriverSampleRates:
      "Insert explicit sample-rate conversion so the driven graph uses one sample clock."
    case .scratchMemoryLimitExceeded:
      "Reduce the active graph or raise maximumScratchByteCount after reviewing its memory budget."
    case .nodeFailure:
      "Inspect underlyingError for the node package's typed recovery information."
    case .nodeRenderFailed:
      "Stop and prepare a new engine after correcting the node's realtime render implementation."
    case .manualRenderUnavailable:
      "Prepare the graph with the manual driver before calling renderOnce()."
    case .alreadyStopped:
      "Prepare a new engine instance before starting the graph again."
    }
  }

  /// Node instances directly implicated by this failure.
  public var nodeIDs: [AudioGraphNodeID] {
    switch self {
    case .nodeIsNotExecutable(let nodeID, _), .nodeRenderFailed(let nodeID, _, _):
      [nodeID]
    case .unsupportedSignalConnection(_, let source, let target):
      source.nodeID == target.nodeID ? [source.nodeID] : [source.nodeID, target.nodeID]
    case .unsupportedFeedbackCycle(let nodeIDs, _):
      nodeIDs
    case .incompatiblePreparedFormats(_, let source, let target, _, _):
      source.nodeID == target.nodeID ? [source.nodeID] : [source.nodeID, target.nodeID]
    case .missingOutputFormat(let address), .invalidOutputFormat(let address, _):
      [address.nodeID]
    case .nodeFailure(let failure):
      [failure.nodeID]
    default:
      []
    }
  }

  /// Connections directly implicated by this failure.
  public var connectionIDs: [AudioGraphConnectionID] {
    switch self {
    case .unsupportedSignalConnection(let connectionID, _, _),
      .incompatiblePreparedFormats(let connectionID, _, _, _, _):
      [connectionID]
    case .unsupportedFeedbackCycle(_, let connectionIDs):
      connectionIDs
    default:
      []
    }
  }

  /// Port addresses directly implicated by this failure.
  public var portAddresses: [AudioGraphPortAddress] {
    switch self {
    case .unsupportedSignalConnection(_, let source, let target):
      [source, target]
    case .incompatiblePreparedFormats(_, let source, let target, _, _):
      [source, target]
    case .missingOutputFormat(let address), .invalidOutputFormat(let address, _):
      [address]
    default:
      []
    }
  }

  /// The original concrete node-package error when one exists.
  public var underlyingError: (any Error)? {
    guard case .nodeFailure(let failure) = self else { return nil }
    return failure.underlyingError
  }
}

/// The lifecycle stage at which an executable node reported a typed failure.
public enum AudioGraphNodeFailureStage: String, Hashable, Codable, Sendable {
  /// Resolving formats or allocating bounded runtime state.
  case preparation

  /// Starting an external resource or worker.
  case start

  /// Stopping external resources and workers.
  case stop
}

/// Context around a node-owned error without erasing its concrete error value.
public struct AudioGraphNodeFailure: Error, LocalizedError, @unchecked Sendable {
  /// The stable instance that reported the failure.
  public let nodeID: AudioGraphNodeID

  /// The node package's stable type identity.
  public let nodeTypeID: AudioGraphNodeTypeID

  /// The lifecycle stage that failed.
  public let stage: AudioGraphNodeFailureStage

  /// The original error, available for typed downcasting by the host.
  public let underlyingError: any Error

  /// Creates failure context while retaining the original typed error.
  public init(
    nodeID: AudioGraphNodeID,
    nodeTypeID: AudioGraphNodeTypeID,
    stage: AudioGraphNodeFailureStage,
    underlyingError: any Error
  ) {
    self.nodeID = nodeID
    self.nodeTypeID = nodeTypeID
    self.stage = stage
    self.underlyingError = underlyingError
  }

  /// A concise description that includes the node and original failure.
  public var errorDescription: String? {
    "Node '\(nodeTypeID.rawValue)' failed during \(stage.rawValue): \(underlyingError.localizedDescription)"
  }
}

final class PreparedAudioGraphPlan: @unchecked Sendable {
  let operations: [PreparedAudioGraphOperation]
  let renderQuantumFrameCount: Int
  let driverSampleRate: Double

  private var startedOperationIndices: [Int] = []

  init(
    operations: [PreparedAudioGraphOperation],
    renderQuantumFrameCount: Int,
    driverSampleRate: Double
  ) {
    self.operations = operations
    self.renderQuantumFrameCount = renderQuantumFrameCount
    self.driverSampleRate = driverSampleRate
  }

  func start() async throws {
    startedOperationIndices.reserveCapacity(operations.count)
    for index in operations.indices.reversed() {
      let operation = operations[index]
      do {
        try await operation.runtime.start()
        startedOperationIndices.append(index)
      } catch {
        await stopStartedOperations()
        throw AudioGraphEngineError.nodeFailure(
          AudioGraphNodeFailure(
            nodeID: operation.nodeID,
            nodeTypeID: operation.nodeTypeID,
            stage: .start,
            underlyingError: error
          )
        )
      }
    }
  }

  func render(frameCount: Int) -> AudioGraphEngineError? {
    for operation in operations {
      operation.clearOutputs(frameCount: frameCount)
      let result = operation.render(frameCount: frameCount)
      guard result == .rendered else {
        return .nodeRenderFailed(operation.nodeID, operation.nodeTypeID, result)
      }
    }
    return nil
  }

  func stop() async throws {
    var firstFailure: AudioGraphEngineError?
    while let index = startedOperationIndices.popLast() {
      let operation = operations[index]
      do {
        try await operation.runtime.stop()
      } catch  where firstFailure == nil {
        firstFailure = .nodeFailure(
          AudioGraphNodeFailure(
            nodeID: operation.nodeID,
            nodeTypeID: operation.nodeTypeID,
            stage: .stop,
            underlyingError: error
          )
        )
      } catch {
        continue
      }
    }
    if let firstFailure { throw firstFailure }
  }

  private func stopStartedOperations() async {
    while let index = startedOperationIndices.popLast() {
      try? await operations[index].runtime.stop()
    }
  }
}

final class PreparedAudioGraphOperation: @unchecked Sendable {
  let nodeID: AudioGraphNodeID
  let nodeTypeID: AudioGraphNodeTypeID
  let runtime: any PreparedAudioGraphNode

  private let inputPorts: UnsafeMutablePointer<AudioGraphRenderInputPort>?
  private let inputPortCount: Int
  private let inputBusAllocations: [UnsafeMutablePointer<AudioGraphRenderInputBus>?]
  private let inputBusCounts: [Int]
  private let outputPorts: UnsafeMutablePointer<AudioGraphRenderOutputPort>?
  private let outputPortCount: Int
  private let outputBuffers: [AudioGraphPlanarBuffer]

  init(
    nodeID: AudioGraphNodeID,
    nodeTypeID: AudioGraphNodeTypeID,
    runtime: any PreparedAudioGraphNode,
    inputDescriptors: [(AudioGraphPortID, [AudioGraphPlanarBuffer])],
    outputDescriptors: [(AudioGraphPortID, AudioGraphPlanarBuffer)]
  ) {
    self.nodeID = nodeID
    self.nodeTypeID = nodeTypeID
    self.runtime = runtime
    inputPortCount = inputDescriptors.count
    outputPortCount = outputDescriptors.count
    outputBuffers = outputDescriptors.map(\.1)

    var busAllocations: [UnsafeMutablePointer<AudioGraphRenderInputBus>?] = []
    var busCounts: [Int] = []
    busAllocations.reserveCapacity(inputDescriptors.count)
    busCounts.reserveCapacity(inputDescriptors.count)
    if inputDescriptors.isEmpty {
      inputPorts = nil
    } else {
      let ports = UnsafeMutablePointer<AudioGraphRenderInputPort>.allocate(
        capacity: inputDescriptors.count
      )
      for (index, descriptor) in inputDescriptors.enumerated() {
        let buses: UnsafeMutablePointer<AudioGraphRenderInputBus>?
        if descriptor.1.isEmpty {
          buses = nil
        } else {
          let allocation = UnsafeMutablePointer<AudioGraphRenderInputBus>.allocate(
            capacity: descriptor.1.count
          )
          for (sourceIndex, buffer) in descriptor.1.enumerated() {
            allocation.advanced(by: sourceIndex).initialize(to: buffer.inputBus)
          }
          buses = allocation
        }
        busAllocations.append(buses)
        busCounts.append(descriptor.1.count)
        ports.advanced(by: index).initialize(
          to: AudioGraphRenderInputPort(
            id: descriptor.0,
            sources: UnsafeBufferPointer(start: buses, count: descriptor.1.count)
          )
        )
      }
      inputPorts = ports
    }
    inputBusAllocations = busAllocations
    inputBusCounts = busCounts

    if outputDescriptors.isEmpty {
      outputPorts = nil
    } else {
      let ports = UnsafeMutablePointer<AudioGraphRenderOutputPort>.allocate(
        capacity: outputDescriptors.count
      )
      for (index, descriptor) in outputDescriptors.enumerated() {
        ports.advanced(by: index).initialize(
          to: AudioGraphRenderOutputPort(id: descriptor.0, bus: descriptor.1.outputBus)
        )
      }
      outputPorts = ports
    }
  }

  deinit {
    if let inputPorts {
      inputPorts.deinitialize(count: inputPortCount)
      inputPorts.deallocate()
    }
    for (index, allocation) in inputBusAllocations.enumerated() {
      guard let allocation else { continue }
      allocation.deinitialize(count: inputBusCounts[index])
      allocation.deallocate()
    }
    if let outputPorts {
      outputPorts.deinitialize(count: outputPortCount)
      outputPorts.deallocate()
    }
  }

  func clearOutputs(frameCount: Int) {
    for buffer in outputBuffers {
      buffer.clear(frameCount: frameCount)
    }
  }

  func render(frameCount: Int) -> AudioRenderResult {
    runtime.render(
      context: AudioGraphRenderContext(
        inputs: UnsafeBufferPointer(start: inputPorts, count: inputPortCount),
        outputs: UnsafeBufferPointer(start: outputPorts, count: outputPortCount),
        frameCount: frameCount
      )
    )
  }
}

final class AudioGraphPlanarBuffer: @unchecked Sendable {
  let format: AudioProcessingFormat
  let maximumFrameCount: Int

  private let samples: UnsafeMutablePointer<Float>
  private let mutableChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  private let inputChannels: UnsafeMutablePointer<UnsafePointer<Float>>

  var inputBus: AudioGraphRenderInputBus {
    AudioGraphRenderInputBus(
      format: format,
      channels: UnsafeBufferPointer(start: inputChannels, count: format.channelCount)
    )
  }

  var outputBus: AudioGraphRenderOutputBus {
    AudioGraphRenderOutputBus(
      format: format,
      channels: UnsafeBufferPointer(start: mutableChannels, count: format.channelCount)
    )
  }

  init(format: AudioProcessingFormat, maximumFrameCount: Int) {
    self.format = format
    self.maximumFrameCount = maximumFrameCount
    let sampleCount = format.channelCount * maximumFrameCount
    samples = .allocate(capacity: sampleCount)
    samples.initialize(repeating: 0, count: sampleCount)
    mutableChannels = .allocate(capacity: format.channelCount)
    inputChannels = .allocate(capacity: format.channelCount)
    for channel in 0..<format.channelCount {
      let address = samples.advanced(by: channel * maximumFrameCount)
      mutableChannels.advanced(by: channel).initialize(to: address)
      inputChannels.advanced(by: channel).initialize(to: UnsafePointer(address))
    }
  }

  deinit {
    let sampleCount = format.channelCount * maximumFrameCount
    inputChannels.deinitialize(count: format.channelCount)
    inputChannels.deallocate()
    mutableChannels.deinitialize(count: format.channelCount)
    mutableChannels.deallocate()
    samples.deinitialize(count: sampleCount)
    samples.deallocate()
  }

  func clear(frameCount: Int) {
    guard frameCount > 0 else { return }
    for channel in 0..<format.channelCount {
      mutableChannels[channel].update(repeating: 0, count: frameCount)
    }
  }
}

enum AudioGraphCompiler {
  static func prepare(
    snapshot: AudioGraphSnapshot,
    configuration: AudioGraphEngineConfiguration
  ) async throws -> PreparedAudioGraphPlan {
    let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
    let enabledConnections = snapshot.connections.filter(\.isEnabled)
    let activeNodeIDs = activeNodes(
      nodes: snapshot.nodes,
      connections: enabledConnections
    )
    guard !activeNodeIDs.isEmpty else {
      throw AudioGraphEngineError.noActiveSink
    }

    let activeConnections = enabledConnections.filter {
      activeNodeIDs.contains($0.source.nodeID) && activeNodeIDs.contains($0.target.nodeID)
    }
    for connection in activeConnections {
      guard
        let source = nodesByID[connection.source.nodeID]?.port(connection.source.portID),
        let target = nodesByID[connection.target.nodeID]?.port(connection.target.portID),
        case .audio = source.signalType,
        case .audio = target.signalType
      else {
        throw AudioGraphEngineError.unsupportedSignalConnection(
          connection.id,
          source: connection.source,
          target: connection.target
        )
      }
    }

    let orderedNodeIDs = try topologicalOrder(
      nodes: snapshot.nodes,
      activeNodeIDs: activeNodeIDs,
      connections: activeConnections
    )
    let incomingByNode = Dictionary(grouping: activeConnections, by: { $0.target.nodeID })
    let outgoingByAddress = Dictionary(grouping: activeConnections, by: { $0.source })
    var outputBuffers: [AudioGraphPortAddress: AudioGraphPlanarBuffer] = [:]
    var operations: [PreparedAudioGraphOperation] = []
    operations.reserveCapacity(orderedNodeIDs.count)
    var allocatedByteCount = 0

    for nodeID in orderedNodeIDs {
      guard let instance = nodesByID[nodeID] else { continue }
      guard let executable = instance.value as? any AudioGraphExecutableNode else {
        throw AudioGraphEngineError.nodeIsNotExecutable(nodeID, instance.typeID)
      }
      let incoming = incomingByNode[nodeID, default: []]
      var inputFormats: [AudioGraphPortID: [AudioProcessingFormat]] = [:]
      for descriptor in instance.descriptor.ports
      where descriptor.direction == .input {
        guard case .audio(let constraint) = descriptor.signalType else { continue }
        let connections = incoming.filter { $0.target.portID == descriptor.id }
        let formats = try connections.map { connection in
          guard let buffer = outputBuffers[connection.source] else {
            throw AudioGraphEngineError.missingOutputFormat(connection.source)
          }
          guard constraint.accepts(buffer.format) else {
            throw AudioGraphEngineError.incompatiblePreparedFormats(
              connection.id,
              source: connection.source,
              target: connection.target,
              sourceFormat: buffer.format,
              targetConstraint: constraint
            )
          }
          return buffer.format
        }
        inputFormats[descriptor.id] = formats
      }

      let context = AudioGraphNodePreparationContext(
        nodeID: nodeID,
        defaultFormat: configuration.defaultFormat,
        maximumFrameCount: configuration.renderQuantumFrameCount,
        inputFormats: inputFormats
      )
      let runtime: any PreparedAudioGraphNode
      do {
        runtime = try await executable.prepare(context: context)
      } catch {
        throw AudioGraphEngineError.nodeFailure(
          AudioGraphNodeFailure(
            nodeID: nodeID,
            nodeTypeID: instance.typeID,
            stage: .preparation,
            underlyingError: error
          )
        )
      }

      var localOutputDescriptors: [(AudioGraphPortID, AudioGraphPlanarBuffer)] = []
      for (portID, format) in runtime.outputFormats {
        let address = AudioGraphPortAddress(nodeID: nodeID, portID: portID)
        guard let descriptor = instance.port(portID),
          descriptor.direction == .output,
          case .audio(let constraint) = descriptor.signalType,
          constraint.accepts(format)
        else {
          throw AudioGraphEngineError.invalidOutputFormat(address, actual: format)
        }
        guard
          let requiredBytes = scratchByteCount(
            format: format,
            maximumFrameCount: configuration.renderQuantumFrameCount
          )
        else {
          throw AudioGraphEngineError.scratchMemoryLimitExceeded(
            requiredByteCount: Int.max,
            limit: configuration.maximumScratchByteCount
          )
        }
        let addition = allocatedByteCount.addingReportingOverflow(requiredBytes)
        guard !addition.overflow,
          addition.partialValue <= configuration.maximumScratchByteCount
        else {
          throw AudioGraphEngineError.scratchMemoryLimitExceeded(
            requiredByteCount: addition.overflow ? Int.max : addition.partialValue,
            limit: configuration.maximumScratchByteCount
          )
        }
        allocatedByteCount = addition.partialValue
        let buffer = AudioGraphPlanarBuffer(
          format: format,
          maximumFrameCount: configuration.renderQuantumFrameCount
        )
        outputBuffers[address] = buffer
        localOutputDescriptors.append((portID, buffer))
      }
      for descriptor in instance.descriptor.ports
      where descriptor.direction == .output {
        let address = AudioGraphPortAddress(nodeID: nodeID, portID: descriptor.id)
        if outgoingByAddress[address, default: []].isEmpty { continue }
        guard outputBuffers[address] != nil else {
          throw AudioGraphEngineError.missingOutputFormat(address)
        }
      }

      let localInputs: [(AudioGraphPortID, [AudioGraphPlanarBuffer])] = instance.descriptor.ports
        .filter { $0.direction == .input && $0.signalType.isAudio }
        .map { descriptor in
          let buffers = incoming.filter { $0.target.portID == descriptor.id }.compactMap {
            outputBuffers[$0.source]
          }
          return (descriptor.id, buffers)
        }
      let outputOrder = Dictionary(
        uniqueKeysWithValues: instance.descriptor.ports.enumerated().map {
          ($0.element.id, $0.offset)
        }
      )
      localOutputDescriptors.sort {
        outputOrder[$0.0, default: Int.max] < outputOrder[$1.0, default: Int.max]
      }
      operations.append(
        PreparedAudioGraphOperation(
          nodeID: nodeID,
          nodeTypeID: instance.typeID,
          runtime: runtime,
          inputDescriptors: localInputs,
          outputDescriptors: localOutputDescriptors
        )
      )
    }

    let sampleRates = Set(outputBuffers.values.map { $0.format.sampleRate })
    guard configuration.driver == .manual || sampleRates.count <= 1 else {
      throw AudioGraphEngineError.incompatibleDriverSampleRates(sampleRates.sorted())
    }
    return PreparedAudioGraphPlan(
      operations: operations,
      renderQuantumFrameCount: configuration.renderQuantumFrameCount,
      driverSampleRate: sampleRates.first ?? configuration.defaultFormat.sampleRate
    )
  }

  private static func activeNodes(
    nodes: [AudioGraphNodeInstance],
    connections: [AudioGraphConnection]
  ) -> Set<AudioGraphNodeID> {
    let roots = nodes.filter { node in
      node.descriptor.activation == .sink
        || !node.descriptor.ports.contains(where: { $0.direction == .output })
    }.map(\.id)
    guard !roots.isEmpty else { return [] }
    let incomingByNode = Dictionary(grouping: connections, by: { $0.target.nodeID })
    var active = Set(roots)
    var stack = roots
    while let nodeID = stack.popLast() {
      for connection in incomingByNode[nodeID, default: []]
      where active.insert(connection.source.nodeID).inserted {
        stack.append(connection.source.nodeID)
      }
    }
    return active
  }

  private static func topologicalOrder(
    nodes: [AudioGraphNodeInstance],
    activeNodeIDs: Set<AudioGraphNodeID>,
    connections: [AudioGraphConnection]
  ) throws -> [AudioGraphNodeID] {
    let stableNodeIDs = nodes.map(\.id).filter(activeNodeIDs.contains)
    var indegree = Dictionary(uniqueKeysWithValues: stableNodeIDs.map { ($0, 0) })
    var outgoing: [AudioGraphNodeID: [AudioGraphNodeID]] = [:]
    for connection in connections {
      indegree[connection.target.nodeID, default: 0] += 1
      outgoing[connection.source.nodeID, default: []].append(connection.target.nodeID)
    }
    var queue = stableNodeIDs.filter { indegree[$0] == 0 }
    var readIndex = 0
    var result: [AudioGraphNodeID] = []
    result.reserveCapacity(stableNodeIDs.count)
    while readIndex < queue.count {
      let nodeID = queue[readIndex]
      readIndex += 1
      result.append(nodeID)
      for target in outgoing[nodeID, default: []] {
        indegree[target, default: 0] -= 1
        if indegree[target] == 0 {
          queue.append(target)
        }
      }
    }
    guard result.count == stableNodeIDs.count else {
      let involvedNodeIDs = stableNodeIDs.filter { indegree[$0, default: 0] > 0 }.sorted {
        $0.rawValue.uuidString < $1.rawValue.uuidString
      }
      let involvedNodeIDSet = Set(involvedNodeIDs)
      let involvedConnectionIDs = connections.compactMap {
        involvedNodeIDSet.contains($0.source.nodeID)
          && involvedNodeIDSet.contains($0.target.nodeID)
          ? $0.id : nil
      }.sorted {
        $0.rawValue.uuidString < $1.rawValue.uuidString
      }
      throw AudioGraphEngineError.unsupportedFeedbackCycle(
        nodeIDs: involvedNodeIDs,
        connectionIDs: involvedConnectionIDs
      )
    }
    return result
  }

  private static func scratchByteCount(
    format: AudioProcessingFormat,
    maximumFrameCount: Int
  ) -> Int? {
    let channelFrames = format.channelCount.multipliedReportingOverflow(by: maximumFrameCount)
    guard !channelFrames.overflow else { return nil }
    let bytes = channelFrames.partialValue.multipliedReportingOverflow(
      by: MemoryLayout<Float>.stride
    )
    guard !bytes.overflow else { return nil }
    return bytes.partialValue
  }
}

extension AudioGraphAudioSignalType {
  fileprivate func accepts(_ format: AudioProcessingFormat) -> Bool {
    let acceptsChannels: Bool
    switch channelCount {
    case .any:
      acceptsChannels = true
    case .fixed(let required):
      acceptsChannels = required == format.channelCount
    }
    let acceptsSampleRate: Bool
    switch sampleRate {
    case .any:
      acceptsSampleRate = true
    case .fixed(let required):
      acceptsSampleRate = required == format.sampleRate
    }
    return acceptsChannels && acceptsSampleRate
  }
}

extension AudioGraphSignalType {
  fileprivate var isAudio: Bool {
    if case .audio = self { return true }
    return false
  }
}
