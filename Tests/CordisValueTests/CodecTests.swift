import CordisValue
import Testing

@Test func roundTripsEveryCase() {
  let v: Value = [
    "null": nil, "t": true, "f": false, "i": -42, "big": .int(Int64.max), "d": 3.5,
    "s": "héllo 🌈", "b": .bytes([0, 255, 7]), "arr": [1, "two", [3.0]], "empty": [:],
  ]
  #expect(Codec.decode(Codec.encode(v)) == v)
}

@Test func rejectsTruncatedAndTrailingBytes() {
  let bytes = Codec.encode(["k": "value"])
  #expect(Codec.decode(Array(bytes.dropLast())) == nil)
  #expect(Codec.decode(bytes + [0]) == nil)
  #expect(Codec.decode([99]) == nil)
}

@Test func subscriptsReadObjectsAndArrays() {
  let v: Value = ["id": "tabs", "inject": ["ui", "webviews"]]
  #expect(v["id"].string == "tabs")
  #expect(v["inject"][1].string == "webviews")
  #expect(v["missing"].isNull)
  #expect(v["inject"][9].isNull)
}
