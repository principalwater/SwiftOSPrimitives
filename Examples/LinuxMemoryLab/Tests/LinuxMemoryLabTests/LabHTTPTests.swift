import LabHTTP
import Testing

@Test func labHTTPRejectsTruncatedContentLength() {
  let response = Array("HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nabc".utf8)
  #expect(throws: LabHTTPResponse.Failure.framing) { try LabHTTPResponse.body(response) }
}

@Test(arguments: [
  "Content-Length: 3\r\nContent-Length: 3", "Content-Length: +3", "Content-Length: -1",
  "Content-Length: 2", "Content-Length: ", "Content-Length: 3x", "Content-Length : 3",
  "Transfer-Encoding: chunked", "X: a\rY: b",
]) func labHTTPRejectsAmbiguousOrMalformedHeaders(_ headers: String) {
  let response = Array(("HTTP/1.0 200 OK\r\n" + headers + "\r\n\r\nabc").utf8)
  #expect(throws: LabHTTPResponse.Failure.framing) { try LabHTTPResponse.body(response) }
}

@Test(arguments: ["Content-Length: 2", "content-length:\t2\t", "X-Lab: close-only"])
func labHTTPPreservesCompleteNumericResults(_ headers: String) throws {
  let response = Array(("HTTP/1.0 200 OK\r\n" + headers + "\r\n\r\n1\n").utf8)
  #expect(try LabHTTPResponse.body(response) == "1\n")
}

@Test func labHTTPRejectsIncompleteHeadersAndResponseCap() {
  for response in [
    Array("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n".utf8),
    Array("HTTP/1.0 200 OK\u{0}\r\n\r\nabc".utf8), [UInt8](repeating: 65, count: 4096),
  ] {
    #expect(throws: LabHTTPResponse.Failure.framing) { try LabHTTPResponse.body(response) }
  }
}

@Test func labHTTPPreservesSQLFailureBeyondLongHeaders() {
  let response = Array(("HTTP/1.0 500 Internal Server Error\r\nX-Lab: "
    + String(repeating: "a", count: 700) + "\r\n\r\nCode: 395. controlled failure\n").utf8)
  #expect(throws: LabHTTPResponse.Failure.loadResponse(
    "HTTP/1.0 500 Internal Server Error \"Code: 395. controlled failure\\n\"")) {
      try LabHTTPResponse.body(response)
  }
}
