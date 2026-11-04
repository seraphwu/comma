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
    @State private var editing = EditingCell()
    @FocusState private var tableFocused: Bool

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

    /// Tab／Shift-Tab：移到下一格／上一格，行尾接下一列開頭；超出表格就結束編輯。
    private func tab(from id: CellID, by d: Int, proxy: ScrollViewProxy) {
        guard let n = CSV.step(id.r, id.c, by: d, rows: doc.rows.count, cols: cols) else {
            editing.id = nil
            return
        }
        selection = [n.r]
        editing.row = n.r
        editing.column = n.c
        editing.id = CellID(r: n.r, c: n.c)
        proxy.scrollTo(n.r)
    }

    var body: some View {
        ScrollViewReader { proxy in
        Table(doc.rows.indices.map(RowRef.init), selection: $selection) {
            TableColumn("#") { r in
                Text("\(r.id + 1)").foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 32, ideal: 40, max: 60)
            TableColumnForEach(0..<cols, id: \.self) { c in
                TableColumn(title(c)) { r in
                    HStack(alignment: .top, spacing: 4) {
                        let id = CellID(r: r.id, c: c)
                        CellView(text: cell(r.id, c), id: id, editing: editing,
                                 tab: { tab(from: id, by: $0, proxy: proxy) })
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
        .focused($tableFocused)
        // Table 內建：點兩下或按 Return 觸發 primaryAction。儲存格上不放手勢，否則單擊選不到列。
        .contextMenu(forSelectionType: Int.self, menu: { _ in }, primaryAction: { rows in
            guard rows.count == 1, let r = rows.first, r < doc.rows.count, cols > 0 else { return }
            // 按 Return 編輯「目前所在欄」；點兩下編輯滑鼠所在那一格
            if NSApp.currentEvent?.type != .keyDown, let h = editing.hover { editing.column = h }
            editing.id = CellID(r: r, c: min(editing.column, cols - 1))
        })
        .onChange(of: selection) {
            editing.row = selection.count == 1 ? selection.first : nil
            // 用滑鼠點選時，目前所在欄 = 點到的那一欄
            if let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .leftMouseUp, let h = editing.hover {
                editing.column = h
            }
        }
        .onChange(of: editing.id) { if editing.id == nil { tableFocused = true } }  // 結束編輯後回到表格，可再按 Enter
        }
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
                Button("新增欄", systemImage: "rectangle.split.3x1") { insertColumn(at: cols) }
                Button("刪除空白欄", systemImage: "rectangle.badge.minus") { editColumns { CSV.dropEmptyColumns($0) } }
                    .help("刪掉整欄都沒有內容的直欄")
                Toggle("Excel 相容（BOM）", isOn: $doc.bom)
                    .help("存檔時加上 UTF-8 BOM，Mac 版 Excel 開啟中文才不會亂碼")
                Button("檢閱器", systemImage: "sidebar.right") { showInspector.toggle() }
            }
        }
        .inspector(isPresented: $showInspector) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("直欄") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(0..<cols, id: \.self) { c in
                                HStack {
                                    Text(title(c)).lineLimit(1)
                                    Spacer()
                                    Button("在右邊插入一欄", systemImage: "plus.circle") { insertColumn(at: c + 1) }
                                    Button("刪除這一欄", systemImage: "minus.circle") {
                                        editColumns { CSV.deleteColumn($0, at: c) }
                                    }.disabled(cols <= 1)
                                }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }.padding(4)
                    }
                    if let r = selection.min(), r < doc.rows.count {
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
                    } else {
                        Text("選一列，就能在這裡編輯長留言或多行文字").foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .inspectorColumnWidth(min: 240, ideal: 300)
        }
    }

    /// 欄位變動一次寫回，讓 ⌘Z 一步就能復原。
    private func editColumns(_ f: ([[String]]) -> [[String]]) {
        editing.id = nil
        doc.rows = CSV.pad(f(doc.rows))
    }

    private func insertColumn(at c: Int) {
        editColumns { CSV.insertColumn($0, at: c) }
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

struct CellID: Hashable { let r: Int, c: Int }

/// 正在編輯的格子。用 @Observable 讓每格自己訂閱：Table 不會因 CSVView 的 @State 變動重畫儲存格。
@Observable final class EditingCell {
    var id: CellID?   // 正在編輯的格子
    var row: Int?     // 目前選取的列（只選一列時）
    var column = 0    // 目前所在欄：單擊設定，按 Enter 就編輯這欄
    var hover: Int?   // 滑鼠所在欄（用來判斷點到哪一格）
}

/// 平常顯示文字，點兩下才進入編輯；按 Return、Esc 或點別處就結束。
struct CellView: View {
    @Binding var text: String
    let id: CellID
    let editing: EditingCell
    let tab: (Int) -> Void
    @FocusState private var focused: Bool

    private func end() { if editing.id == id { editing.id = nil } }

    var body: some View {
        if editing.id == id {
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($focused)
                .onAppear {
                    DispatchQueue.main.async {
                        focused = true
                        // 預設會全選，一打字就蓋掉原文；改成游標放最後
                        DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
                    }
                }
                .onChange(of: focused) { if !focused { end() } }
                .onSubmit(end)
                .onExitCommand(perform: end)
                // Shift-Tab 在 macOS 送出的是 backtab（U+0019）
                .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
                    tab(press.key == .tab && !press.modifiers.contains(.shift) ? 1 : -1)
                    return .handled
                }
        } else {
            // 依內容長高，最多 4 行；更長的到右側檢閱器看全文
            Text(text.isEmpty ? " " : text)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .overlay {  // 標出「目前所在格」：按 Enter 會編輯這格
                    if editing.id == nil && editing.row == id.r && editing.column == id.c {
                        RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5).padding(-4)
                    }
                }
                .onContinuousHover { if case .active = $0, editing.hover != id.c { editing.hover = id.c } }
        }
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
