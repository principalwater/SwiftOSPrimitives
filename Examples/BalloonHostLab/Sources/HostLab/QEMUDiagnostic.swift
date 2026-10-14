import Foundation

/// Pinned QEMU10.2 laboratory diagnostic contract, not a general stderr parser.
public enum QEMUDiagnostic {
  public static let backingPageWarning =
    "qemu-system-aarch64: warning: Balloon used with backing page size > 4kiB, this may not be reliable\n"

  public static func validate(_ text: String, expectedWarningCount: Int, senderPID: Int32?) throws {
    guard text.components(separatedBy: backingPageWarning).count - 1 == expectedWarningCount else {
      throw LabError.protocolViolation
    }
    let remainder = text.replacingOccurrences(of: backingPageWarning, with: "")
    guard let senderPID else {
      guard remainder.isEmpty else { throw LabError.protocolViolation }
      return
    }
    let prefix = "qemu-system-aarch64: terminating on signal 15 from pid \(senderPID) "
    guard remainder.hasPrefix(prefix) else { throw LabError.protocolViolation }
    let suffix = remainder.dropFirst(prefix.count)
    guard suffix.hasPrefix("("), suffix.hasSuffix(")\n"),
      !suffix.dropLast().contains("\n"), !suffix.contains("\r")
    else { throw LabError.protocolViolation }
  }
}
