import Testing

@testable import container_native_lab

@Test(arguments: [
  "CAPACITY_READY 3000 0", "CAPACITY_READY 2944 7999999999", "CAPACITY_READY 3072 17",
  "CAPACITY_READY 2943 0", "CAPACITY_READY 3073 0", "CAPACITY_READY 3000 8000000000",
  "CAPACITY_READY +3000 0", "CAPACITY_READY -3000 0", "CAPACITY_READY 3000 -1",
  "CAPACITY_READY 3000 18446744073709551616", "CAPACITY_READY 3000", "READY 3000 0",
  "CAPACITY_READY 3000 0 trailing",
  "CAPACITY_READY 3000 0\n", "CAPACITY_READY 2944 7999999999\n",
  "CAPACITY_READY 3072 17\n", "CAPACITY_READY  3000 0\n",
  "CAPACITY_READY 03000 0\n", "CAPACITY_READY 3000 00\n",
])
func startupCapacityReceiptRefusesPartialOrExpiredEvidence(_ line: String) {
  let receipt = CapacityLaunchReceipt(line: Substring(line), minimum: 2944, maximum: 3072)
  let valid = [
    "CAPACITY_READY 3000 0\n", "CAPACITY_READY 2944 7999999999\n", "CAPACITY_READY 3072 17\n",
  ].contains(line)
  #expect((receipt != nil) == valid)
}
