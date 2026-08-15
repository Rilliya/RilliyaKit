// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import RilliyaCore
import Testing

@testable import RilliyaDiscovery

@Suite("CoreAudioPropertyDataValidator")
struct CoreAudioPropertyDataValidatorTests {
  @Test("Returns only the object identifier prefix written by Core Audio")
  func returnsWrittenObjectIdentifierPrefix() throws {
    let ids = try CoreAudioPropertyDataValidator.objectIDs(
      from: [10, 20, 0],
      returnedByteCount: UInt32(2 * MemoryLayout<HardwareObjectID>.stride),
      objectKind: .system,
      property: .devices
    )

    #expect(ids == [10, 20])
  }

  @Test("Rejects a misaligned returned object identifier size")
  func rejectsMisalignedObjectIdentifierSize() {
    #expect(throws: AudioCatalogError.self) {
      try CoreAudioPropertyDataValidator.objectIDs(
        from: [10, 20],
        returnedByteCount: UInt32(MemoryLayout<HardwareObjectID>.stride + 1),
        objectKind: .system,
        property: .devices
      )
    }
  }

  @Test("Rejects an object identifier size larger than the allocation")
  func rejectsObjectIdentifierSizeLargerThanAllocation() {
    #expect(throws: AudioCatalogError.self) {
      try CoreAudioPropertyDataValidator.objectIDs(
        from: [10],
        returnedByteCount: UInt32(2 * MemoryLayout<HardwareObjectID>.stride),
        objectKind: .system,
        property: .devices
      )
    }
  }

  @Test("Accepts exactly one CFString reference")
  func acceptsCFStringReferenceSize() throws {
    try CoreAudioPropertyDataValidator.validateStringByteCount(
      UInt32(MemoryLayout<CFString?>.stride),
      objectKind: .device,
      property: .deviceName
    )
  }

  @Test("Rejects an unexpected CFString reference size")
  func rejectsUnexpectedCFStringReferenceSize() {
    #expect(throws: AudioCatalogError.self) {
      try CoreAudioPropertyDataValidator.validateStringByteCount(
        1,
        objectKind: .device,
        property: .deviceName
      )
    }
  }
}
