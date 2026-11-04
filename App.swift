import SwiftUI
import UniformTypeIdentifiers
import WebKit
import QuickLook

#if !HARNESS
@main
#endif
struct CommaApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: CSVDocument()) { CSVView(doc: $0.$document, fileURL: $0.fileURL) }
        DocumentGroup(newDocument: MarkdownDocument()) { MarkdownView(doc: $0.$document) }
            .commands { CommandGroup(after: .newItem) { NewMarkdownButton() } }
    }
}

struct NewMarkdownButton: View {
    @Environment(\.newDocument) private var newDocument
    var body: some View {
        Button("新增 Markdown") { newDocument(MarkdownDocument()) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
    }
}

// MARK: - Documents

// ponytail: 值型別文件，每次編輯會複製整張表；幾萬列以上再改 ReferenceFileDocument。
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText]
    var rows: [[String]] = Array(repeating: ["", "", ""], count: 5)
    var bom = true  // 新檔預設加 BOM，Mac 版 Excel 才不會亂碼
    var tab = false

    init() {}

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let (text, bom) = try CSV.decode(data)
        self.bom = bom
        tab = configuration.contentType == .tabSeparatedText || CSV.sniffDelimiter(text) == "\t"
        rows = CSV.parse(text, delimiter: tab ? "\t" : ",")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: CSV.encode(rows, delimiter: tab ? "\t" : ",", bom: bom))
    }
}

struct MarkdownDocument: FileDocument {
    static let readableContentTypes = [UTType(importedAs: "net.daringfireball.markdown")]
    var text = "# 新文件\n\n```mermaid\nflowchart LR\n  A[擷取留言] --> B[CSV] --> C[整理]\n```\n"

    init() {}

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = try CSV.decode(data).text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - CSV editor

struct RowRef: Identifiable { let id: Int }

struct CSVView: View {
    @Binding var doc: CSVDocument
    var fileURL: URL?
    @State private var selection = Set<Int>()
    @State private var showInspector = true
    @State private var images = ImageIndex()
    @State private var quickLook: URL?

    private func image(_ r: Int, _ c: Int) -> URL? { images.resolve(cell(r, c).wrappedValue) }

    private func open(_ url: URL) {
        if url.isFileURL { quickLook = url } else { NSWorkspace.shared.open(url) }
    }

    private var cols: Int { doc.rows.first?.count ?? 0 }

    /// 防呆 binding：刪列後 SwiftUI 可能還會讀到舊索引。
    private func cell(_ r: Int, _ c: Int) -> Binding<String> {
        Binding(
            get: { r < doc.rows.count && c < doc.rows[r].count ? doc.rows[r][c] : "" },
            set: { if r < doc.rows.count && c < doc.rows[r].count { doc.rows[r][c] = $0 } })
    }

    private func title(_ c: Int) -> String {
        let h = doc.rows.first?[c] ?? ""
        return h.isEmpty ? CSV.columnName(c) : "\(CSV.columnName(c)) · \(h)"
    }

    var body: some View {
        Table(doc.rows.indices.map(RowRef.init), selection: $selection) {
            TableColumn("#") { r in
                Text("\(r.id + 1)").foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 32, ideal: 40, max: 60)
            TableColumnForEach(0..<cols, id: \.self) { c in
                TableColumn(title(c)) { r in
                    HStack(alignment: .top, spacing: 4) {
                        // 依內容長高，最多 4 行；更長的到右側檢閱器看全文
                        TextField("", text: cell(r.id, c), axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...4)
                        if let url = image(r.id, c) {
                            Button("查看圖片", systemImage: "photo") { open(url) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).help(url.path)
                        }
                    }
                    .padding(.vertical, 6)
                }.width(min: 80, ideal: 220)
            }
        }
        .id(images.count)  // Table 不會因 images 變動重畫儲存格，索引載入後重建一次
        .quickLookPreview($quickLook)
        .task(id: fileURL) {
            let url = fileURL
            images = await Task.detached { ImageIndex(near: url) }.value
        }
        .toolbar {
            ToolbarItemGroup {
                Button("新增列", systemImage: "plus.rectangle") { addRow() }
                Button("刪除列", systemImage: "minus.rectangle") { deleteRows() }
                    .disabled(selection.isEmpty || doc.rows.count <= 1)
                Button("新增欄", systemImage: "rectangle.split.3x1") {
                    for i in doc.rows.indices { doc.rows[i].append("") }
                }
                Menu("刪除欄", systemImage: "rectangle.badge.minus") {
                    ForEach(0..<cols, id: \.self) { c in
                        Button(title(c)) { for i in doc.rows.indices { doc.rows[i].remove(at: c) } }
                    }
                }.disabled(cols <= 1)
                Toggle("Excel 相容（BOM）", isOn: $doc.bom)
                    .help("存檔時加上 UTF-8 BOM，Mac 版 Excel 開啟中文才不會亂碼")
                Button("檢閱器", systemImage: "sidebar.right") { showInspector.toggle() }
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let r = selection.min(), r < doc.rows.count {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("第 \(r + 1) 列").font(.headline)
                            ForEach(0..<cols, id: \.self) { c in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title(c)).font(.caption).foregroundStyle(.secondary)
                                    TextEditor(text: cell(r, c))
                                        .font(.body)
                                        .frame(height: 80)
                                        .scrollContentBackground(.hidden)
                                        .padding(4)
                                        .background(.background.secondary, in: .rect(cornerRadius: 6))
                                    if let url = image(r, c) {
                                        Button { open(url) } label: {
                                            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                                                .frame(maxWidth: .infinity, maxHeight: 220)
                                        }.buttonStyle(.plain).help("點一下放大")
                                    }
                                }
                            }
                        }.padding()
                    }
                } else {
                    ContentUnavailableView("選一列", systemImage: "text.cursor",
                                           description: Text("在這裡編輯長留言或多行文字"))
                }
            }
            .inspectorColumnWidth(min: 220, ideal: 300)
        }
    }

    private func addRow() {
        let at = (selection.max() ?? doc.rows.count - 1) + 1
        doc.rows.insert(Array(repeating: "", count: cols), at: at)
        selection = [at]
    }

    private func deleteRows() {
        let keep = doc.rows.indices.filter { !selection.contains($0) }
        selection = []
        doc.rows = CSV.pad(keep.map { doc.rows[$0] })
    }
}

// MARK: - Markdown editor + preview

struct MarkdownView: View {
    @Binding var doc: MarkdownDocument
    var body: some View {
        HSplitView {
            TextEditor(text: $doc.text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .frame(minWidth: 250)
            Preview(markdown: doc.text).frame(minWidth: 250)
        }
    }
}

struct Preview: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        let dir = Bundle.main.resourceURL!.appending(path: "web")
        web.loadFileURL(dir.appending(path: "index.html"), allowingReadAccessTo: dir)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.render(markdown, in: web)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded = false
        private var pending: String?

        func render(_ md: String, in web: WKWebView) {
            pending = md
            guard loaded, let json = try? JSONEncoder().encode(md), let arg = String(data: json, encoding: .utf8) else { return }
            web.evaluateJavaScript("render(\(arg))")
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let p = pending { render(p, in: web) }
        }

        // 連結一律用外部瀏覽器開，不讓預覽頁被導走
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated else { return decisionHandler(.allow) }
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
