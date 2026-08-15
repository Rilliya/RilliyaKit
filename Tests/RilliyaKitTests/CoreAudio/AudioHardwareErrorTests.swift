// SPDX-License-Identifier: Apache-2.0

import RilliyaKit
import Testing

@Suite("AudioHardwareError")
struct AudioHardwareErrorTests {
  @Test("Maps printable status values to four-character codes")
  func mapsFourCharacterCodes() {
    let status = AudioHardwareStatus(rawValue: Int32(bitPattern: 0x6261_646F))

    #expect(status.fourCharacterCode == "bado")
  }

  @Test("Leaves numeric status values numeric")
  func leavesNumericStatusValuesNumeric() {
    let status = AudioHardwareStatus(rawValue: -50)

    #expect(status.fourCharacterCode == nil)
  }

  @Test("Retains typed operation context")
  func retainsOperationContext() throws {
    let error = AudioHardwareError(
      objectKind: .device,
      property: .deviceStreams,
      operation: .readProperty,
      status: AudioHardwareStatus(rawValue: Int32(bitPattern: 0x6261_646F))
    )

    #expect(error.objectKind == .device)
    #expect(error.property == .deviceStreams)
    #expect(error.operation == .readProperty)
    #expect(error.status.fourCharacterCode == "bado")
    #expect(try #require(error.errorDescription).contains("OSStatus"))
  }
}
