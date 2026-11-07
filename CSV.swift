import Foundation

enum CSV {
    struct DecodeError: LocalizedError {
        var errorDescription: String? { "無法辨識檔案編碼（不是 UTF-8、UTF-16 或 Big5）" }
    }

    /// 回傳文字與是否帶 UTF-8 BOM。無法辨識就丟錯，避免亂碼被存回去。
    static func decode(_ data: Data) throws -> (text: String, bom: Bool) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let s = String(data: data.dropFirst(3), encoding: .utf8) else { throw DecodeError() }
            return (s, true)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) {
            return (s, false)
        }
        if let s = String(data: data, encoding: .utf8) { return (s, false) }
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
        if let s = String(data: data, encoding: big5) { return (s, false) }
        throw DecodeError()
    }

    /// 猜分隔符：第一行 tab 比逗號多就當 TSV。
    static func sniffDelimiter(_ text: String) -> Unicode.Scalar {
        let first = text.unicodeScalars.prefix { $0 != "\n" && $0 != "\r" }
        let tabs = first.filter { $0 == "\t" }.count
        let commas = first.filter { $0 == "," }.count
        return tabs > commas ? "\t" : ","
    }

    /// RFC 4180：支援引號內的分隔符、換行與 ""。用 unicodeScalars 是因為 Swift 把 \r\n 當成一個 Character。
    static func parse(_ text: String, delimiter d: Unicode.Scalar = ",") -> [[String]] {
        let a = Array(text.unicodeScalars)
        var rows: [[String]] = [], row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false, i = 0
        while i < a.count {
            let c = a[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < a.count, a[i + 1] == "\"" { field.append(c); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == d {
                row.append(String(field)); field = .init()
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < a.count, a[i + 1] == "\n" { i += 1 }
                row.append(String(field)); field = .init()
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(String(field)); rows.append(row) }
        return pad(rows)
    }

    /// 補齊成矩形，至少 1×1。
    static func pad(_ rows: [[String]]) -> [[String]] {
        let n = max(1, rows.map(\.count).max() ?? 0)
        let out = rows.map { $0 + Array(repeating: "", count: n - $0.count) }
        return out.isEmpty ? [[""]] : out
    }

    static func serialize(_ rows: [[String]], delimiter d: Unicode.Scalar = ",") -> String {
        rows.map { row in
            row.map { f in
                f.unicodeScalars.contains { $0 == d || $0 == "\"" || $0 == "\n" || $0 == "\r" }
                    ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    : f
            }.joined(separator: String(d))
        }.joined(separator: "\r\n") + "\r\n"
    }

    static func encode(_ rows: [[String]], delimiter: Unicode.Scalar, bom: Bool) -> Data {
        (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(serialize(rows, delimiter: delimiter).utf8)
    }

    /// A, B, …, Z, AA, AB…
    static func columnName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }
}

/// 儲存格寫明圖片路徑才顯示，不搜尋資料夾、不猜檔名：
/// 絕對路徑、~ 開頭，或相對於 CSV 所在資料夾的路徑（如 丹娜絲/D01.png、../丹娜絲/D01.png）；也接受 http(s) 圖片網址。
enum ImageRef {
    static let exts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp"]

    static func resolve(_ value: String, relativeTo csv: URL?) -> URL? {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 1024, !s.contains("\n") else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            guard let u = URL(string: s), exts.contains(u.pathExtension.lowercased()) else { return nil }
            return u
        }
        let path = (s as NSString).expandingTildeInPath
        let u: URL
        if path.hasPrefix("/") {
            u = URL(fileURLWithPath: path)
        } else {
            guard let dir = csv?.deletingLastPathComponent() else { return nil }
            u = dir.appendingPathComponent(path)
        }
        guard exts.contains(u.pathExtension.lowercased()), FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u.standardizedFileURL
    }

    /// 給 📷 提示用：從 CSV 所在資料夾到圖片的相對路徑（如 丹娜絲/D01.png、../丹娜絲/D01.png）；網址原樣顯示。
    static func relativePath(_ file: URL, from csv: URL?) -> String {
        guard file.isFileURL, let csv else { return file.isFileURL ? file.path : file.absoluteString }
        let dir = csv.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        let f = file.resolvingSymlinksInPath().pathComponents
        let common = zip(dir, f).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: dir.count - common) + f[common...]).joined(separator: "/")
    }
}

extension CSV {
    static func insertColumn(_ rows: [[String]], at c: Int) -> [[String]] {
        rows.map { var r = $0; r.insert("", at: min(c, r.count)); return r }
    }

    static func deleteColumn(_ rows: [[String]], at c: Int) -> [[String]] {
        pad(rows.map { var r = $0; if c < r.count { r.remove(at: c) }; return r })
    }

    /// 從 (r, c) 往後（d > 0）或往前移 d 格，行尾接下一列開頭；超出表格回傳 nil。
    static func step(_ r: Int, _ c: Int, by d: Int, rows: Int, cols: Int) -> (r: Int, c: Int)? {
        guard cols > 0 else { return nil }
        let i = r * cols + c + d
        guard i >= 0, i < rows * cols else { return nil }
        return (i / cols, i % cols)
    }

    /// 刪掉整欄都是空白的直欄。
    static func dropEmptyColumns(_ rows: [[String]]) -> [[String]] {
        let n = rows.first?.count ?? 0
        let keep = (0..<n).filter { c in rows.contains { !$0[c].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        return pad(rows.map { r in keep.map { r[$0] } })
    }
}

struct CellID: Hashable { let r: Int, c: Int }

// MARK: - 尋找取代
extension CSV {
    static func options(_ caseSensitive: Bool) -> String.CompareOptions { caseSensitive ? [] : [.caseInsensitive] }

    /// 含有 q 的格子，依列、欄順序。
    // ponytail: 每次重畫都全表掃描；幾萬格以上再快取結果。
    static func matches(_ rows: [[String]], _ q: String, caseSensitive cs: Bool) -> [CellID] {
        guard !q.isEmpty else { return [] }
        var out: [CellID] = []
        for (r, row) in rows.enumerated() {
            for (c, s) in row.enumerated() where s.range(of: q, options: options(cs)) != nil { out.append(CellID(r: r, c: c)) }
        }
        return out
    }

    /// 從 from 往後（d > 0）或往前找下一個符合的格子，到底繞回另一端。
    static func nextMatch(_ m: [CellID], after from: CellID?, by d: Int, cols: Int) -> CellID? {
        guard !m.isEmpty else { return nil }
        guard let f = from else { return d > 0 ? m.first : m.last }
        let key = { (x: CellID) in x.r * cols + x.c }
        return d > 0 ? (m.first { key($0) > key(f) } ?? m.first) : (m.last { key($0) < key(f) } ?? m.last)
    }

    /// 取代 s 裡所有的 q，回傳新字串與取代次數。
    static func replace(_ s: String, _ q: String, with rep: String, caseSensitive cs: Bool) -> (String, Int) {
        guard !q.isEmpty else { return (s, 0) }
        var out = "", rest = s[...], n = 0
        while let r = rest.range(of: q, options: options(cs)) {
            out += rest[..<r.lowerBound] + rep
            rest = rest[r.upperBound...]
            n += 1
        }
        return (out + rest, n)
    }

    static func replaceAll(_ rows: [[String]], _ q: String, with rep: String, caseSensitive cs: Bool) -> ([[String]], Int) {
        var total = 0
        let out = rows.map { $0.map { s in
            let (t, n) = replace(s, q, with: rep, caseSensitive: cs)
            total += n
            return t
        } }
        return (out, total)
    }
}
