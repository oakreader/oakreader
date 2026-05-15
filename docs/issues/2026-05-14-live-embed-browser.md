# Live Embed Browser — 内嵌实时网页浏览器

## Problem

OakReader 的 embed 查看器（`EmbedCardView`）当前只能渲染本地保存的 HTML 快照。对于需要登录才能查看的内容（Twitter/X 受限推文、Reddit 登录后内容、付费墙文章等），用户只能点击 "Open in Browser" 跳转到系统浏览器，打断了阅读流程。

### Current state

- `LocalEmbedWebView` 加载本地 `embed.html`，通过 `WKContentRuleList` 拦截所有外部请求
- 无网络访问能力，无法加载实时页面
- 无 cookie/session 持久化，无法保持登录态
- 每个 WKWebView 实例独立创建 `WKWebViewConfiguration`，不共享 `WKProcessPool`
- 用户查看需要登录的内容时，只能 "Open in Browser" → 切换到 Safari → 登录 → 查看
- App 已有本地导入服务 `SnapshotServer` 监听 `127.0.0.1:23119`，目前 CORS 允许任意 origin，实时网页 JS 会显著放大这个攻击面

### Desired state

- Embed 查看器直接加载 `sourceURL` 实时网页
- 用户可以在 embed 内登录网站，cookie 持久化保存
- 同域名的多个 embed 共享登录态（登录一次 Twitter，所有 Twitter embed 都可见）
- 重启 app 后登录态仍然有效
- 提供最小化浏览器控件（后退/前进/刷新/URL 显示）
- 失败、离线、站点阻止嵌入时，仍回退到本地 `embed.html` 卡片和 "Open in Browser"

## Risk assessment

**总体风险：中高。** `WKWebView` 技术上可行，但这不是普通 viewer 改造，而是把任意站点 JS、持久 cookie、OakReader 本地 API 放进同一个进程的安全项目。

### Highest-risk items

1. **Localhost API 暴露**
   - `SnapshotServer` 当前接受 `/snapshot`、`/collections`、`/tags`、`/selected-collection` 请求。
   - 响应头使用 `Access-Control-Allow-Origin: *`。
   - 一旦 embed 加载任意网页，该网页 JS 可以尝试访问 `http://127.0.0.1:23119`，读取库结构或制造导入请求。
   - **必须先修**：token 鉴权、Origin 校验、CORS 收紧，否则不要启用 live embed。

2. **Snapshot viewer 安全边界被混淆**
   - `webSnapshot` 的产品承诺是离线、自包含、不可联网。
   - `embed` 的产品语义是 live、联网、可能登录。
   - 两者必须使用显式不同的 `WKWebViewConfiguration`，不能依赖默认配置隐式隔离。

3. **站点兼容性不可控**
   - X/Twitter、Reddit、Google OAuth、付费墙、captcha、bot detection 可能拒绝 embedded WebView。
   - 该功能需要真实站点 spike，不能只靠本地 mock 验证。

4. **Cookie 隐私和清除能力**
   - `WKWebsiteDataStore.default()` 会持久化网页登录态。
   - 必须提供至少一个清除 live embed 网站数据的入口，否则用户无法撤销登录态。

5. **Navigation policy**
   - Live 页面不能访问 localhost、私网地址、file URL 或 OakReader 自己的 custom URL scheme。
   - `target="_blank"` 和 OAuth popup 需要明确策略：同 WebView 打开、临时 child WebView、或外部浏览器打开。

## Proposal

### Implementation shape

不要直接删除 `LocalEmbedWebView`。先以受控 MVP 引入 live browser，并保留本地 `embed.html` 作为 fallback。

```
EmbedCardView
├─ LiveEmbedBrowserBar
├─ LiveEmbedWebView(sourceURL)
└─ LocalEmbedWebView fallback
   ├─ live load failed
   ├─ user offline
   ├─ unsupported scheme / blocked host
   └─ site blocks embedded login
```

### Phase 0 — Security prerequisite

在实现 live browser 之前先硬化 `SnapshotServer` 和扩展通信：

1. `SnapshotServer`
   - 生成 per-install 或 per-session secret token。
   - 对 `GET /collections`、`GET /tags`、`GET /selected-collection`、`POST /snapshot` 全部要求 token。
   - 校验 `Origin`，只允许 OakReader extension origin 或无 origin 的可信本机客户端。
   - 移除 `Access-Control-Allow-Origin: *`，改为精确 allowlist。
   - 对 `OPTIONS` preflight 同样执行 Origin/header 校验。

2. Browser extension
   - 请求 `127.0.0.1:23119` 时带 token header，例如 `X-OakReader-Token`。
   - token 存储在 extension storage 中，由 app 首次配对或本地配置提供。

3. Live web navigation blocklist
   - 阻止 `localhost`、`127.0.0.0/8`、`::1`。
   - 阻止 RFC1918 私网地址：`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`。
   - 阻止 `file://`、`oakreader://`、`data:` top-level navigation。
   - 只允许 `https`，必要时允许用户显式外部浏览器打开 `http`。

### Architecture

引入共享 `WKProcessPool` 单例 + `WKWebsiteDataStore.default()` 持久化存储：

```
┌─ EmbedWebViewPool.shared (WKProcessPool 单例) ─┐
│                                                  │
│  ┌─ Embed A ─┐  ┌─ Embed B ─┐  ┌─ Embed C ─┐  │
│  │ twitter.com│  │ twitter.com│  │ reddit.com │  │
│  │ (已登录)   │  │ (共享cookie)│  │ (独立cookie)│  │
│  └────────────┘  └────────────┘  └────────────┘  │
│                                                  │
│  Cookie 持久化: ~/Library/WebKit/OakReader/      │
└──────────────────────────────────────────────────┘
```

### Components

**新建文件：**

1. `OakReader/Views/Viewer/LiveEmbedWebView.swift`
   - `EmbedWebViewPool` — 共享 ProcessPool 单例
   - `LiveEmbedNavState` — @Observable 导航状态（canGoBack, title, url, isLoading...）
   - `LiveEmbedNavAction` — 导航动作通道（goBack, goForward, reload）
   - `LiveEmbedWebView` — NSViewRepresentable，WKNavigationDelegate + WKUIDelegate
   - `LiveEmbedNavigationPolicy` — URL scheme、localhost、私网地址、外部打开策略

2. `OakReader/Views/Viewer/LiveEmbedBrowserBar.swift`
   - 最小化浏览器工具栏：[←] [→] [↻] [URL/Title 显示] [↗ 在浏览器打开]
   - 使用 `OakToolButton` + `OakStyle` 保持设计一致性

**修改文件：**

3. `OakReader/Services/SnapshotServer.swift`
   - 添加 token 鉴权、Origin 校验和 CORS allowlist
   - 这是 live embed 的 blocker，不应跳过

4. `browser-extension/src/lib/api.ts`
   - 对 OakReader localhost API 请求添加 token header
   - 处理 401/403，引导用户重新配对 extension

5. `OakReader/Views/Viewer/EmbedCardView.swift`
   - 改为 `LiveEmbedBrowserBar` + `LiveEmbedWebView` 组合
   - 加载 `media.sourceURL` 而非本地 `embed.html`
   - 保留 `LocalEmbedWebView`，作为失败/离线/站点阻止嵌入时的 fallback
   - 错误遮罩显示 Retry、Use Snapshot Card、Open in Browser

6. `OakReader/Views/Viewer/WebArchiveViewerRepresentable.swift`
   - 显式使用独立 `WKProcessPool`
   - 考虑显式使用 `.nonPersistent()` 或独立 `WKWebsiteDataStore`，避免和 live embed 默认存储发生隐式共享

**不影响：**
- YouTube embed（走 `MediaViewerView` 路径）
- Web snapshot viewer（继续保持离线、阻断外部请求、不共享 live embed cookie）
- PDF viewer

### Cookie/Session 机制

| 层级 | 作用 |
|---|---|
| `EmbedWebViewPool.shared` | 所有 live embed WKWebView 共享同一进程池 → 内存 cookie 共享 |
| `WKWebsiteDataStore.default()` | cookie 持久化到磁盘 → 重启后有效 |
| HTTP cookie 域名隔离 | 标准 web 行为 — twitter.com cookie 不发到 reddit.com |
| 与其他 viewer 隔离 | WebArchiveViewer 显式使用独立配置，不共享 live embed cookie |

### Privacy controls

MVP 至少需要提供一个全局清除入口：

- Settings → Privacy → Clear Live Embed Website Data
- 调用 `WKWebsiteDataStore.default().removeData(...)`
- 清除 cookies、localStorage、IndexedDB、cache

后续再做按域名清除 UI。

### Edge cases

- **离线**：`didFailProvisionalNavigation` → 显示错误遮罩 + Retry 按钮
- **`target="_blank"` 链接**：默认在同一 webView 加载；如果被 navigation policy 阻止，则提供 Open in Browser
- **OAuth popup**：不要假设都能通过重定向处理。MVP 支持同 WebView fallback；若真实站点失败，再增加临时 child WebView/window
- **站点阻止 WebView 登录**：显示 fallback，并允许外部浏览器打开
- **ATS**：现代网站均 HTTPS，不需额外配置
- **本地服务访问**：所有 localhost/private network navigation 必须 cancel

## Open source references

| 项目 | Stars | 参考价值 |
|---|---|---|
| [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) | 10k | WKWebView 文章查看器、自定义右键菜单、键盘代理 |
| [SwiftUI-WebView](https://github.com/kylehickinson/SwiftUI-WebView) | 362 | @dynamicMemberLookup + KVO 绑定 WKWebView → SwiftUI |
| [WKCookieWebView](https://github.com/Kofktu/WKCookieWebView) | — | 单例 WKProcessPool、双存储 cookie 同步 |
| [MacPin](https://github.com/kfix/MacPin) | — | Site-specific browser、标签页、cookie 持久化 |

## Validation plan

### Spike matrix

必须用真实站点验证，不以本地 mock 作为可用性结论：

| Site | Scenario | Expected |
|---|---|---|
| X/Twitter | 打开受限 tweet，登录，刷新，重启 app | 登录态保留或明确 fallback |
| Reddit | 打开登录后内容，登录，打开第二个 reddit embed | 同域登录态共享 |
| Substack/Medium | 打开 paywall/会员内容 | 可登录或明确 fallback |
| Google OAuth site | 触发 OAuth popup/redirect | 能完成或明确外部浏览器 fallback |
| `http://127.0.0.1:23119` | 从 live embed 访问本地 API | 必须被 navigation policy 或 token 鉴权阻止 |

### Acceptance checklist

- [ ] SnapshotServer 不再接受无 token 请求
- [ ] CORS 不再允许任意 origin
- [ ] Live embed 不允许访问 localhost、私网、file URL、`oakreader://`
- [ ] Web snapshot viewer 仍然阻断所有外部网络请求
- [ ] Live embed 登录态在同域名 embed 间共享
- [ ] App 重启后 live embed 登录态仍然可用
- [ ] 用户可以清除 live embed website data
- [ ] Live load 失败时可以回退到本地 `embed.html`
- [ ] `target="_blank"` 不会生成失控新窗口
- [ ] Snapshot area selection 仍能在 live embed 上工作，或明确禁用并解释

## Future extensions

1. **快速保存链接**：跳过 web-import 流程，直接存 URL + 自动抓取 title/favicon → LiveEmbedWebView 直接加载
2. **Cookie 管理 UI**：在设置中显示已登录的站点，允许清除特定域名的 cookie
3. **Reader View 模式**：在实时页面上叠加类似 Safari Reader 的简洁阅读模式
4. **Per-site settings**：每个域名独立控制是否允许 live load、是否总是外部打开、是否清除数据
