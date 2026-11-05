# Tendedero Dev — 顶部中间悬停版

这是基于 [alejandrobujan/tendedero](https://github.com/alejandrobujan/tendedero) 的个人二次开发版（已同步上游到 v1.8.1）。它作为独立的 **Tendedero Dev** 构建，不会覆盖或修改你正在使用的原生 `/Applications/Tendedero.app`。

## 交互改动

### 1. 顶部正中间触发（无动画版）

- 热区是屏幕顶部正中间的一块区域：宽约 320 pt，从屏幕最上沿向下约 144 pt。
- 没有任何提示动画和面板：指针进入热区后向上移动并到达屏幕最上沿，晾衣绳直接落下。
- 落下瞬间播放一声短促的系统提示音（Tink）并触发一次触觉反馈；可在菜单栏里关闭声音。
- 空绳时不触发。菜单栏其他位置（Apple 菜单、状态图标、时钟）不会触发。
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
| 滚轮下拉 / 双指下滑 | 把指针下的图片「拿在手上」（见下一节） |
| 左上角叉号 | 原生取下 / 废纸篓语义 |

「快速取下 / 删除」沿用原生 `discard` 语义：

- 图片在 Tendedero 接管的截图文件夹里：移到废纸篓；
- 图片在桌面、下载或其他被监视文件夹里：只从晾衣绳上取下，不删除原文件。

这样中键和快捷键不会误删用户自己的外部文件。

### 3. 滚轮下拉「拿在手上」

- 指针停在绳上某张图片上，**滚轮向下滑 / 触控板双指下滑**（方向按设备判定，不受「自然滚动」开关影响）：图片从绳上滑落，边下滑边放大到屏幕中间，动画是一条连续的曲线，没有分段停顿；
- 不会误触：下拉累计超过 30 pt 才触发，且需要指针正停在某张图上。

拿在手上的图片：

| 操作 | 行为 |
|:--|:--|
| 拖动 | 移动位置（一直如此，文字上也可以） |
| 左上角「识别文字」按钮 | 打开/关闭 OCR：打开后淡淡高亮全部可识别文字，在文字上拖动即可框选，选中为蓝色 |
| `C`（指针在图内） | 复制整张图片，**留在手上**，不回到绳上 |
| `C` + 双击 | 复制整张图片并放回绳上 |
| `⌥` + 双击 | 同上（保留旧手势） |
| 双击 | 放回绳上，沿原路飞回它原来的位置 |
| `⌘C` | 有选中文字时复制选中文字；否则复制整张图片 |
| 拖动四角 / 边 | 缩放（保持照片比例） |
| `⌘` + 滚轮 / 双指捏合 | 以指针为中心缩放 |
| 滚轮向上 / 双指上滑 | 放回绳上 |
| `Esc` | 先取消文字选中；没有选中时放回绳上 |
| **按住不放 2.5 秒** | 图片缩小成**文件缩略图**：按住时指针周围有进度环，松手前完成 |
| 缩略图形态 | 拖动＝把文件拖到别的 App / 访达；`C` 或 `⌘C` ＝复制文件；右键「分享」；双击＝变回大图；滚轮向上 / `Esc` / 右键＝放回绳上 |

绳上留下半透明的痕迹，点它也能放回；手上的图片是置顶且随时可用的，不会把当前 App 切走。

### 4. 接管桌面截图，并排成队列

macOS 默认把截图放在桌面。本版默认**接管**这个动作：

- 首次运行时把系统截图位置（`location` / `location-screenshot` / `location-screenrecording`）指到 App 自己的目录，并关闭浮动缩略图，截图落盘后立刻挂到绳上；
- 仍在桌面生成的截图（系统设置被别处改回、或用其他工具存的）也会被**移入**这个目录，桌面保持干净；
- App 没运行时落在桌面的截图，下次启动时按上次退出时间一并收进队列；
- 目录是**队列**：每张新图进队，队满时最旧的出队（移到废纸篓），容量与晾衣绳的「Keep on line」一致（默认可放下几张就存几张，设了 Keep on line 就是 25/50/100）；
- 退出 App 时把系统设置还回去，不留下没人看管的截图目录。

可在菜单栏「Handle screenshots」里整体关掉。

### 5. 独立身份，便于与原生版共存

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
| `Sources/Tendedero/AppDelegate.swift` | 顶部中间热区、截图接管、队列进出、快捷键与菜单 |
| `Sources/Tendedero/Inbox.swift` | 截图接管目录、队列容量与出队、桌面截图收编 |
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

## 同步 iPhone 截图（一键开关）

菜单栏「同步 iPhone 截图」打开后，App 自动监视 iCloud Drive 里的
`Tendedero` 文件夹（不存在会自动创建）。手机端只需设置一次快捷指令自动化：

1. 快捷指令 App → 自动化 → 新建 →「截屏时」（When screenshot is taken）
2. 动作：获取最新截图 → 存储文件 → iCloud Drive/Tendedero，关闭「询问」
3. 完成。之后每张手机截图都会自动挂上 Mac 的晾衣绳。

取下不会删除 iCloud 里的原文件；iCloud 没同步下来时图片会暂时从绳上消失。
