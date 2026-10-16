<div align="center">

# OakReader

**原生 macOS 阅读器，也是你和智能体共用的 AI 知识库。**

集中整理 PDF、论文、书籍和已保存网页。
在原文旁阅读、批注、翻译和提问，点击页码引用即可核对出处。

[下载](https://github.com/oakreader/oakreader/releases/latest) · [官网](https://oakreader.com) · [反馈问题](https://github.com/oakreader/oakreader/issues) · [English](README.md)

![macOS 15.4+](https://img.shields.io/badge/macOS-15.4%2B-black?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

![OakReader——在合集旁比较多本书，生成带来源引用的学习路线](.github/assets/screenshots/research.jpg)

<sub>截图来自 2026 年 10 月的 macOS 开发版，包含演示研究对话与阅读笔记。</sub>

</div>

## 开始使用

需要 **macOS 15.4 或更高版本**。

1. [下载最新版本](https://github.com/oakreader/oakreader/releases/latest)，打开磁盘映像，将 OakReader 拖入「应用程序」。
2. 将文档导入资料库，打开后即可阅读和记笔记。
3. 使用 AI 前，在 **Settings → LLM** 中配置提供商和模型，再打开文档旁的对话或翻译面板。

发行版已内置后端与 CLI；只有从源码构建时才需要安装开发工具。

## 核心功能

<table>
  <tr>
    <td width="60%" valign="middle">
      <img src=".github/assets/screenshots/research.jpg" alt="合集研究——书籍资料旁的跨文档比较与来源引用" width="100%" />
    </td>
    <td width="40%" valign="middle">
      <b>跨文档研究，有据可查</b><br/>
      围绕整个资料库或某个合集提问，让 AI 查找并读取相关资料、比较多份文档，再通过引用回到原文。图中展示基于三本书生成的学习路线。
    </td>
  </tr>
  <tr>
    <td width="60%" valign="middle">
      <img src=".github/assets/screenshots/chat.jpg" alt="AI 对话——附有原文页码引用的阅读路线图" width="100%" />
    </td>
    <td width="40%" valign="middle">
      <b>读懂当前文档，随时核对出处</b><br/>
      在文档旁请求解释、摘要或阅读计划。点击页码引用回到原文，也可附上选中文字或截图，提供更多上下文。
    </td>
  </tr>
  <tr>
    <td width="60%" valign="middle">
      <img src=".github/assets/screenshots/library.jpg" alt="资料库——铺满视图的论文、文章和视频卡片" width="100%" />
    </td>
    <td width="40%" valign="middle">
      <b>集中整理你的阅读资料</b><br/>
      用卡片或列表浏览 PDF、书籍和已保存网页，通过合集、标签、阅读列表与资料库搜索整理内容。
    </td>
  </tr>
  <tr>
    <td width="60%" valign="middle">
      <img src=".github/assets/screenshots/notes.jpg" alt="笔记——PDF 旁的阅读笔记与展开的格式工具栏" width="100%" />
    </td>
    <td width="40%" valign="middle">
      <b>把阅读变成自己的知识</b><br/>
      在原文旁收集高亮、想法与截图。为笔记设置格式、添加标签、关联其他笔记，并导出为 Markdown。
    </td>
  </tr>
  <tr>
    <td width="60%" valign="middle">
      <img src=".github/assets/screenshots/translate.jpg" alt="翻译——PDF 旁的英文原文与中文译文" width="100%" />
    </td>
    <td width="40%" valign="middle">
      <b>对照原文，随读随译</b><br/>
      在独立面板中对照原文与译文。选取段落或通过 OCR 截取区域，切换语言，也可朗读文本。
    </td>
  </tr>
  <tr>
    <td width="60%" valign="middle">
      <img src=".github/assets/screenshots/browse.jpg" alt="网页阅读——在独立标签页中打开已保存文章" width="100%" />
    </td>
    <td width="40%" valign="middle">
      <b>内置浏览，纵览万维</b><br/>
      搜索、打开链接，带着登录身份读实时网页——再把要紧的收进资料库。
    </td>
  </tr>
</table>

**选择你的模型** — 在 Settings → LLM 中连接受支持的云端提供商，或提供兼容 API 的本地服务。

### 让你的智能体使用同一个资料库

通过 `oak` CLI，外部智能体也能检索资料目录、读取文档、提取笔记和管理合集。你整理的资料和笔记，可以继续用于后续研究。Quick Chat 与可复用技能让阅读辅助延伸到文档窗口之外。

文献管理还支持编辑作者、出版信息和引用键，以及复制引用。

## 帮助与反馈

遇到问题或有功能建议，请[提交 GitHub issue](https://github.com/oakreader/oakreader/issues)。报告问题时，请附上 OakReader 版本、macOS 版本和复现步骤；必要时提供截图或示例文档。

## 技术栈

| 组成 | 框架 |
|------|------|
| 界面 | SwiftUI + AppKit |
| PDF 引擎 | PDFKit |
| 资料目录 | 共享的 TypeScript/Bun 后端，通过 SQLite 存储 |
| AI | 基于 `pi-ai` / `pi-agent-core` 的多提供商智能体运行时，打包为本地辅助进程 |
| 检索与智能体访问 | 资料库筛选与 `oak` CLI，支持目录检索、文档文本读取和笔记提取 |
| 网页剪藏 | 浏览器扩展（WXT）→ 本地快照服务 |
| OCR | Apple Vision |

## 从源码构建

### 环境要求

- macOS 15.4 或更高版本
- Xcode 16 或更高版本，含命令行工具
- Bun 与 pnpm 10（用于安装依赖并构建应用内置的后端与 CLI）
- XcodeGen（使用 Homebrew 安装：`brew install xcodegen`）

### 准备项目

```bash
git clone https://github.com/oakreader/oakreader.git
cd oakreader
pnpm install --frozen-lockfile
xcodegen generate
```

### 配置代码签名（首次构建）

项目默认使用维护者的 Apple 开发团队。运行以下脚本，通过被 Git 忽略的本地配置使用你自己的签名身份，无需修改已跟踪的文件：

```bash
scripts/setup-signing.sh
```

按提示输入 Apple Developer **Team ID**（可在 developer.apple.com → Account → Membership 查看，免费 Apple ID 也可使用），脚本会写入 `xcconfig/DeveloperSettings.xcconfig`。没有 Apple 账号时，直接按 Enter 使用适合本地开发的 **ad-hoc 签名**。也可以手动复制并编辑 `xcconfig/DeveloperSettings.example.xcconfig`。

Debug 构建不包含受限的 `keychain-access-groups` 权限，支持自己的团队或 ad-hoc 签名。在 **Settings → LLM** 中配置 AI 凭据，也可通过提供商环境变量（例如 `OPENAI_API_KEY`）传入。

### 运行

```bash
open OakReader.xcodeproj
```

选择 **OakReader** scheme，构建并运行（<kbd>Cmd</kbd>+<kbd>R</kbd>）。
`project.yml` 是唯一真源——`.xcodeproj` 由 XcodeGen 生成。

## 参与贡献

欢迎反馈问题、修复缺陷和提交聚焦的改进。可按上方构建说明在本地运行应用。较大的改动请先[开一个 issue](https://github.com/oakreader/oakreader/issues) 讨论方案，再提交 PR。

## 许可证

[MIT](LICENSE) © 2026 Jiwei Yuan
