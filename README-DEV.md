# Tendedero Dev — 顶部中间悬停版

这是基于 [alejandrobujan/tendedero](https://github.com/alejandrobujan/tendedero) v1.6.0 的个人二次开发版。它作为独立的 **Tendedero Dev** 构建，不会覆盖或修改你正在使用的原生 `/Applications/Tendedero.app`。

## 交互改动

### 1. 顶部正中间触发，而不是整条菜单栏

![顶部中间提示气泡](docs/images/dev-hint.png)

- 热区是屏幕顶部正中间的一块区域：宽约 320 pt，从屏幕最上沿向下约 96 pt。
- 指针进入热区后**只出现提示气泡，不会立即放下晾衣架**：
  - 有图片时：`晾衣绳上有 3 张 · 继续向上唤醒` + 向上箭头
  - 空绳时：`截图后会挂在这里`
- 提示会**跟随鼠标向上移动**，而不是按时间自动爬升；鼠标停在中间，提示就停在中间，晾衣架始终不出现。
- 提示底部有一条**阈值进度条**：它按 96 pt 的上移行程填充，鼠标越往上填充越多；接近阈值时进度条变亮、向上箭头轻微放大，填满并到达最上沿才唤醒。
- 只有提示出现后鼠标**继续向上移动**（哪怕一小段），并且到达**屏幕最上沿**，才唤醒晾衣架；随后提示消失、绳子落下。
- 没有“等几秒自动展开”的逻辑。鼠标不继续上移，就不会展开。
- 菜单栏其他位置（Apple 菜单、状态图标、时钟等）不会触发。
- 可在菜单栏「放下晾衣绳」里开关「指针停在顶部正中间时」。
- 原有快捷键、菜单「显示晾衣绳」、全屏 App 上的行为、空绳逻辑都保留。

### 2. 悬挂图片上的鼠标 / 键盘操作

| 操作 | 行为 |
|:--|:--|
| 单击 | 快速预览（系统 Quick Look）；等待系统双击间隔后触发，避免和双击冲突 |
| 双击 | 复制图片（写入 PNG + 文件 URL，显示 `Copied`） |
| 中键（滚轮按下） | 快速取下指针下的图片 |
| `⌃⌥⌫` | 删除指针下的图片；快捷键可在「鼠标 → 删除悬停的图片」里改 |
| 单击（可选） | 菜单「鼠标 → 单击即复制」打开后，单击改为复制，不再预览 |
| 右键 | 完全保留原生菜单（复制 / 打开 / 快速查看 / 标记 / 在 Finder 中显示 / 保存到桌面 / 取下 / 移到废纸篓 / 清理左右两侧） |
| 长按 | 原生 Markup |
| 力度点按 | 原生 Quick Look |
| 拖拽 | 原生拖拽；拖进文件夹保留文件，拖进废纸篓删除 |
| 左上角叉号 | 原生取下 / 废纸篓语义 |

「快速取下 / 删除」沿用原生 `discard` 语义：

- 图片在 Tendedero 接管的截图文件夹里：移到废纸篓；
- 图片在桌面、下载或其他被监视文件夹里：只从晾衣绳上取下，不删除原文件。

这样中键和快捷键不会误删用户自己的外部文件。

### 3. 独立身份，便于与原生版共存

| | 原生版 | 开发版 |
|:--|:--|:--|
| App | `/Applications/Tendedero.app` | `/Applications/Tendedero Dev.app` |
| Bundle ID | `app.tendedero.Tendedero` | `app.tendedero.Tendedero.dev` |
| 偏好 | `app.tendedero.Tendedero` | `app.tendedero.Tendedero.dev` |
| 截图接管目录 | `~/Library/Application Support/Tendedero/Screenshots` | `~/Library/Application Support/Tendedero Dev/Screenshots` |
| 源码 | 上游 release | 本仓库 `top-center-hover` 分支 |

> 两个版本可以同时安装。但两者都监听截图/悬停时会出现两条绳子：
> - 建议在使用开发版时，退出原生版；或在原生版菜单里关掉「指针停在菜单栏时」；
> - 「接管截图」（Handle screenshots）同一时间只应有一个 App 开启，否则系统截图目录会被来回切换；
> - 如果原生版正在接管截图，开发版会监视同一个文件夹，但把文件视为「外部文件」：中键/快捷键删除只会从绳子取下，不会删文件。这是为了避免误删原生版的数据。

## 构建

需要 Swift 工具链（Xcode 或 Command Line Tools），macOS 14+。

```sh
cd /Users/wang/Code/Tendedero
scripts/build-dev.sh
open "build/Tendedero Dev.app"
```

本次已经安装一份到 `/Applications/Tendedero Dev.app`，与原生 `/Applications/Tendedero.app` 并存。

构建脚本会：

1. 编译 arm64 + x86_64 通用二进制；
2. 生成图标和本地化资源；
3. 写入独立 Info.plist（`app.tendedero.Tendedero.dev`）；
4. 本机 ad-hoc 签名，输出 `build/Tendedero Dev.app`。

正式版构建仍可用：

```sh
scripts/build-app.sh
```

## 关键代码位置

| 文件 | 作用 |
|:--|:--|
| `Sources/Tendedero/AppDelegate.swift` | 顶部中间热区、延迟状态机、提示窗显隐、快捷键与菜单 |
| `Sources/Tendedero/HoverHintPanel.swift` | 菜单栏下方的玻璃提示气泡 |
| `Sources/Tendedero/GrabArea.swift` | 双击复制、中键删除、右键原生菜单、拖拽 |
| `Sources/Tendedero/PeggedView.swift` | 鼠标悬停到具体图片时记录 `hoveredID` |
| `Sources/Tendedero/HotKey.swift` | 多快捷键 Carbon 注册、删除快捷键、录制器 |
| `Sources/Tendedero/AppIdentity.swift` | 开发版 / 原生版身份与数据目录 |
| `scripts/build-dev.sh` | 独立开发版构建入口 |

## 已验证

- `swift build -c release` 通过，无编译警告；
- `swift scripts/check-strings.swift` 通过（11 种语言，66 条字符串）；
- 通用二进制（arm64 + x86_64）构建、ad-hoc 签名通过；
- 提示底部进度条随指针上移平滑填充；接近阈值时箭头放大、进度条变亮。
- 在 2048 × 1152 屏幕上，指针移到顶部正中：
  - 进入 96 pt 热区：只出现提示窗 `(884, 36)`、约 `280 × 44`、alpha = 1，晾衣架不出现；
  - 停留在热区中段（例如指针 y=60）：提示停在 `(884, 30)` 左右，进度条约 38%，晾衣架始终不出现；
  - 指针在提示出现后继续上移并到达最上沿：提示窗上移到 `(884, 20)` 左右，进度条填满，随后隐藏，晾衣绳展开；
  - 指针移开后 0.5 秒收绳，面板 `orderOut` 后 `isVisible = false`；
- 事件自检结果：`single=true double=true middle=true`（单击延迟判定、双击取消单击、中键删除均通过）；
- 快捷键注册：显示快捷键与 `⌃⌥⌫` 删除快捷键均注册成功。

> 系统级合成鼠标点击需要「辅助功能」权限。本机终端未授予该权限，因此单击预览、双击复制与中键删除的**事件派发**已用应用内自检验证，真实鼠标点击请在运行中的 App 上确认。

## 回退

```sh
cd /Users/wang/Code/Tendedero
git checkout main
scripts/build-app.sh
```

原生 `/Applications/Tendedero.app` 始终未被修改。
