# 手机截图自动上绳 — 设置指南

两条路都能把 iPhone 截图送上 Tendedero Dev 的晾衣绳，全部本地、无需任何第三方服务账号。

---

## 路线 C：`tendedero` CLI（已随本仓库构建好）

CLI 通过 **spool 指针文件** 与运行中的 Tendedero Dev 通信：往
`~/Library/Application Support/Tendedero Dev/Spool` 写入一个 `.tendedero`
指针（内容是原文件的绝对路径），App 侧的 `SpoolWatcher` 读到后就挂绳，
然后删掉指针。**原文件不移动、不复制**——挂上的是"外部文件"，从绳上取下
不会删除原文件，与"Also watch folders"语义一致。

### 安装

```sh
cd /Users/wang/Code/Tendedero
swift build -c release --product tendedero-cli
sudo cp .build/release/tendedero-cli /usr/local/bin/tendedero   # 可选
```

### 用法

```sh
tendedero hang ~/pic.png             # 挂一张图
tendedero hang *.png                 # 挂多张
tendedero hang --dir ~/Downloads     # 挂文件夹里所有图片（不递归）
tendedero list                       # 打印 spool 目录路径
tendedero hang --app official x.png  # 发给官方版而非开发版
```

### 端到端验证

```sh
open "build/Tendedero Dev.app"       # 或 /Applications/Tendedero Dev.app
tendedero hang /path/to/any.png      # 绳子落下，图片挂上
```

注意事项：
- 第一次会向终端/App 申请 Application Support 权限，同意即可。
- App 未运行时指针会留在 Spool 里，App 下次启动会补挂（`SpoolWatcher.start()` 首次 drain）。
- CLI 目标哪个 App 由 `--app` 决定，默认 `dev`。

---

## 路线 A：iCloud Drive 中转（手机 → Mac）

1. **Mac 端**：在 Tendedero Dev 菜单栏里选 "Also watch folders"，添加
   `~/Library/Mobile Documents/iCloud~com~apple~CloudDocs/Tendedero`
   （文件夹会自动创建为空；iCloud 文件按需下载时 macOS 会先拉取再触发）。
2. **iPhone 端**：快捷指令 App → 自动化 → **"截屏时"（When screenshot is taken）**：
   - 动作 1：`获取最新截图`
   - 动作 2：`存储文件` → 目标 `iCloud Drive/Tendedero`，关闭"询问存储位置"
3. 以后每次手机截图，几秒后自动出现在 Mac 晾衣绳上。

隐私提示：文件会经过 iCloud 云端（与 Tendedero "纯本地"哲学的差异由你权衡；
AirDrop 路线见下文则完全不经云端）。

## 路线 B（备选）：AirDrop → Downloads 过滤

AirDrop 到 Mac 落在 `~/Downloads`。若想让"只有真截图"上绳，可以在
`AppDelegate.extraFolders` 里加入 Downloads，并给 `ScreenshotWatcher` 传入
"仅带 `kMDItemIsScreenCapture` 扩展属性或 `IMG_####` 命名的文件" 的谓词
（`isScreenCapture` 已存在，改动约 30 行，尚未实现——需要时说一声）。

---

## 本次改动清单

| 文件 | 改动 |
|:--|:--|
| `Sources/Tendedero/SpoolWatcher.swift` | 新增：监视 Spool，读指针→挂绳→删指针 |
| `Sources/Tendedero/AppDelegate.swift` | `startWatcher()` 里启动 spool watcher |
| `Sources/Tendedero/ScreenshotWatcher.swift` | 暴露 `isImageURL(_:)` 供 spool 复用 |
| `Sources/tendedero-cli/main.swift` | 新增：CLI（hang / hang --dir / list） |
| `Package.swift` | 新增 `tendedero-cli` target |

`swift build -c release --disable-sandbox` 通过；App 已组装为
`build/Tendedero Dev.app`（arm64，ad-hoc 签名）。安装：
`cp -R "build/Tendedero Dev.app" /Applications/`（注意 Xcode SDK 构建脚本
的沙箱问题——本机直接 `swift build --disable-sandbox` 即可）。
