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
assert(CSV.dropEmptyColumns([["a", "", "b", " "], ["c", "", "", ""]]) == [["a", "b"], ["c", ""]])
assert(CSV.dropEmptyColumns([["", ""]]) == [[""]])

let g = [["a", "b"], ["c", "d"]]
assert(CSV.insertColumn(g, at: 1) == [["a", "", "b"], ["c", "", "d"]])
assert(CSV.insertColumn(g, at: 2) == [["a", "b", ""], ["c", "d", ""]])
assert(CSV.deleteColumn(g, at: 0) == [["b"], ["d"]])
assert(CSV.deleteColumn([["a"], ["b"]], at: 0) == [[""], [""]])

assert(CSV.step(0, 0, by: 1, rows: 2, cols: 3)! == (0, 1))
assert(CSV.step(0, 2, by: 1, rows: 2, cols: 3)! == (1, 0))   // 行尾 Tab 跳下一列
assert(CSV.step(1, 0, by: -1, rows: 2, cols: 3)! == (0, 2))  // Shift-Tab 回上一列行尾
assert(CSV.step(1, 2, by: 1, rows: 2, cols: 3) == nil && CSV.step(0, 0, by: -1, rows: 2, cols: 3) == nil)

// 尋找取代
let fr = [["留言者", "留言內容"], ["王小明", "颱風好大，颱風快走"], ["Amy", "Typhoon"]]
assert(CSV.matches(fr, "颱風", caseSensitive: false) == [CellID(r: 1, c: 1)])
assert(CSV.matches(fr, "typhoon", caseSensitive: false) == [CellID(r: 2, c: 1)])
assert(CSV.matches(fr, "typhoon", caseSensitive: true).isEmpty && CSV.matches(fr, "", caseSensitive: false).isEmpty)
let fm = [CellID(r: 0, c: 1), CellID(r: 2, c: 0)]
assert(CSV.nextMatch(fm, after: nil, by: 1, cols: 2) == fm[0] && CSV.nextMatch(fm, after: nil, by: -1, cols: 2) == fm[1])
assert(CSV.nextMatch(fm, after: fm[0], by: 1, cols: 2) == fm[1] && CSV.nextMatch(fm, after: fm[1], by: 1, cols: 2) == fm[0])  // 繞回
assert(CSV.nextMatch(fm, after: fm[0], by: -1, cols: 2) == fm[1])
assert(CSV.replace("颱風好大，颱風快走", "颱風", with: "風", caseSensitive: false) == ("風好大，風快走", 2))
assert(CSV.replace("aAa", "a", with: "aa", caseSensitive: true) == ("aaAaa", 2))  // 取代內容含關鍵字也不會無限迴圈
let (fr2, frn) = CSV.replaceAll(fr, "typhoon", with: "颱風", caseSensitive: false)
assert(frn == 1 && fr2[2][1] == "颱風" && fr2[1] == fr[1])

// 圖片：只認明確路徑。模擬 fb-zheng/out/丹娜絲.csv 與 fb-zheng/丹娜絲/D01.png
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("comma-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp.appendingPathComponent("丹娜絲"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: tmp.appendingPathComponent("out"), withIntermediateDirectories: true)
let png = tmp.appendingPathComponent("丹娜絲/D01.png")
try Data().write(to: png)
let outCSV = tmp.appendingPathComponent("out/丹娜絲.csv")
let rootCSV = tmp.appendingPathComponent("貼文紀錄表.csv")
assert(ImageRef.resolve("丹娜絲/D01.png", relativeTo: rootCSV)?.path == png.standardizedFileURL.path)
assert(ImageRef.resolve(" ../丹娜絲/D01.png ", relativeTo: outCSV)?.path == png.standardizedFileURL.path)
assert(ImageRef.resolve(png.path, relativeTo: nil) != nil)  // 絕對路徑不需 CSV 位置
for v in ["D01", "D01.png", "丹娜絲/D01", "丹娜絲/D02.png", "應該說颱風生成的機會提升了吧！"] {
    assert(ImageRef.resolve(v, relativeTo: rootCSV) == nil, v)  // 不猜檔名、不搜尋資料夾
}
assert(ImageRef.resolve("丹娜絲/D01.png", relativeTo: nil) == nil)  // 未存檔的新文件沒有相對基準
assert(ImageRef.resolve("https://x.com/a.jpg", relativeTo: nil) != nil && ImageRef.resolve("https://x.com/a", relativeTo: nil) == nil)
assert(ImageRef.relativePath(png, from: rootCSV) == "丹娜絲/D01.png")
assert(ImageRef.relativePath(png, from: outCSV) == "../丹娜絲/D01.png")
assert(ImageRef.relativePath(URL(string: "https://x.com/a.jpg")!, from: rootCSV) == "https://x.com/a.jpg")
try FileManager.default.removeItem(at: tmp)
print("CSV self-test OK")
