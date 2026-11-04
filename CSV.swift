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

/// 把儲存格文字（D01、D01.png、丹娜絲/D01.png、絕對路徑、http 圖片網址）對應到圖片檔。
struct ImageIndex {
    static let exts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp"]
    private var byName: [String: URL] = [:]
    var count: Int { byName.count }

    init() {}

    /// ponytail: 只掃 CSV 所在資料夾與上一層、往下 3 層、最多 20000 個檔案；圖放更遠再加「指定圖片資料夾」。
    init(near file: URL?) {
        guard let dir = file?.deletingLastPathComponent() else { return }
        var seen = 0
        for root in [dir, dir.deletingLastPathComponent()] {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                seen += 1
                if seen > 20000 { return }
                guard Self.exts.contains(url.pathExtension.lowercased()) else { continue }
                for key in [url.lastPathComponent, url.deletingPathExtension().lastPathComponent] {
                    let k = key.lowercased()
                    if byName[k] == nil { byName[k] = url }  // 先掃到的（較近的）優先
                }
            }
        }
    }

    func resolve(_ value: String) -> URL? {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 300, !s.contains("\n") else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            guard let u = URL(string: s), Self.exts.contains(u.pathExtension.lowercased()) else { return nil }
            return u
        }
        if s.hasPrefix("/") || s.hasPrefix("~") {
            let u = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
            return Self.exts.contains(u.pathExtension.lowercased()) && FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        return byName[s.lowercased()] ?? byName[(s as NSString).lastPathComponent.lowercased()]
    }
}
