# Agent Overlay Sandbox — Virtualization.framework + Linux OverlayFS

## Problem

现在很多 Agent（包括 Cowork 等）把整理文件当成卖点功能，但都有同一个问题：需要用户先授予某个目录的修改权限，用户完全不知道给了权限后 Agent 会做什么，无法保证它不会弄丢文件或越改越乱。

Bridge 的解决方案是内嵌 Linux 虚拟机 + OverlayFS：Agent 在 overlay 里随便改，改完后展示所有变更，用户可以全部接受或选择性接受部分文件。得益于 OverlayFS 的 COW 语义，整理文件时不需要先把文件夹复制到沙盒里，只有 Agent 实际修改文件时才会复制一份。

### Current state

- OakAgent 已有可插拔的 `FileOperations` / `BashOperations` / `LsOperations` 协议（`Packages/OakAgent/Sources/OakAgent/Operations/`）
- `ToolExecutionContext` 组装这三个协议实例，传给所有 Tool 的 `execute()` 方法（`Tool/ToolExecutionContext.swift`）
- `PathSandbox` 做路径验证，防止 Agent 越界访问（`Operations/PathSandbox.swift`）
- 现有 Tool 权限分级：`readOnly` / `write` / `dangerous`，写操作需要用户确认（`Tool/AgentTool.swift`）
- 没有 move/delete/copy 专用 Tool，Agent 需要通过 BashTool 执行这些操作
- `GrepTool` 和 `FindTool` 内部调用 `bashOperations.execute()`（`GrepTool.swift:50`、`FindTool.swift:42`）

### Desired state

- Agent 在真正的 OverlayFS 沙盒中自由操作文件，原始文件系统不受影响
- Bash 命令在 VM 内自由执行，不需要禁用或白名单
- Agent 完成后，所有文件变更以列表形式展示给用户
- 用户可以全部接受、选择性接受（如只要最终结果不要中间文件），或全部放弃

## Research: macOS 原生技术方案对比

| 方案 | 真正 Overlay | Bash 隔离 | 无第三方 | 启动开销 | 复杂度 |
|------|:-:|:-:|:-:|:-:|:-:|
| **A. Virtualization.framework + Linux OverlayFS** | 完整 | 完整（VM 级） | Apple 原生 | ~0.7s | 中高 |
| B. APFS clonefile + 用户空间 overlay | 模拟 | 无（需禁用 bash） | Apple 原生 | 0ms | 中 |
| C. FSKit 自定义文件系统 | 完整 | 无 | Apple 原生 | 0ms | 非常高 |
| D. macFUSE 5.2 (FSKit backend) | 完整 | 无 | 第三方 | 0ms | 高 |
| E. sandbox-exec 限制写入 | 无（只能 deny） | 部分 | Apple 原生 | 0ms | 低 |

**选择方案 A** 的理由：
- 这就是 Bridge 的方案，验证过可行
- 真正的内核级 OverlayFS，不需要在用户空间模拟 whiteout、目录合并等
- Bash/grep/find 等命令在 VM 内自由执行，无需禁用或改造
- WWDC 2025 Apple 开源了 Containerization framework，轻量 Linux micro-VM 冷启动仅 ~0.7s
- `VZSharedDirectory(url:, readOnly: true)` 直接把 host 目录只读挂载到 VM
- VM 级别的进程隔离，比任何用户空间方案都更安全

## Design: Virtualization.framework + Linux OverlayFS

### Architecture

```
macOS Host                               Linux micro-VM (~0.7s boot)
┌────────────────────────┐               ┌──────────────────────────────┐
│                        │               │                              │
│  Agent Loop            │   vsock       │  SandboxDaemon               │
│  (LLM ↔ Tool calls)   │◄─────────────►│  (接收 + 执行 tool commands) │
│                        │   JSON-RPC    │                              │
│  ChatViewModel         │               │  Bash/Grep/Find:             │
│  ├── send()            │               │  在 /sandbox/merged 上自由执行│
│  ├── tool confirmation │               │  写入被 OverlayFS 隔离到     │
│  └── change review ◄───────────────────│  /sandbox/upper               │
│                        │               │                              │
│                        │  virtio-fs    │  OverlayFS:                  │
│  ~/OakReader/          │──────────────►│  /sandbox/merged             │
│    storage/{id}/       │  (read-only)  │    = upper (rw) + lower (ro) │
│                        │               │                              │
└────────────────────────┘               └──────────────────────────────┘
                                                      │
                                         Agent 完成后提取 upper layer diff
                                                      │
                                                      ▼
                                    ┌─────────────────────────────────┐
                                    │  ChangeReviewView               │
                                    │  ☑ created / ☑ modified / ☐ tmp │
                                    │  [Discard All] [Accept Selected]│
                                    └─────────────────────────────────┘
                                                      │
                                         用户确认后才 apply 到真实文件系统
```

**两层防护：**
1. **VM 隔离** — Agent 在独立 Linux VM 中运行，host 目录只读挂载，所有写入被 OverlayFS 隔离到 upper layer，bash/grep/find 自由执行但无法逃逸 VM
2. **用户确认** — 所有变更必须经过用户 review 才能 apply 到真实文件系统

### 数据流

1. **启动**: ChatViewModel 创建 `SandboxVM`，通过 Virtualization.framework 启动 Linux micro-VM
2. **挂载**: host 目录通过 `VZVirtioFileSystemDeviceConfiguration` + `VZSharedDirectory(readOnly: true)` 只读挂载到 VM
3. **OverlayFS**: VM 内的 init 进程配置 OverlayFS，将 virtio-fs mount 作为 lower layer
4. **执行**: Agent Loop 在 macOS 上运行，每个 tool call 通过 vsock 发送到 VM 内的 SandboxDaemon
5. **SandboxDaemon** 在 `/sandbox/merged` 上执行命令（read/write/bash/grep/find 等），OverlayFS 自动处理 COW
6. **完成**: 读取 `/sandbox/upper` 的内容，生成 `[FileChange]` 列表
7. **Review**: 展示给用户，选择性 apply 到 host 文件系统

### 与 Bridge 的对比

| 特性 | Bridge | OakReader |
|------|--------|-----------|
| VM 技术 | 自研 Linux VM | Apple Virtualization.framework |
| 启动速度 | ~300ms | ~700ms（Containerization 框架） |
| Host 目录挂载 | 自研方案 | VZSharedDirectory + virtio-fs |
| OverlayFS | 标准 Linux OverlayFS | 同 |
| Agent 执行位置 | VM 内 | VM 内（通过 RPC bridge） |
| Bash 支持 | 完整 | 完整 |
| 跨文件系统 | 支持 | 支持（virtio-fs 不挑 host FS） |

## Research: BoxLite 架构分析

分析了 [BoxLite](https://github.com/boxlite-ai/boxlite)（Rust 实现的可嵌入 VM 沙盒运行时，定位 "SQLite for sandboxing"），用于校准和优化我们的设计。

### BoxLite 架构概览

```
Host App (Rust)
├── BoxliteRuntime (嵌入式，无 daemon)
│   ├── BoxManager → 管理 Box 生命周期
│   ├── ImageManager → OCI 镜像拉取 + 缓存
│   └── LiteBox → 单个沙盒实例
│       ├── ShimController → 子进程管理
│       ├── Jailer → OS 级沙盒 (bwrap/sandbox-exec)
│       └── libkrun → VMM (KVM / Hypervisor.framework)
│           ├── Guest Agent (gRPC server in VM)
│           ├── OCI Container Runtime (libcontainer)
│           └── virtiofs mounts + QCOW2 disks
└── SDKs: Rust, Python, Node, C, Go, CLI, REST
```

### 关键对比

| 维度 | BoxLite | OakReader (本设计) |
|------|---------|-------------------|
| **VMM** | libkrun (封装 KVM / Hypervisor.framework) | Virtualization.framework |
| **Host-Guest RPC** | gRPC + protobuf | JSON-RPC over vsock |
| **文件隔离** | QCOW2 持久化磁盘（无文件级 diff） | OverlayFS（文件级变更追踪） |
| **文件共享** | virtiofs（读写均可） | virtiofs（只读）+ OverlayFS |
| **Guest 内部** | OCI 容器运行时 (libcontainer) | 最小 init + Alpine + 持久化 toolchain |
| **安全层** | Jailer: cgroups + seccomp + bwrap/sandbox-exec | VM 隔离 + 用户确认 |
| **启动延迟** | ~1.4s macOS (dylib 签名验证占 70%) | 预期 ~1.0-1.5s |
| **工具安装** | OCI 镜像（如 python:slim） | Alpine apk + 持久化 toolchain 层 |
| **变更审查** | 无（持久化到 QCOW2） | diff upper layer → 用户选择性 apply |
| **语言** | Rust core + 多语言 SDK | Swift core + Go/Rust guest daemon |

### 对设计的启发

**1. Virtualization.framework 是正确选择**

BoxLite 用 libkrun 是因为需要跨平台（Linux KVM + macOS HVF）。OakReader 只需 macOS，Virtualization.framework 是更好的选择——Apple 原生 API，App Store 兼容，VZSharedDirectory 提供原生 virtio-fs，VZVirtioSocketDevice 提供原生 vsock。

**2. JSON-RPC 优于 gRPC（对本场景）**

BoxLite 用 gRPC (tonic + prost) 处理复杂的容器生命周期管理。OakReader 的 RPC 负载是简单的 tool call（字符串为主），JSON-RPC 更合适：无代码生成步骤、人类可读便于调试、消除 gRPC-Swift + SwiftProtobuf 依赖链。

**3. OverlayFS 是核心差异化**

BoxLite 用 QCOW2 持久化磁盘——VM 级快照，无法选择性接受单个文件变更。这证实 OverlayFS 对我们的场景不可替代：用户需要在文件粒度上 review 和 cherry-pick Agent 的修改。

**4. Jailer 多层安全值得借鉴**

BoxLite 在 VM 之外还加了 OS 级沙盒（macOS 上是 sandbox-exec）。我们应该考虑：
- VM init 中设置 memory cgroup 限制，防止 OOM
- 用 seccomp 限制 SandboxDaemon 的 syscall 范围
- 这些可以在 VM 的 init script 中零成本添加

**5. 真实启动延迟需要上调**

BoxLite 文档记录 macOS 上 ~1.4s 冷启动，其中 70% 是 dylib 代码签名验证（不可避免）。设计中引用的 ~0.7s 来自 Apple Containerization 框架基准，实际应预算 ~1.0-1.5s。应考虑 VM 预热策略（app 启动时预创建 VM）。

**6. BoxLite 无法直接使用**

- **Rust FFI** — 集成 Rust 到 Swift/Xcode 项目增加显著构建复杂度（cargo build scripts, universal binary）
- **无 OverlayFS** — 使用 QCOW2 持久化磁盘，无法提供文件级变更审查
- **OCI 复杂度** — BoxLite 的镜像管理（OCI layers, rootfs assembly）对 OakReader 来说过度设计
- **libkrun vs VF** — 我们需要 Virtualization.framework 的 App Store 兼容性和原生 vsock/virtio-fs 支持

### macOS 上无法使用 Bubblewrap

BoxLite 在 Linux 上使用 Bubblewrap (bwrap) 做进程隔离，macOS 上使用 sandbox-exec。Bubblewrap 依赖 Linux 专有系统调用（`unshare(CLONE_NEWNS)`、`pivot_root()`、bind mount namespace），macOS/Darwin 内核没有这些机制。

macOS 上可选的原生隔离技术：

| 技术 | 隔离级别 | Host CLI 可用 | 文件级变更追踪 |
|------|----------|:---:|:---:|
| Virtualization.framework (VM) | 最强（硬件级） | ✗（需在 VM 内安装） | ✓（OverlayFS） |
| sandbox-exec (Seatbelt) | 中等（进程级） | ✓ | ✗（需 APFS clone + diff） |
| App Sandbox (entitlements) | 弱（app 级） | ✓ | ✗ |

选择 VM 方案是因为它同时提供最强隔离和内核级 OverlayFS 变更追踪。Host CLI 可用性问题通过持久化 toolchain 层解决（见下文）。

## Design: Multi-Layer OverlayFS with Persistent Toolchain

### 核心改进：解决 VM 内工具可用性

原始设计的 VM 只包含 busybox (~5MB)，无法运行 Python、Node.js 等 host 上的 CLI 工具。改进方案：使用 Alpine Linux 作为 base rootfs，Agent Skill 声明式指定依赖，通过 `apk` 安装到持久化 toolchain 磁盘。

### Multi-Layer OverlayFS Architecture

```
macOS Host                               Linux micro-VM
┌────────────────────────┐               ┌──────────────────────────────────┐
│                        │               │                                  │
│  Agent Loop            │   vsock       │  SandboxDaemon                   │
│  (LLM ↔ Tool calls)   │◄─────────────►│  (接收 + 执行 tool commands)     │
│                        │   JSON-RPC    │                                  │
│  ChatViewModel         │               │  OverlayFS merged view:          │
│  ├── send()            │               │  /sandbox/merged                 │
│  ├── tool confirmation │               │    = upper (rw, 临时会话层)      │
│  └── change review ◄───────────────────│    + toolchain (ro, 持久化工具)  │
│                        │               │    + hostfs (ro, host 文件)      │
│                        │  virtio-fs    │    + base (ro, Alpine rootfs)    │
│  ~/OakReader/          │──────────────►│                                  │
│    storage/{id}/       │  (read-only)  │  工具安装:                       │
│                        │               │  apk add python3 ffmpeg ...      │
│  ~/.oakbox/            │               │  → 写入 toolchain QCOW2 磁盘    │
│    toolchain.qcow2  ◄─────────────────│    (跨会话持久化)                 │
│                        │  virtio-blk   │                                  │
└────────────────────────┘               └──────────────────────────────────┘
```

### OverlayFS 四层结构

```bash
mount -t overlay overlay \
  -o lowerdir=/toolchain:/hostfs:/base,upperdir=/session,workdir=/work \
  /sandbox/merged
```

| 层 | 挂载方式 | 读写 | 持久化 | 内容 |
|---|---|---|---|---|
| **upper** (session) | tmpfs | rw | 否（会话结束即丢弃） | Agent 本次会话的文件修改 |
| **toolchain** | virtio-blk QCOW2 | ro* | 是（跨会话） | 已安装的 CLI 工具 (python3, ffmpeg...) |
| **hostfs** | virtio-fs | ro | — | Host 目录（用户的文件） |
| **base** | initramfs | ro | — | Alpine Linux rootfs (~8MB) |

\* toolchain 层在安装工具时临时变为 rw，安装完成后切回 ro 再挂载 OverlayFS。

### Skill 声明式依赖安装

OakAgent 的 Skill 系统已有 `SkillRequirements.bins` 字段。扩展为 sandbox 依赖：

```json
{
  "requires": {
    "bins": [
      { "name": "python3", "install": "apk add python3" },
      { "name": "pandoc", "install": "apk add pandoc" },
      { "name": "ffmpeg", "install": "apk add ffmpeg" }
    ]
  }
}
```

**安装流程：**
1. VM 启动后，挂载 toolchain QCOW2 磁盘
2. 检查 Skill 声明的依赖是否已安装（`which python3`）
3. 缺失的依赖 → 以 rw 挂载 toolchain → `apk add` → 卸载
4. 以 ro 挂载 toolchain，组装 OverlayFS
5. Agent 开始工作

**体验时间线：**

| 场景 | 耗时 |
|------|------|
| VM 冷启动 | ~1.0-1.5s |
| 首次安装 Python | ~10-30s（下载 + 安装，仅一次） |
| 后续启动（工具已缓存） | ~1.0-1.5s |
| 每次 tool RPC | 毫秒级 |

## Component Design (OakBox Package)

所有 sandbox 组件独立为 `Packages/OakBox/` Swift 包，依赖 OakAgent（使用其 Operations 协议）。

### 1. SandboxVM — VM 生命周期管理

```swift
// Sources/OakAgent/Sandbox/SandboxVM.swift

import Virtualization

/// 管理 Linux micro-VM 的生命周期。
/// 使用 Apple Virtualization.framework，启动一个最小化 Linux guest，
/// 内部配置 OverlayFS 提供沙盒文件操作。
public final class SandboxVM {
    private var vm: VZVirtualMachine?
    private var rpcConnection: SandboxRPCConnection?

    /// VM 配置
    struct Config {
        let kernelPath: URL          // 预编译的 minimal Linux kernel
        let initrdPath: URL          // initramfs with SandboxDaemon
        let memorySize: UInt64       // 默认 128MB
        let cpuCount: Int            // 默认 2
    }

    /// 启动 VM 并挂载 host 目录
    /// - Parameters:
    ///   - hostDirectory: host 上要挂载的目录（只读）
    ///   - config: VM 配置
    /// - Returns: 就绪的 RPC 连接
    public func start(
        hostDirectory: URL,
        config: Config = .default
    ) async throws -> SandboxRPCConnection {
        let vmConfig = VZVirtualMachineConfiguration()

        // CPU + Memory
        vmConfig.cpuCount = config.cpuCount
        vmConfig.memorySize = config.memorySize

        // Boot: Linux kernel + initrd
        let bootLoader = VZLinuxBootLoader(kernelURL: config.kernelPath)
        bootLoader.initialRamdiskURL = config.initrdPath
        // 内核参数：告诉 init 挂载 OverlayFS
        bootLoader.commandLine = "console=hvc0 quiet overlay_tag=hostfs"
        vmConfig.bootLoader = bootLoader

        // Console (for debugging)
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.nullDevice,
            fileHandleForWriting: FileHandle.nullDevice
        )
        vmConfig.serialPorts = [console]

        // Shared directory: host → VM (read-only)
        let sharedDir = VZSharedDirectory(url: hostDirectory, readOnly: true)
        let share = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "hostfs")
        fsConfig.share = share
        vmConfig.directorySharingDevices = [fsConfig]

        // vsock: host ↔ VM RPC 通信
        let vsock = VZVirtioSocketDeviceConfiguration()
        vmConfig.socketDevices = [vsock]

        // Entropy (required for Linux guest)
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        try vmConfig.validate()

        // 启动 VM
        let vm = VZVirtualMachine(configuration: vmConfig)
        self.vm = vm
        try await vm.start()

        // 建立 vsock RPC 连接
        let socketDevice = vm.socketDevices.first!
        let connection = try await SandboxRPCConnection.connect(
            to: socketDevice,
            port: 5000
        )
        self.rpcConnection = connection

        // 等待 VM 内 SandboxDaemon 就绪（OverlayFS 挂载完成）
        try await connection.waitForReady()

        return connection
    }

    /// 停止 VM
    public func stop() async throws {
        try await vm?.stop()
        vm = nil
        rpcConnection = nil
    }

    /// 从 VM 的 upper layer 提取所有变更
    public func extractChanges() async throws -> [FileChange] {
        guard let rpc = rpcConnection else { return [] }
        return try await rpc.getChanges()
    }
}
```

### 2. SandboxRPCConnection — vsock 通信

```swift
// Sources/OakAgent/Sandbox/SandboxRPCConnection.swift

/// 通过 vsock 与 VM 内 SandboxDaemon 通信的 JSON-RPC 客户端。
/// 所有 tool 命令通过这个连接发送到 VM 执行。
public actor SandboxRPCConnection {
    private let connection: VZVirtioSocketConnection

    // MARK: - Tool Execution RPCs

    /// 读取文件内容
    public func readFile(path: String) async throws -> String

    /// 写入文件
    public func writeFile(path: String, content: String) async throws

    /// 检查文件是否存在
    public func fileExists(path: String) async throws -> Bool

    /// 创建目录
    public func createDirectory(path: String) async throws

    /// 删除文件
    public func deleteFile(path: String) async throws

    /// 移动/重命名文件
    public func moveFile(source: String, destination: String) async throws

    /// 复制文件
    public func copyFile(source: String, destination: String) async throws

    /// 列出目录内容
    public func listDirectory(path: String) async throws -> [LsEntry]

    /// 执行 bash 命令（在 OverlayFS merged view 上）
    public func executeBash(
        command: String,
        workingDirectory: String,
        timeout: TimeInterval
    ) async throws -> BashResult

    // MARK: - Sandbox Control RPCs

    /// 等待 VM 内 SandboxDaemon 就绪
    public func waitForReady() async throws

    /// 获取所有文件变更（读取 upper layer diff）
    public func getChanges() async throws -> [FileChange]
}
```

**RPC 协议**: 使用简单的 JSON-RPC over vsock。每个请求：

```json
{"method": "readFile", "params": {"path": "/sandbox/merged/notes/chapter1.md"}}
```

响应：

```json
{"result": "# Chapter 1\n...", "error": null}
```

### 3. VM-Bridged Operations — 桥接到 VM 的 Operations 实现

实现现有的 `FileOperations` / `BashOperations` / `LsOperations` 协议，将调用转发到 VM。

```swift
// Sources/OakAgent/Sandbox/VMFileOperations.swift

/// 将 FileOperations 协议调用桥接到 VM 内执行。
/// 所有路径自动映射：host 路径 → VM 内 /sandbox/merged/ 路径。
public struct VMFileOperations: FileOperations, Sendable {
    let rpc: SandboxRPCConnection
    let hostRoot: URL       // host 上的原始路径 (lowerRoot)
    let vmMergedRoot: String  // VM 内的 merged mount point: "/sandbox/merged"

    public func readFile(at url: URL) throws -> String {
        let vmPath = mapToVM(url)
        // 注意：FileOperations 协议是同步的，需要 bridge
        return try runBlocking { await rpc.readFile(path: vmPath) }
    }

    public func writeFile(content: String, to url: URL) throws {
        let vmPath = mapToVM(url)
        try runBlocking { await rpc.writeFile(path: vmPath, content: content) }
    }

    public func fileExists(at path: String) -> Bool {
        let vmPath = mapToVM(path)
        return (try? runBlocking { await rpc.fileExists(path: vmPath) }) ?? false
    }

    public func createDirectory(at url: URL) throws {
        let vmPath = mapToVM(url)
        try runBlocking { await rpc.createDirectory(path: vmPath) }
    }

    public func deleteFile(at url: URL) throws {
        let vmPath = mapToVM(url)
        try runBlocking { await rpc.deleteFile(path: vmPath) }
    }

    public func moveFile(from source: URL, to destination: URL) throws {
        try runBlocking {
            await rpc.moveFile(source: mapToVM(source), destination: mapToVM(destination))
        }
    }

    public func copyFile(from source: URL, to destination: URL) throws {
        try runBlocking {
            await rpc.copyFile(source: mapToVM(source), destination: mapToVM(destination))
        }
    }

    // MARK: - Path Mapping

    /// host path → VM path
    /// ~/OakReader/storage/abc/notes.md → /sandbox/merged/notes.md
    private func mapToVM(_ url: URL) -> String {
        let relative = url.standardized.path
            .replacingOccurrences(of: hostRoot.standardized.path, with: "")
        return vmMergedRoot + relative
    }

    private func mapToVM(_ path: String) -> String {
        mapToVM(URL(fileURLWithPath: path))
    }
}
```

```swift
// Sources/OakAgent/Sandbox/VMBashOperations.swift

/// 将 bash 命令转发到 VM 内执行。
/// 命令在 OverlayFS merged view 上运行，写入自动隔离到 upper layer。
public struct VMBashOperations: BashOperations, Sendable {
    let rpc: SandboxRPCConnection
    let hostRoot: URL
    let vmMergedRoot: String

    public func execute(
        command: String,
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> BashResult {
        let vmWorkDir = mapToVM(workingDirectory)
        return try await rpc.executeBash(
            command: command,
            workingDirectory: vmWorkDir,
            timeout: timeout
        )
    }
}
```

```swift
// Sources/OakAgent/Sandbox/VMLsOperations.swift

/// 将目录列表转发到 VM 内执行。
/// 返回的是 OverlayFS merged view 的内容（已合并 upper + lower）。
public struct VMLsOperations: LsOperations, Sendable {
    let rpc: SandboxRPCConnection
    let hostRoot: URL
    let vmMergedRoot: String

    public func listDirectory(at url: URL) throws -> [LsEntry] {
        let vmPath = mapToVM(url)
        return try runBlocking { await rpc.listDirectory(path: vmPath) }
    }
}
```

**关键设计：现有 Tool 代码零修改。** `WriteTool`、`BashTool`、`GrepTool`、`FindTool` 等全部通过 `ToolExecutionContext` 中的 Operations 协议透明地在 VM 内执行。`BashTool` 不需要禁用——它的命令在 VM 内 OverlayFS 上自由运行。

### 4. OverlaySandbox — 顶层协调器

```swift
// Sources/OakAgent/Sandbox/OverlaySandbox.swift

/// 协调 VM sandbox 的完整生命周期：
/// 启动 VM → 提供 ToolExecutionContext → 提取变更 → apply/discard。
public final class OverlaySandbox: Sendable {
    private let vm: SandboxVM
    private let rpc: SandboxRPCConnection
    public let hostRoot: URL

    /// 启动 sandbox（创建 VM + 挂载 host 目录 + 配置 OverlayFS）
    public static func create(
        hostDirectory: URL,
        allowedPaths: [URL] = []
    ) async throws -> OverlaySandbox

    /// 供 Agent 使用的 ToolExecutionContext
    /// workingDirectory 仍为 host 路径（PathSandbox 验证在 host 空间）
    /// Operations 实现桥接到 VM
    public var toolContext: ToolExecutionContext {
        ToolExecutionContext(
            workingDirectory: hostRoot,
            allowedPaths: allowedPaths,
            fileOperations: VMFileOperations(rpc: rpc, hostRoot: hostRoot, ...),
            bashOperations: VMBashOperations(rpc: rpc, hostRoot: hostRoot, ...),
            lsOperations: VMLsOperations(rpc: rpc, hostRoot: hostRoot, ...)
        )
    }

    /// 所有现有 Tool 都可用（包括 BashTool、GrepTool、FindTool）
    public var tools: [any AgentTool] {
        ToolKit.allTools() + [MoveTool(), DeleteTool(), CopyTool()]
    }

    /// 提取 VM upper layer 的所有变更
    public func changes() async throws -> [FileChange]

    /// 将选中的变更 apply 到 host 文件系统
    public func apply(acceptedChanges: [FileChange]) throws

    /// 放弃所有变更，关闭 VM
    public func discard() async throws
}
```

**对比用户空间方案的优势：**
- `tools` 包含 **所有 7 个内置 Tool**（包括 BashTool、GrepTool、FindTool），不需要禁用任何工具
- 不需要 whiteout 标记文件，Linux OverlayFS 内核原生处理
- 不需要用户空间的 ChangeManifest actor，直接 diff upper layer 即可

### 5. FileChange — 变更模型（不变）

```swift
// Sources/OakAgent/Sandbox/FileChange.swift

public struct FileChange: Identifiable, Sendable {
    public let id: UUID
    public let type: ChangeType
    public let relativePath: String           // 相对于 hostRoot
    public let overlayData: Data?             // 变更后的文件内容（created/modified）
    public let originalURL: URL?              // host 上的原始路径
    public let movedFromRelativePath: String? // 仅 .moved 类型

    public enum ChangeType: String, Sendable, Codable {
        case created, modified, deleted, moved
    }
}
```

### 6. 变更提取逻辑

VM 内的 SandboxDaemon 在收到 `getChanges` RPC 时，对 upper layer 做 diff：

```bash
# VM init script 中 OverlayFS 的目录结构
/sandbox/lower    ← virtio-fs mount (read-only host dir)
/sandbox/upper    ← OverlayFS upper layer (COW writes)
/sandbox/work     ← OverlayFS workdir (internal)
/sandbox/merged   ← OverlayFS merged view (agent 工作目录)
```

**提取逻辑（SandboxDaemon 内）：**

1. 遍历 `/sandbox/upper` 目录
2. 对每个文件：
   - 是 OverlayFS **whiteout** 文件（`c 0 0` character device）→ `FileChange.deleted`
   - 在 `/sandbox/lower` 中也存在 → `FileChange.modified`
   - 在 `/sandbox/lower` 中不存在 → `FileChange.created`
3. 检测 **opaque directories**（`trusted.overlay.opaque` xattr）→ 目录被重新创建
4. 检测 **redirect directories**（`trusted.overlay.redirect` xattr）→ `FileChange.moved`

OverlayFS 的 whiteout 和 opaque 机制是内核标准，无需自己实现。

### 7. VM Init 进程（SandboxDaemon）

```
# VM initramfs 包含的最小系统
/init              ← 静态链接的 Go/Rust 二进制，musl libc
                     1. mount virtio-fs → /sandbox/lower
                     2. mkdir /sandbox/upper, /sandbox/work, /sandbox/merged
                     3. mount -t overlay overlay \
                          -o lowerdir=/sandbox/lower,upperdir=/sandbox/upper,workdir=/sandbox/work \
                          /sandbox/merged
                     4. 启动 vsock JSON-RPC server (port 5000)
                     5. 接收并执行 tool commands on /sandbox/merged
/bin/busybox       ← 提供 bash, grep, find, mv, cp, rm 等命令
```

Boot 流程：kernel → initrd → /init → mount overlayfs → vsock server ready → 接收 RPC

### 8. 新增 File Management Tools（同时适用两种模式）

扩展 `FileOperations` 协议，添加 `deleteFile` / `moveFile` / `copyFile`：

```swift
// Operations/FileOperations.swift — 修改

public protocol FileOperations: Sendable {
    // 现有
    func readFile(at url: URL) throws -> String
    func writeFile(content: String, to url: URL) throws
    func fileExists(at path: String) -> Bool
    func createDirectory(at url: URL) throws
    // 新增
    func deleteFile(at url: URL) throws
    func moveFile(from source: URL, to destination: URL) throws
    func copyFile(from source: URL, to destination: URL) throws
}
```

新增 `MoveTool`、`DeleteTool`、`CopyTool`，遵循 `WriteTool` 的模式。这些 Tool 在普通模式（LocalFileOperations）和 sandbox 模式（VMFileOperations）下都可用。

## Integration: ChatViewModel

### 新增属性

```swift
var sandboxMode: Bool = false
var activeSandbox: OverlaySandbox?
var pendingChanges: [FileChange] = []
var showChangeReview: Bool = false
```

### send() 中的 sandbox 分支

```swift
// sandbox 模式时：
let sandbox = try await OverlaySandbox.create(
    hostDirectory: storagePath,
    allowedPaths: [storagePath]
)
self.activeSandbox = sandbox

// 使用 sandbox 的 context（所有操作桥接到 VM）
let effectiveToolContext = sandbox.toolContext

// 所有 Tool 都可用（包括 BashTool）
let effectiveTools = sandbox.tools + documentTools
```

### Stream 结束后

```swift
if let sandbox = activeSandbox {
    let changes = try await sandbox.changes()
    if !changes.isEmpty {
        self.pendingChanges = changes
        self.showChangeReview = true
    } else {
        try await sandbox.discard()
        self.activeSandbox = nil
    }
}
```

### Review 操作

```swift
func acceptChanges(_ accepted: Set<UUID>) {
    guard let sandbox = activeSandbox else { return }
    let toApply = pendingChanges.filter { accepted.contains($0.id) }
    try? sandbox.apply(acceptedChanges: toApply)
    Task { try? await sandbox.discard() }
    activeSandbox = nil
    pendingChanges = []
    showChangeReview = false
}
```

## File Change Confirmation（核心用户体验）

这是整个 sandbox 方案的核心价值——和 Bridge 一样，**Agent 的所有文件修改必须经过用户确认才会应用到真实文件系统**。

### 确认流程

```
Agent 执行中                    Agent 完成
    │                              │
    │  所有操作在 overlay 中       │  提取 upper layer diff
    │  原始文件完全不受影响         │
    │                              ▼
    │                     ┌──────────────────┐
    │                     │ ChangeReviewView  │
    │                     │                  │
    │                     │ ☑ notes/ch1.md   │ modified (橙)
    │                     │ ☑ notes/ch2.md   │ created  (绿)
    │                     │ ☐ tmp/draft.md   │ created  (绿)  ← 用户不想要中间文件
    │                     │ ☑ old/legacy.md  │ deleted  (红)
    │                     │ ☑ a.md → b.md    │ moved    (蓝)
    │                     │                  │
    │                     │ [Discard All] [Accept Selected] │
    │                     └──────────────────┘
    │                              │
    │                     用户选择后
    │                              ▼
    │                     Apply 选中的变更到真实文件系统
    │                     Discard VM / 清理 overlay
```

### 关键原则

1. **Agent 执行期间原始文件零修改** — 所有写入都在 overlay（VM upper layer 或用户空间 upper dir）
2. **完成后必须 review** — 不存在 "自动应用" 选项，这是安全底线
3. **选择性接受** — 用户可以只接受最终结果，不接受中间产物（如临时文件、备份文件）
4. **变更可预览** — modified 文件展示 diff，deleted 文件标红确认，moved 文件显示 from → to

### ChangeReviewView

```swift
// Views/Chat/ChangeReviewView.swift

struct ChangeReviewView: View {
    let changes: [FileChange]
    @State private var selectedChanges: Set<UUID>  // 默认全选
    let onAccept: (Set<UUID>) -> Void
    let onDiscardAll: () -> Void
}
```

UI 结构：
- 文件变更列表，每项带 checkbox
- 类型标记：created (绿) / modified (橙) / deleted (红) / moved (蓝)
- moved 类型显示 `from → to` 路径
- modified 类型可展开查看 unified diff
- 底部操作栏：Select All / Select None / Discard All / Accept Selected

通过 `.sheet(isPresented: $chatViewModel.showChangeReview)` 从 AIChatView 触发。

## Bundled Resources

需要随 app 打包的 VM 资源：

| 资源 | 大小估算 | 说明 |
|------|----------|------|
| Linux kernel (ARM64) | ~15MB | 最小化配置，仅需 virtio-fs + overlayfs + vsock |
| initramfs | ~5MB | SandboxDaemon + busybox (静态链接) |
| **总计** | **~20MB** | 添加到 app bundle |

Apple 的 Containerization 框架使用 Kata Containers 的 Linux kernel (ARM64 v3.17.0) + 自研 vminitd (musl libc 静态链接)。我们可以采用类似方案，或直接复用其开源组件。

## File Summary

### 新建文件

| 文件 | 位置 | 说明 |
|------|------|------|
| `SandboxVM.swift` | `OakAgent/Sandbox/` | VM 生命周期管理 (Virtualization.framework) |
| `SandboxRPCConnection.swift` | `OakAgent/Sandbox/` | vsock JSON-RPC 客户端 |
| `VMFileOperations.swift` | `OakAgent/Sandbox/` | FileOperations → VM bridge |
| `VMBashOperations.swift` | `OakAgent/Sandbox/` | BashOperations → VM bridge |
| `VMLsOperations.swift` | `OakAgent/Sandbox/` | LsOperations → VM bridge |
| `OverlaySandbox.swift` | `OakAgent/Sandbox/` | 顶层协调器 |
| `FileChange.swift` | `OakAgent/Sandbox/` | 变更模型 |
| `MoveTool.swift` | `OakAgent/Tools/` | 移动/重命名 |
| `DeleteTool.swift` | `OakAgent/Tools/` | 删除文件 |
| `CopyTool.swift` | `OakAgent/Tools/` | 复制文件 |
| `ChangeReviewView.swift` | `OakReader/Views/Chat/` | Review UI |
| `sandbox-init/` | `Resources/` | VM init 进程源码 + 预编译 kernel |

### 修改文件

| 文件 | 修改内容 |
|------|----------|
| `FileOperations.swift` | 协议新增 deleteFile/moveFile/copyFile |
| `ToolKit.swift` | 添加 `sandboxTools()` 工厂方法 |
| `ChatViewModel.swift` | 新增 sandbox 属性、send() sandbox 分支、review 操作方法 |
| `AIChatView.swift` | 添加 `.sheet` 触发 ChangeReviewView |

## Implementation Phases

### Phase 1: VM sandbox 核心
1. 准备 minimal Linux kernel + initramfs (SandboxDaemon)
2. 实现 `SandboxVM` (Virtualization.framework)
3. 实现 vsock JSON-RPC 通信 (`SandboxRPCConnection`)
4. 实现 VM-bridged Operations (`VMFileOperations`, `VMBashOperations`, `VMLsOperations`)
5. 实现 `OverlaySandbox` 协调器
6. 变更提取逻辑（diff upper layer）

### Phase 2: Tools + Integration
1. 扩展 `FileOperations` 协议
2. 实现 `MoveTool`, `DeleteTool`, `CopyTool`
3. `ChatViewModel` sandbox 模式集成
4. `ChangeReviewView` UI

### Phase 3: Polish
1. VM 资源打包 (kernel + initramfs in app bundle)
2. VM 启动优化（预热/缓存）
3. 错误处理（VM 崩溃恢复、timeout）
4. modified 文件的 diff 预览

## Open Questions

1. **SandboxDaemon 语言**: Go (静态链接简单) vs Rust (更小的二进制) vs Swift (统一技术栈但静态链接困难)?
2. **VM 预热**: 是否在 app 启动时预启动 VM 来消除 0.7s 延迟？还是按需启动？
3. **同步 ↔ 异步桥接**: `FileOperations` 协议方法是同步的，但 VM RPC 是 async 的。`runBlocking` 实现需要避免死锁（不能在 MainActor 上阻塞）。是否改造协议为 async？
4. **多目录挂载**: 是否需要同时挂载多个 host 目录（如 storage + notes）？`VZMultipleDirectoryShare` 支持这个。
5. **App Sandbox 兼容**: Virtualization.framework 需要 `com.apple.security.virtualization` entitlement。是否与 App Sandbox 兼容？
