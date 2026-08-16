import Testing

@testable import RilliyaRealtime

@Suite("Realtime audio frame distributor")
struct AudioRealtimeFrameDistributorTests {
  @Test
  func subscribersReadTheSameSourceIndependently() throws {
    let distributor = try makeDistributor(capacityFrameCount: 8, subscriberCount: 2)
    let first = try distributor.subscribe()
    let second = try distributor.subscribe()
    let input: [Float] = [0.25, 0.5, 0.75, 1]

    let distribution = try write(input, to: distributor)
    let firstOutput = try read(first, frameCount: 4)
    let secondOutput = try read(second, frameCount: 4)

    #expect(distribution.activeSubscriberCount == 2)
    #expect(distribution.minimumWrittenFrameCount == 4)
    #expect(distribution.maximumWrittenFrameCount == 4)
    #expect(firstOutput == input)
    #expect(secondOutput == input)
  }

  @Test
  func aSlowSubscriberDoesNotMoveAnotherSubscribersCursor() throws {
    let distributor = try makeDistributor(capacityFrameCount: 4, subscriberCount: 2)
    let fast = try distributor.subscribe()
    let slow = try distributor.subscribe()

    try write([1, 2, 3, 4], to: distributor)
    #expect(try read(fast, frameCount: 4) == [1, 2, 3, 4])
    let distribution = try write([5, 6, 7, 8], to: distributor)

    #expect(distribution.minimumWrittenFrameCount == 0)
    #expect(distribution.maximumWrittenFrameCount == 4)
    #expect(try read(fast, frameCount: 4) == [5, 6, 7, 8])
    #expect(try read(slow, frameCount: 4) == [1, 2, 3, 4])
    #expect(slow.statistics().frameBuffer.droppedFrameCount == 4)
  }

  @Test
  func cancellationInvalidatesAStaleSubscriptionBeforeSlotReuse() throws {
    let distributor = try makeDistributor(capacityFrameCount: 4, subscriberCount: 1)
    let stale = try distributor.subscribe()
    try write([1, 2], to: distributor)
    stale.cancel()
    let replacement = try distributor.subscribe()
    try write([3, 4], to: distributor)

    var staleOutput = [Float](repeating: -1, count: 2)
    let staleResult = try staleOutput.withUnsafeMutableBufferPointer { output in
      let baseAddress = try #require(output.baseAddress)
      let channels = [baseAddress]
      return channels.withUnsafeBufferPointer {
        stale.read(into: $0, frameCount: output.count)
      }
    }

    #expect(staleResult == .inactive)
    #expect(staleOutput == [-1, -1])
    #expect(try read(replacement, frameCount: 2) == [3, 4])
  }

  @Test
  func preparedInactiveSourceRendersSilence() throws {
    let distributor = try makeDistributor(capacityFrameCount: 4, subscriberCount: 1)
    let subscription = try distributor.subscribe()
    let source = try PreparedAudioFrameSubscriptionSource(
      subscription: subscription,
      maximumFrameCount: 4
    )
    subscription.cancel()
    var output = [Float](repeating: 1, count: 4)

    let result = try output.withUnsafeMutableBufferPointer { output in
      let baseAddress = try #require(output.baseAddress)
      let channels = [baseAddress]
      return channels.withUnsafeBufferPointer {
        source.render(outputChannels: $0, frameCount: output.count)
      }
    }

    #expect(result == .rendered)
    #expect(output == [0, 0, 0, 0])
  }

  @Test
  func subscriberAndAggregateStorageBoundsAreEnforced() throws {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 256)

    #expect(throws: AudioRealtimeFrameDistributorError.invalidSubscriberCount(0)) {
      try AudioRealtimeFrameDistributor(format: format, maximumSubscriberCount: 0)
    }
    #expect(
      throws: AudioRealtimeFrameDistributorError.excessiveStorage(
        channelCount: 256,
        capacityFrameCount: 65_536,
        maximumSubscriberCount: 2
      )
    ) {
      try AudioRealtimeFrameDistributor(
        format: format,
        capacityFrameCount: 65_536,
        maximumSubscriberCount: 2
      )
    }

    let distributor = try makeDistributor(capacityFrameCount: 4, subscriberCount: 1)
    let activeSubscription = try distributor.subscribe()
    #expect(throws: AudioRealtimeFrameDistributorError.subscriberLimitReached(1)) {
      try distributor.subscribe()
    }
    #expect(activeSubscription.statistics().isActive)
  }

  private func makeDistributor(
    capacityFrameCount: Int,
    subscriberCount: Int
  ) throws -> AudioRealtimeFrameDistributor {
    try AudioRealtimeFrameDistributor(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 1),
      capacityFrameCount: capacityFrameCount,
      maximumSubscriberCount: subscriberCount
    )
  }

  @discardableResult
  private func write(
    _ samples: [Float],
    to distributor: AudioRealtimeFrameDistributor
  ) throws -> AudioRealtimeFrameDistributionResult {
    try samples.withUnsafeBufferPointer { input in
      let baseAddress = try #require(input.baseAddress)
      let channels = [baseAddress]
      return channels.withUnsafeBufferPointer {
        distributor.writePlanar($0, frameCount: input.count)
      }
    }
  }

  private func read(
    _ subscription: AudioRealtimeFrameSubscription,
    frameCount: Int
  ) throws -> [Float] {
    var output = [Float](repeating: -1, count: frameCount)
    let result = try output.withUnsafeMutableBufferPointer { output in
      let baseAddress = try #require(output.baseAddress)
      let channels = [baseAddress]
      return channels.withUnsafeBufferPointer {
        subscription.read(into: $0, frameCount: frameCount)
      }
    }
    guard case .read = result else { return [] }
    return output
  }
}
