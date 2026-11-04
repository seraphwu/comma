# Comma ，

輕巧的 macOS CSV／Markdown 編輯器。給嫌 Excel、Numbers 太大，又被 Mac 上 UTF-8 中文亂碼困擾的人。

- **CSV**：表格直接編輯，新增／刪除列與欄；右側檢閱器編輯長文字與多行內容
- **編碼**：自動辨識 UTF-8、UTF-8 BOM、UTF-16、Big5；存成 UTF-8，可勾「Excel 相容（BOM）」讓 Mac 版 Excel 開啟不亂碼
- **圖片**：儲存格寫 `D01`、`D01.png`、`子資料夾/D01.png`、絕對路徑或圖片網址時，旁邊出現 📷，點一下用 Quick Look 開啟（會在 CSV 所在資料夾與上一層往下找）
- **Markdown**：左邊編輯、右邊即時預覽（⇧⌘N 新增）
- **流程圖**：` ```mermaid ` 區塊以 [Pele](https://github.com/obsidianmd/pele) 渲染

## 建置

需要 macOS 14.4 以上與 Xcode（Swift 6）。

```bash
./build.sh
```

會先跑 CSV 自我測試，再產生 `Comma.app`（ad-hoc 簽章）。拖到「應用程式」即可使用。

## 結構

| 檔案 | 用途 |
|---|---|
| `App.swift` | SwiftUI 介面、文件類型、Markdown 預覽 |
| `CSV.swift` | CSV 解析／輸出、編碼偵測、圖片對應 |
| `web/` | 預覽頁；內含 [marked](https://github.com/markedjs/marked) 與 Pele |
| `icon/make-icon.swift` | 產生 App 圖示（正體中文置中逗點） |
| `test/main.swift` | 自我測試 |

## 授權

MIT。內含的 Pele 與 marked 亦為 MIT，條款見 `web/LICENSES.txt`。
