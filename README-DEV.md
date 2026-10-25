# Tendedero Dev — 顶部中间悬停版

这是基于 [alejandrobujan/tendedero](https://github.com/alejandrobujan/tendedero) v1.6.0 的个人二次开发版。它作为独立的 **Tendedero Dev** 构建，不会覆盖或修改你正在使用的原生 `/Applications/Tendedero.app`。

## 交互改动

### 1. 顶部正中间触发，而不是整条菜单栏

![小拉锁提示](docs/images/dev-hint.png)

刘海锚点的模拟渲染（当前主屏无刘海，运行时回退到顶部中央）：

![刘海锚点模拟](docs/images/dev-hint-notch.png)

- 热区是屏幕顶部正中间的一块区域：宽约 320 pt，从屏幕最上沿向下约 144 pt。
- **小拉锁**：提示是一道从菜单栏/刘海下沿垂下的竖直拉链，底部是拉链头和带环孔的拉片。没有文字、目标线或玻璃背板。
- **拉动物理动画**：
  - 鼠标往上推，拉链头沿中缝上升，齿牙逐颗分开，中缝下方漏出越来越亮的暖色光。
  - 拉片会随拉动摆动：拉到中间时偏向一侧（约 8°），到顶回正；绷直瞬间再轻轻回弹。
  - 光晕跟随拉链头，色相随进度从青绿过渡到橙色。
- **刘海锚点**：在带刘海的 Mac 上，拉链从刘海下沿的黑色锚点垂出来；没有刘海的屏幕自动回退到顶部中央。
- **触觉两段式**：
  - 拉到 50%（拉链半开）触发一次较软的定位点（alignment）。
  - 到 100%（拉链完全打开）触发更强的 levelChange，闪光后主晾衣架落下。
- 提示尺寸约 **64 × 150**；触觉依赖 Force Touch 触控板，没有支持的设备时不影响视觉和交互。
- 拉链的中缝和齿牙都有深色描边，叠在浅色浏览器标题栏上也能看清。
- 到顶后先轻微回弹并闪一圈暖色光环，约 0.18 秒后主晾衣架落下，形成“啪”一下的断开感。
- 鼠标在热区边缘小幅不确定移动时不会闪：提示出现后使用扩大 14 pt 的保持区和 0.12 秒离开宽限；进度做了低通平滑，微小抖动不会让拉链发抖或反复显示/隐藏。
- 进入顶部拉链区域时，光标换成自定义的**上拉箭头**（2× Retina 位图）；鼠标移到照片上则变成**手形光标**。离开区域、唤醒、收绳或鼠标进入菜单栏其他位置时立刻恢复系统光标。
- 空绳时不显示拉链提示，避免没有内容可拉。
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
| `Sources/Tendedero/HoverHintPanel.swift` | 顶部中央的小拉锁提示、拉链动画、自定义光标 |
| `Sources/Tendedero/GrabArea.swift` | 双击复制、中键删除、右键原生菜单、拖拽 |
| `Sources/Tendedero/PeggedView.swift` | 鼠标悬停到具体图片时记录 `hoveredID` |
| `Sources/Tendedero/HotKey.swift` | 多快捷键 Carbon 注册、删除快捷键、录制器 |
| `Sources/Tendedero/AppIdentity.swift` | 开发版 / 原生版身份与数据目录 |
| `scripts/build-dev.sh` | 独立开发版构建入口 |

## 已验证

- `swift build -c release` 通过，无编译警告；
- `swift scripts/check-strings.swift` 通过（11 种语言，65 条字符串）；
- 通用二进制（arm64 + x86_64）构建、ad-hoc 签名通过；
- 小拉锁的拉链头随指针上移，齿牙逐颗分开、中缝光变亮；拉片摆动，接近阈值时转橙。
- 边缘抖动保护：在热区边缘来回抖动时提示 alpha 始终为 1；离开较远约 0.35 秒后才隐藏，重新进入立即恢复。
- 刘海锚点：当前主屏无刘海，运行时正确回退到顶部中央；刘海状态下的黑色锚点和拉链形态已用模拟渲染检查。
- 在 2048 × 1152 屏幕上，指针移到顶部正中：
  - 进入 144 pt 热区：只出现约 `64 × 150` 的小拉锁，alpha = 1，晾衣架不出现；
  - 停留在热区中段（例如指针 y=60）：拉链半开，触发 50% 触觉定位点，晾衣架始终不出现；
  - 指针在提示出现后继续上移并到达最上沿：拉链完全打开，回弹/闪光约 0.18 秒，然后提示窗隐藏、晾衣绳展开（实测从 snap 开始到主绳展开约 0.21 秒）；
  - 触觉日志验证：50% 处 `detent stage1` 一次，到顶 `detent snap` 一次；实际手感需要 Force Touch 触控板。
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
