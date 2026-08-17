#!/usr/bin/env python3
"""Reverts each fix in turn and records whether its test catches it.

A fix with no test that fails when it is reverted is a fix nothing is holding in place.
"""
import subprocess
import sys

ROOT = "/Users/cocoa/workspace/oss/RilliyaKit"

# name, file, (old -> new) revert, test filter
CASES = [
    (
        "heap overflow: forged datagram refused on the way in",
        "Sources/RilliyaNetworkAudio/NetworkAudioPacket.swift",
        (
            "    if fragment != nil, encoding == .interleavedFloat32 {\n"
            "      throw NetworkAudioPacketError.unsupportedFlags("
            "NetworkAudioPacketCodec.fragmentedFlag)\n    }\n",
            "",
        ),
        "forgedUncompressedFragmentIsRefused",
    ),
    (
        "heap overflow: fragment flag on uncompressed (build)",
        "Sources/RilliyaNetworkAudio/NetworkAudioPacket.swift",
        (
            "    if fragment != nil, encoding == .interleavedFloat32 {\n"
            "      throw NetworkAudioPacketError.unsupportedFlags("
            "NetworkAudioPacketCodec.fragmentedFlag)\n    }\n",
            "",
        ),
        "uncompressedFragmentIsRefused",
    ),
    (
        "encode drops the fragment and configuration",
        "Sources/RilliyaNetworkAudio/NetworkAudioPacket.swift",
        (
            "    data.appendInteger(packet.fragment == nil ? UInt16(0) : fragmentedFlag)",
            "    data.appendInteger(UInt16(0))",
        ),
        "packetRoundTripsWithEverythingItHolds",
    ),
    (
        "reassembler sequence underflow",
        "Sources/RilliyaNetworkAudio/NetworkAudioFragmentReassembler.swift",
        (
            "    guard sequence >= UInt64(fragment.index) else { return .tooLate }\n"
            "    let firstSequence = sequence - UInt64(fragment.index)",
            "    let firstSequence = sequence &- UInt64(fragment.index)",
        ),
        "underflowingPieceCannotWedgeReassembly",
    ),
    (
        "session identity minted per run",
        "Sources/RilliyaNetworkAudio/NetworkAudioSender.swift",
        (
            "    let runSessionID = UUID()\n    sessionID = runSessionID",
            "    let runSessionID = UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))\n"
            "    sessionID = runSessionID",
        ),
        "sendersFromOneConfigurationDiffer",
    ),
    (
        "history answers a sequence once",
        "Sources/RilliyaNetworkAudio/NetworkAudioSenderHistory.swift",
        (
            "    guard present[slot], sequences[slot] == sequence, !answered[slot] else "
            "{ return nil }",
            "    guard present[slot], sequences[slot] == sequence else { return nil }",
        ),
        "aSequenceIsAnsweredOnce",
    ),
    (
        "codec configuration on every piece",
        "Sources/RilliyaNetworkAudio/NetworkAudioSender.swift",
        (
            "        codecConfiguration: configurationBytes,",
            "        codecConfiguration: index == 0 ? configurationBytes : Data(),",
        ),
        "everyPieceCarriesTheConfiguration",
    ),
    (
        "undecodable block is counted",
        "Sources/RilliyaNetworkAudio/NetworkAudioReceiver.swift",
        (
            "      increment(\\Self.undecodablePacketCount)\n      return nil\n    }\n    guard\n"
            "      let frames = try? block.withUnsafeBytes({ bytes in",
            "      return nil\n    }\n    guard\n"
            "      let frames = try? block.withUnsafeBytes({ bytes in",
        ),
        "undecodableBlockIsCounted",
    ),
    (
        "a stopped receiver accepts nothing",
        "Sources/RilliyaNetworkAudio/NetworkAudioReceiver.swift",
        (
            "      guard case .running = state else { return false }\n"
            "      connections[ObjectIdentifier(connection)] = connection\n      return true",
            "      connections[ObjectIdentifier(connection)] = connection\n      return true",
        ),
        "connectionAfterStopIsRefused",
    ),
    (
        "a cancelled discovery releases its port",
        "Sources/RilliyaNetworkAudio/NetworkAudioFormatDiscovery.swift",
        (
            "        guard shouldListen else {\n          listener.cancel()\n          return\n        }",
            "        _ = shouldListen",
        ),
        "cancelledDiscoveryReleasesItsPort",
    ),
    (
        "worker reports a startup failure",
        "Sources/RilliyaRealtime/AudioRealtimeWorker.swift",
        (
            "      startupLock.withLock { startupError = error }",
            "      lock.withLock { startupError = error }",
        ),
        "startupFailureIsReportedRatherThanHung",
    ),
    (
        "a second stop waits",
        "Sources/RilliyaRealtime/AudioRealtimeWorker.swift",
        ("    stopLock.lock()\n    defer { stopLock.unlock() }\n", ""),
        "concurrentStopWaitsForTheThread",
    ),
    (
        "the realtime budget covers a split block",
        "Sources/RilliyaNetworkAudio/NetworkAudioSender.swift",
        (
            "    let wanted = Self.datagramBudget + Self.additionalDatagramBudget * (pieces - 1)",
            "    let wanted = Self.datagramBudget",
        ),
        "splitBlockDeclaresEveryPiece",
    ),
    (
        "blocks leave in the order they were sent",
        "Sources/RilliyaNetworkAudio/NetworkAudioFragmentReassembler.swift",
        ("    return released\n  }", "    return Array(released.reversed())\n  }"),
        "laterBlockWaits",
    ),
    (
        "the meter measures channels apart",
        "Sources/RilliyaRealtime/AudioWaveformMeter.swift",
        (
            "    let snapshots = zip(measurements, channelIDs).map { measurement, channelID in",
            "    let snapshots = zip(measurements.map { _ in measurements[0] }, channelIDs)\n"
            "      .map { measurement, channelID in",
        ),
        "channelsAreMeasuredApart",
    ),
]


import re


def run(filter_name):
    result = subprocess.run(
        ["swift", "test", "--filter", filter_name],
        cwd=ROOT, capture_output=True, text=True, timeout=900,
    )
    out = result.stdout + result.stderr
    # The Swift Testing summary is the only reliable evidence that anything executed; the XCTest
    # half of the same run always prints "Executed 0 tests" when a package has no XCTest cases.
    match = re.search(r"Test run with (\d+) test", out)
    executed = int(match.group(1)) if match else 0
    return result.returncode == 0, executed, out


print(f"{'fix':<52} {'baseline':<10} {'reverted':<10} verdict")
print("-" * 92)
caught = missed = broken = 0

for name, path, (old, new), test_filter in CASES:
    full = f"{ROOT}/{path}"
    original = open(full).read()

    baseline_ok, baseline_count, baseline_out = run(test_filter)
    if baseline_count == 0:
        print(f"{name:<52} {'NO TESTS':<10} {'-':<10} FILTER MATCHED NOTHING")
        broken += 1
        continue
    if not baseline_ok:
        print(f"{name:<52} {'FAIL':<10} {'-':<10} BASELINE ALREADY RED")
        broken += 1
        continue

    if old not in original:
        print(f"{name:<52} {'pass':<10} {'-':<10} REVERT PATTERN NOT FOUND")
        broken += 1
        continue

    open(full, "w").write(original.replace(old, new, 1))
    try:
        reverted_ok, reverted_count, reverted_out = run(test_filter)
    finally:
        open(full, "w").write(original)

    if reverted_count == 0:
        verdict = "DID NOT COMPILE"
        broken += 1
    elif reverted_ok:
        verdict = "*** NOT CAUGHT ***"
        missed += 1
    else:
        verdict = "caught"
        caught += 1
    state = "fail" if not reverted_ok else "pass"
    print(f"{name:<52} {f'pass({baseline_count})':<10} {state:<10} {verdict}")

print("-" * 92)
print(f"caught: {caught}   not caught: {missed}   inconclusive: {broken}")
sys.exit(0 if missed == 0 and broken == 0 else 1)
