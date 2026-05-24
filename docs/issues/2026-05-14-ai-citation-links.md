# AI Citation Links — 引用原文点击跳转

## Problem

AI 聊天中引用文档内容时（如"根据第 3 页…""Vaswani et al. 在方法部分提到…"），用户无法直接跳转到对应位置，需要手动翻页查找。这在阅读长论文或跨文档比较时打断思路。

### Current state

- AI 回答中的页码引用是纯文本，不可点击
- 工具输出（ReadDocumentTool、SearchDocumentTool、SemanticSearchTool）已包含页码和 citeKey 信息，但 AI 没有被指示将其转化为可交互格式
- `ViewerViewModel.goToPage(_:)` 已存在（`ViewerViewModel.swift:82-91`），支持边界检查和导航历史
- Notes 系统已有 `[[pageN]]` 点击跳转页面的先例（`NoteEditorView.swift:359`）
- `oakreader://` URL scheme 已注册（`Info.plist:44-53`），但只做 `showMainWindow()`（`AppDelegate.swift:64-67`）
- Chat markdown 渲染使用 Textual 框架的 `StructuredText`（`ChatBubbleView.swift:137`），无自定义链接拦截

### Desired state

- AI 回答中的页码引用变成可点击链接
- 点击当前文档引用 → PDF 阅读器跳转到对应页面
- 点击跨文档引用 → 打开该文档并跳转到指定页面
- 链接格式对 AI 友好（简洁、易生成），对用户友好（可读、不突兀）

## Research: Zotero URL Scheme

Zotero 是学术文献管理领域的标杆，其 URL scheme 设计值得借鉴。

### Zotero URL 格式

| 功能 | 格式 | 说明 |
|------|------|------|
| 选中条目 | `zotero://select/library/items/{itemKey}` | 打开 Zotero 并选中该条目 |
| 选中条目（by citeKey） | `zotero://select/items/@{citeKey}` | Better BibTeX 扩展支持 |
| 打开 PDF | `zotero://open-pdf/library/items/{itemKey}` | 在 Zotero 内置阅读器打开 PDF |
| 打开 PDF + 跳页 | `zotero://open-pdf/library/items/{itemKey}?page={N}` | 打开并跳转到指定页 |
| 打开 PDF + 定位标注 | `zotero://open-pdf/library/items/{itemKey}?page={N}&annotation={annotationKey}` | 跳转到具体标注 |
| 群组文献 | `zotero://open-pdf/groups/{groupID}/items/{itemKey}?page={N}` | 群组库中的 PDF |

### Zotero 设计的关键决策

1. **使用 itemKey（8 字符 ID）而非人类可读标识符** — Zotero 的 itemKey 是内部 ID，对用户不友好；Better BibTeX 尝试支持 citeKey 但未完全实现
2. **PDF attachment key vs parent item key** — 必须使用 PDF attachment 的 key，而非父条目的 key，这经常让用户困惑
3. **query parameters 用于可选参数** — `page` 和 `annotation` 作为 query params，路径部分只放 item 定位
4. **library/groups 路径区分作用域** — 明确区分个人库和群组库

### Zotero 的不足

- itemKey 不可读，用户需要借助插件（Zutilo）或拖拽标注来生成链接
- Better BibTeX 尝试用 `@citeKey` 替代 itemKey，但 `open-pdf` 场景一直没实现
- 文档不足，大量行为只能从论坛帖子中拼凑
- Zotero 7 beta 中旧格式 `zotero://open-pdf/1_{itemKey}` 被废弃但无迁移指引

## Design: OakReader `oak://` Scheme

### 设计原则

1. **AI 可生成** — 格式简洁，AI 无需复杂逻辑即可在 markdown 中嵌入
2. **用户可读** — citeKey（如 `vaswaniAttention2017`）比 UUID 更易理解
3. **渐进复杂** — 最简单的用法（当前文档跳页）极其简短
4. **Zotero 兼容思路** — 路径定位 item，query params 放可选参数

### URL 格式

| 场景 | 格式 | 示例 |
|------|------|------|
| 当前文档跳页 | `oak://page/{N}` | `oak://page/5` |
| 打开文档（by citeKey） | `oak://cite/{citeKey}` | `oak://cite/vaswaniAttention2017` |
| 打开文档 + 跳页 | `oak://cite/{citeKey}?page={N}` | `oak://cite/vaswaniAttention2017?page=3` |
| （未来）定位标注 | `oak://cite/{citeKey}?page={N}&annotation={id}` | 预留扩展 |

- `N` 为 **1-based** 页码（AI 工具输出和用户认知均为 1-based）
- `citeKey` 已被 SemanticSearchTool、SearchLibraryTool、ReadLibraryItemTool 广泛使用
- 无 `/library/` 路径前缀 — OakReader 当前只有单用户单库，无需区分

### 对比 Zotero

| | Zotero | OakReader |
|---|---|---|
| 标识符 | 8 字符 itemKey（不可读） | citeKey（人类可读） |
| 最短链接 | `zotero://open-pdf/library/items/IBQAQYSF` | `oak://page/5` |
| 跳页 | query param `?page=N` | 当前文档用路径，跨文档用 query param |
| 生成方式 | 用户手动拖拽/插件 | AI 自动生成 |
| 文档类型 | 仅 PDF | PDF + web snapshot + markdown + embed |

### AI Markdown 输出示例

**当前文档引用：**
```markdown
论文在方法部分详细描述了 multi-head attention 机制 ([p. 5](oak://page/5))，
其中 scaled dot-product attention 的公式定义在 ([p. 4](oak://page/4))。
```

**跨文档引用（语义搜索结果）：**
```markdown
这与 Vaswani et al. 的结论一致 ([vaswaniAttention2017, p. 3](oak://cite/vaswaniAttention2017?page=3))。
另见 Devlin et al. 关于预训练的讨论 ([devlinBERTPretraining2019](oak://cite/devlinBERTPretraining2019))。
```

## Implementation Plan

### 涉及文件

| 文件 | 改动 |
|------|------|
| `OakReader/Views/RightPanel/ChatBubbleView.swift` | 添加 `onNavigateToPage` / `onOpenCitation` 回调 + `OpenURLAction` 拦截 |
| `OakReader/Views/RightPanel/AIChatView.swift` | 传递导航闭包到 ChatBubbleView |
| `OakReader/ViewModels/ChatViewModel.swift` | 新增 `openCitation(citeKey:pageIndex:)` 方法 |
| `OakReader/Services/AI/LLMContextProvider.swift` | system prompt 追加引用格式指令 |
| `OakReader/Services/LibraryItemStore.swift` | 可能需新增 `findItem(byCiteKey:)` |

### Step 1: ChatBubbleView — 拦截 `oak://` 链接

新增回调属性：
```swift
var onNavigateToPage: ((Int) -> Void)?
var onOpenCitation: ((String, Int?) -> Void)?
```

在 `messageBubble` 的 assistant 分支，给 `StructuredText` 添加 `OpenURLAction`：
```swift
base
    .environment(\.openURL, OpenURLAction { url in
        guard url.scheme == "oak" else { return .systemAction }

        if url.host == "page",
           let pageStr = url.pathComponents.dropFirst().first,
           let page = Int(pageStr) {
            onNavigateToPage?(page - 1)  // 1-based → 0-based
            return .handled
        }

        if url.host == "cite",
           let citeKey = url.pathComponents.dropFirst().first {
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })
                .flatMap { Int($0.value ?? "") }
            onOpenCitation?(citeKey, page.map { $0 - 1 })  // 1-based → 0-based
            return .handled
        }

        return .systemAction
    })
```

### Step 2: AIChatView — 传递导航回调

```swift
ChatBubbleView(
    turn: turn,
    onSaveToNote: onSaveAssistantResponse,
    onApproveToolCall: { chatVM.approveToolCall() },
    onDenyToolCall: { chatVM.denyToolCall() },
    onNavigateToPage: { pageIndex in
        chatVM.parent?.viewer.goToPage(pageIndex)
    },
    onOpenCitation: { citeKey, pageIndex in
        chatVM.openCitation(citeKey: citeKey, pageIndex: pageIndex)
    }
)
```

### Step 3: ChatViewModel — 跨文档打开

```swift
func openCitation(citeKey: String, pageIndex: Int?) {
    guard let appState else { return }
    let store = appState.libraryStore

    guard let item = store.findItem(byCiteKey: citeKey) else { return }
    appState.openLibraryItem(item)

    if let pageIndex {
        // 等文档加载后跳转（PDF 加载需要时间）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            appState.activeTab?.document?.viewer.goToPage(pageIndex)
        }
    }
}
```

> **注意**：`asyncAfter` 是临时方案。更健壮的做法是在 `DocumentState` 上加 `pendingPageIndex: Int?`，PDF 加载完成后检查并跳转。

### Step 4: LLMContextProvider — 指示 AI 使用引用格式

在 system prompt 的 tool hint 之后追加：
```swift
parts.append("""
    When referencing specific pages from the document, use clickable \
    citation links: [p. N](oak://page/N) where N is the 1-based page \
    number. When referencing other documents from search results, use: \
    [citeKey, p. N](oak://cite/citeKey?page=N). Only cite pages you \
    have actually read or found via search tools.
    """)
```

### Step 5: LibraryItemStore（如需要）

确认是否存在 `findItem(byCiteKey:)` 方法。如果没有：
```swift
func findItem(byCiteKey citeKey: String) -> LibraryItem? {
    items.first { $0.citeKey == citeKey }
}
```

## Future Extensions

1. **`&annotation={id}`** — 跳转到具体标注，而非只是页面
2. **`oak://search?q={query}`** — 点击触发文档内搜索，定位到具体段落
3. **`oak://cite/{citeKey}?highlight={text}`** — 类似 Chrome 的 text fragment，高亮特定文字
4. **Library chat 支持** — Library 级别的 AI 对话也能生成和响应 `oak://cite/` 链接
5. **反向引用** — 从文档标注反向查看哪些 AI 对话引用了这个位置
6. **拷贝引用链接** — 用户在 PDF 中右键 → "Copy Citation Link" 生成 `oak://cite/{citeKey}?page={N}` 供粘贴到笔记或其他 app

## References

- [Zotero Forum: Create external link to open PDF](https://forums.zotero.org/discussion/73776/create-external-link-to-open-pdf-within-zotero)
- [Zotero Forum: PDF reader and zotero://open-pdf links](https://forums.zotero.org/discussion/90858/pdf-reader-and-zotero-open-pdf-links)
- [Zotero Forum: Zotero 7 beta open-pdf URL scheme](https://forums.zotero.org/discussion/112275/zotero-7-beta-open-pdf-url-scheme)
- [Better BibTeX: open-pdf by citekey issue](https://github.com/retorquere/zotero-better-bibtex/issues/1347)
