/// Bounded HTTP/1.0 connection-close response subset for the private lab endpoint.
public enum LabHTTPResponse {
  public enum Failure: Error, Equatable {
    case framing
    case loadResponse(String)
  }

  public static func body(_ response: [UInt8]) throws(Failure) -> String {
    guard response.count < 4096, response.count >= 4,
      let boundary = (0...(response.count - 4)).first(where: {
        response[$0..<($0 + 4)].elementsEqual([13, 10, 13, 10])
      }) else { throw Failure.framing }
    let lines = response[..<boundary].split(separator: 10)
    guard let first = lines.first else { throw Failure.framing }
    let status = String(decoding: first.last == 13 ? first.dropLast() : first, as: UTF8.self)
    guard status.utf8.allSatisfy({ (32...126).contains($0) }) else { throw Failure.framing }
    let bodyBytes = response[(boundary + 4)...]
    let body = String(decoding: bodyBytes, as: UTF8.self)
    guard status.hasPrefix("HTTP/1.0 200 ") || status.hasPrefix("HTTP/1.1 200 ") else {
      throw Failure.loadResponse(String(status.prefix(64)) + " " + String(reflecting: body.prefix(512)))
    }
    var declaredLength: Int?
    var exception = body.hasPrefix("Code:")
    for rawLine in lines.dropFirst() {
      let line = rawLine.last == 13 ? rawLine.dropLast() : rawLine
      guard line.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
        let colon = line.firstIndex(of: 58) else { throw Failure.framing }
      let name = line[..<colon]
      guard !name.isEmpty, name.allSatisfy({
        switch $0 {
        case 48...57, 65...90, 97...122, 33, 35...39, 42, 43, 45, 46, 94...96, 124, 126: true
        default: false
        }
      }) else { throw Failure.framing }
      var value = line[line.index(after: colon)...]
      while value.first == 32 || value.first == 9 { value = value.dropFirst() }
      while value.last == 32 || value.last == 9 { value = value.dropLast() }
      switch String(decoding: name, as: UTF8.self).lowercased() {
      case "content-length":
        guard declaredLength == nil, !value.isEmpty,
          value.allSatisfy({ (48...57).contains($0) }),
          let length = Int(String(decoding: value, as: UTF8.self)), length == bodyBytes.count
        else { throw Failure.framing }
        declaredLength = length
      case "transfer-encoding": throw Failure.framing
      case "x-clickhouse-exception-code": exception = true
      default: break
      }
    }
    guard !exception else { throw Failure.loadResponse(String(reflecting: body.prefix(512))) }
    return body
  }
}
