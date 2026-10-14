import HostLab
import Testing

struct QEMUDiagnosticTests {
  @Test func completeTerminationLineAndActualWarnings() throws {
    let notice = "qemu-system-aarch64: terminating on signal 15 from pid 123 (/tool)\n"
    try QEMUDiagnostic.validate(notice, expectedWarningCount: 0, senderPID: 123)
    try QEMUDiagnostic.validate("", expectedWarningCount: 0, senderPID: nil)
    try QEMUDiagnostic.validate(
      QEMUDiagnostic.backingPageWarning + notice, expectedWarningCount: 1, senderPID: 123)
    for bad in [
      notice + "assertion failed\n", notice + "extra",
      notice.replacingOccurrences(of: "123", with: "124"), notice + notice,
    ] {
      #expect(throws: LabError.protocolViolation) {
        try QEMUDiagnostic.validate(bad, expectedWarningCount: 0, senderPID: 123)
      }
    }
    #expect(throws: LabError.protocolViolation) {
      try QEMUDiagnostic.validate("", expectedWarningCount: 1, senderPID: nil)
    }
    #expect(throws: LabError.protocolViolation) {
      try QEMUDiagnostic.validate(
        QEMUDiagnostic.backingPageWarning, expectedWarningCount: 0, senderPID: nil)
    }
  }
}
