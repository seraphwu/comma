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
            .commands {
                CommandGroup(after: .newItem) { NewMarkdownButton() }
                FindCommands()
            }
    }
}

// MARK: - 尋找（⌘F）

struct FindActionKey: FocusedValueKey { typealias Value = (NSTextFinder.Action) -> Void }
extension FocusedValues {
    var findAction: FindActionKey.Value? {
        get { self[FindActionKey.self] }
        set { self[FindActionKey.self] = newValue }
    }
}

/// 編輯選單的尋找項目：CSV 視窗交給表格上方的尋找列，Markdown 交給 NSTextView 原生尋找列。
struct FindCommands: Commands {
    @FocusedValue(\.findAction) private var findAction

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("尋找…") { run(.showFindInterface) }.keyboardShortcut("f")
            Button("尋找與取代…") { run(.showReplaceInterface) }.keyboardShortcut("f", modifiers: [.command, .option])
            Button("找下一個") { run(.nextMatch) }.keyboardShortcut("g")
            Button("找上一個") { run(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }

    private func run(_ a: NSTextFinder.Action) {
        if let findAction { return findAction(a) }
        let item = NSMenuItem()
        item.tag = a.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
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
    @State private var quickLook: URL?
    @State private var editing = EditingCell()
    @State private var find = FindState()
    @FocusState private var tableFocused: Bool
    @FocusState private var findFocused: Bool

    private func image(_ r: Int, _ c: Int) -> URL? { ImageRef.resolve(cell(r, c).wrappedValue, relativeTo: fileURL) }

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

    // MARK: 尋找取代

    private func findAction(_ a: NSTextFinder.Action, proxy: ScrollViewProxy) {
        switch a {
        case .showFindInterface, .showReplaceInterface:
            find.visible = true
            find.showReplace = find.showReplace || a == .showReplaceInterface
            findFocused = true
        case .nextMatch: findStep(1, proxy: proxy)
        case .previousMatch: findStep(-1, proxy: proxy)
        default: break
        }
    }

    private var findMatches: [CellID] { CSV.matches(doc.rows, find.query, caseSensitive: find.caseSensitive) }

    private var findStatus: String {
        if !find.message.isEmpty { return find.message }
        if find.query.isEmpty { return "" }
        let m = findMatches
        if m.isEmpty { return "找不到" }
        if let cur = find.current, let i = m.firstIndex(of: cur) { return "\(i + 1) / \(m.count)" }
        return "\(m.count) 格"
    }

    /// 跳到下一個／上一個符合的格子：選取那一列並標出那一格。
    private func findStep(_ d: Int, proxy: ScrollViewProxy) {
        find.visible = true
        find.message = ""
        guard let n = CSV.nextMatch(findMatches, after: find.current, by: d, cols: cols) else { return }
        find.current = n
        editing.id = nil
        selection = [n.r]
        editing.row = n.r
        editing.column = n.c
        proxy.scrollTo(n.r)
    }

    /// 取代目前這格，再跳到下一個。還沒選到任何符合的格子時，先跳到第一個。
    private func replaceCurrent(proxy: ScrollViewProxy) {
        if let cur = find.current, cur.r < doc.rows.count, cur.c < cols {
            let (s, n) = CSV.replace(doc.rows[cur.r][cur.c], find.query, with: find.replacement, caseSensitive: find.caseSensitive)
            if n > 0 { doc.rows[cur.r][cur.c] = s }
        }
        findStep(1, proxy: proxy)
    }

    /// 一次取代全部，⌘Z 一步就能復原。
    private func replaceAll() {
        let (rows, n) = CSV.replaceAll(doc.rows, find.query, with: find.replacement, caseSensitive: find.caseSensitive)
        if n > 0 {
            editing.id = nil
            doc.rows = rows
        }
        find.current = nil
        find.message = n > 0 ? "已取代 \(n) 處" : "找不到"
    }

    private func closeFind() {
        find.visible = false
        find.current = nil
        tableFocused = true
    }

    private func findBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("尋找", text: Bindable(find).query)
                .textFieldStyle(.roundedBorder).frame(width: 200)
                .focused($findFocused)
                .onSubmit { findStep(1, proxy: proxy) }
            if find.showReplace {
                TextField("取代為", text: Bindable(find).replacement)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { replaceCurrent(proxy: proxy) }
            }
            Toggle("Aa", isOn: Bindable(find).caseSensitive).toggleStyle(.button).help("區分大小寫")
            Button("上一個", systemImage: "chevron.up") { findStep(-1, proxy: proxy) }
                .labelStyle(.iconOnly).help("找上一個（⇧⌘G）")
            Button("下一個", systemImage: "chevron.down") { findStep(1, proxy: proxy) }
                .labelStyle(.iconOnly).help("找下一個（⌘G）")
            Text(findStatus).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Spacer()
            if find.showReplace {
                Button("取代") { replaceCurrent(proxy: proxy) }.disabled(find.query.isEmpty)
                Button("全部取代") { replaceAll() }.disabled(find.query.isEmpty)
            } else {
                Button("取代…") { find.showReplace = true }
            }
            Button("完成") { closeFind() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .onExitCommand { closeFind() }
        .onChange(of: find.query) { find.current = nil; find.message = "" }
        .onChange(of: find.caseSensitive) { find.current = nil; find.message = "" }
    }

    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
        if find.visible {
            findBar(proxy: proxy)
            Divider()
        }
        Table(doc.rows.indices.map(RowRef.init), selection: $selection) {
            TableColumn("#") { r in
                Text("\(r.id + 1)").foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 32, ideal: 40, max: 60)
            TableColumnForEach(0..<cols, id: \.self) { c in
                TableColumn(title(c)) { r in
                    HStack(alignment: .top, spacing: 4) {
                        let id = CellID(r: r.id, c: c)
                        CellView(text: cell(r.id, c), id: id, editing: editing, find: find,
                                 tab: { tab(from: id, by: $0, proxy: proxy) })
                        if let url = image(r.id, c) {
                            Button("查看圖片", systemImage: "photo") { open(url) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).help(ImageRef.relativePath(url, from: fileURL))
                        }
                    }
                    .padding(.vertical, 6)
                }.width(min: 80, ideal: 220)
            }
        }
        .id(fileURL)  // 第一次存檔後相對路徑才有基準；Table 不會自己重畫儲存格，重建一次
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
        .onChange(of: editing.id) { if editing.id == nil && !findFocused { tableFocused = true } }  // 結束編輯後回到表格，可再按 Enter
        }
        .focusedSceneValue(\.findAction) { findAction($0, proxy: proxy) }
        #if HARNESS
        .onAppear { if ProcessInfo.processInfo.environment["H_FIND"] != nil { findAction(.showReplaceInterface, proxy: proxy) } }
        #endif
        }
        .quickLookPreview($quickLook)
        .toolbar {
            ToolbarItemGroup {
                Button("尋找取代", systemImage: "magnifyingglass") {
                    find.visible = true
                    find.showReplace = true
                    findFocused = true
                }.help("尋找與取代（⌘F／⌘⌥F）")
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

/// 正在編輯的格子。用 @Observable 讓每格自己訂閱：Table 不會因 CSVView 的 @State 變動重畫儲存格。
@Observable final class EditingCell {
    var id: CellID?   // 正在編輯的格子
    var row: Int?     // 目前選取的列（只選一列時）
    var column = 0    // 目前所在欄：單擊設定，按 Enter 就編輯這欄
    var hover: Int?   // 滑鼠所在欄（用來判斷點到哪一格）
}

/// 尋找列的狀態；同樣用 @Observable 讓每格自己決定要不要標色。
@Observable final class FindState {
    var visible = false
    var showReplace = false
    var query = ""
    var replacement = ""
    var caseSensitive = false
    var current: CellID?   // 目前跳到的符合格
    var message = ""       // 「已取代 N 處」這類一次性訊息

    func hits(_ s: String) -> Bool {
        visible && !query.isEmpty && s.range(of: query, options: CSV.options(caseSensitive)) != nil
    }
}

/// 平常顯示文字，點兩下才進入編輯；按 Return、Esc 或點別處就結束。
struct CellView: View {
    @Binding var text: String
    let id: CellID
    let editing: EditingCell
    let find: FindState
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
                .background {  // 尋找結果：符合的格子淡黃，目前這格橘色
                    if find.hits(text) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(find.current == id ? Color.orange.opacity(0.45) : Color.yellow.opacity(0.25))
                            .padding(-4)
                    }
                }
                .overlay {  // 標出「目前所在格」：按 Enter 會編輯這格
                    if editing.id == nil && editing.row == id.r && editing.column == id.c {
                        RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5).padding(-4)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active: if editing.hover != id.c { editing.hover = id.c }
                    case .ended: if editing.hover == id.c { editing.hover = nil }  // 離開表格就清掉，按尋找列按鈕時才不會被誤認成點格子
                    }
                }
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
                .background(EnableFindBar())
                .frame(minWidth: 250)
            Preview(markdown: doc.text).frame(minWidth: 250)
        }
    }
}

/// macOS 14 的 TextEditor 沒有開原生尋找列：找出同視窗裡的 NSTextView 打開它（⌘F／⌘⌥F）。
struct EnableFindBar: NSViewRepresentable {
    final class Enabler: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                func walk(_ v: NSView) {
                    if let t = v as? NSTextView {
                        t.usesFindBar = true
                        t.isIncrementalSearchingEnabled = true
                    }
                    v.subviews.forEach(walk)
                }
                if let root = self?.window?.contentView { walk(root) }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Enabler() }
    func updateNSView(_ v: NSView, context: Context) {}
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
