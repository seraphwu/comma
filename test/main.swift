import Foundation

// 引號、逗號、換行、"" 跳脫、CRLF、參差列
let src = "名字,留言,讚\r\n王小明,\"你好，\"\"世界\"\"\n第二行\",3\r\nAmy,ok\n"
let rows = CSV.parse(src)
assert(rows == [["名字", "留言", "讚"], ["王小明", "你好，\"世界\"\n第二行", "3"], ["Amy", "ok", ""]], "\(rows)")
assert(CSV.parse(CSV.serialize(rows)) == rows, "round trip")
assert(CSV.parse("") == [[""]])
assert(CSV.parse("5\" 螢幕,a") == [["5\" 螢幕", "a"]], "lenient mid-field quote")

// 編碼
let bomData = CSV.encode(rows, delimiter: ",", bom: true)
let (t1, b1) = try CSV.decode(bomData)
assert(b1 && CSV.parse(t1) == rows)
let big5 = "中文,測試".data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue))))!
let t2 = try CSV.decode(big5).text
assert(t2 == "中文,測試", t2)
let utf16 = "a\tb\n中\t文".data(using: .utf16)!
let (t3, _) = try CSV.decode(utf16)
assert(CSV.sniffDelimiter(t3) == "\t" && CSV.parse(t3, delimiter: "\t") == [["a", "b"], ["中", "文"]])

assert(CSV.columnName(0) == "A" && CSV.columnName(25) == "Z" && CSV.columnName(26) == "AA")
// 圖片對應：模擬 fb-zheng/out/丹娜絲.csv 找 fb-zheng/丹娜絲/D01.png
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("comma-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp.appendingPathComponent("丹娜絲"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: tmp.appendingPathComponent("out"), withIntermediateDirectories: true)
try Data().write(to: tmp.appendingPathComponent("丹娜絲/D01.png"))
let idx = ImageIndex(near: tmp.appendingPathComponent("out/丹娜絲.csv"))
for v in ["D01", "d01.png", "丹娜絲/D01.png", " D01 "] { assert(idx.resolve(v)?.lastPathComponent == "D01.png", v) }
assert(idx.resolve("D02") == nil && idx.resolve("應該說颱風生成的機會提升了吧！") == nil)
assert(idx.resolve("https://x.com/a.jpg") != nil && idx.resolve("https://x.com/a") == nil)
try FileManager.default.removeItem(at: tmp)
print("CSV self-test OK")
