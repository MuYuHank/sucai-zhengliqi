# 素材整理器

> **自用工具，仅供个人使用。** 只在作者自己的 Mac（Apple M4、macOS 26.4、Command Line Tools + Swift 6.3）上构建和测试过，**不确定在其他 Mac 型号、系统版本或环境下能否正常使用**，不提供任何保证与支持。应用内显示名称为「产物整理器」。

---

# 产物整理器

菜单栏里的本地 macOS 工具。它扫描你指定的文件夹，把视频、图片、产品交付物、网页和 SEO/GEO 文件整理进桌面上的一套目录，并给每次移动留下可以撤回的记录。

界面是中文。分类、版本滚档、规则、发布匹配、重命名、SQLite 搜索、交付清单和周报都在 `OrganizerCore` 里，Linux 上可以用 `swift test` 验证。窗口、菜单栏、FSEvents、全局快捷键、AVFoundation 和钥匙串只在 macOS 目标里。

## 它会在产物库里建什么

产物库默认是「桌面」，路径可以在设置里改。

```text
社媒/视频/视频发布/     已经在 TikTok、YouTube 或 Facebook 发布
社媒/视频/视频待发布/   还没发布的成片
社媒/图片/图片成品/     AI 图和设计导出。截图不进这里
社媒/图片/截图/
社媒/音频/
产品/<项目>/            安装包、交付压缩包、设计源文件。最新版本留在这里
产品/<项目>/历史版本/   较旧的 v1、v2、r15、final、日期
网站相关/网站维护/      html / css / js
网站相关/SEO GEO/       sitemap、llms.txt、schema、关键词和审计
待删/                   渲染帧、缓存、日志、旧副本。只是归档，不会删除
其他/
产物整理器报告/         每周日的 Markdown
```

这些相对路径都可以在设置里改。

## 它会做什么

1. 扫描你选的文件夹，以及下载、桌面、文稿、`.codex`、Projects、Developer、`.cursor`。跳过 `node_modules`、`.git`、缓存目录、`.app` 和任何叫 `Library` 的目录。
2. 按扩展名、路径、文件名、大小、同级文件和元数据判断：成片、渲染帧、截图、日志、缓存、压缩包、AI 图、设计源文件、安装包、网页、SEO/GEO。密钥样子的文件（`.env`、`api_key`、`credentials`）留在原地。`keyframe` 不当成密钥。
3. 发布匹配。可以导入 CSV/JSON，也可以用你自己的 Client ID 走 YouTube、TikTok、Facebook 的官方 OAuth。匹配用标题相似度、时长和画面感知哈希。匹配上的进「视频发布」，并记下平台和日期；其余成片进「视频待发布」。
4. 同一产品的版本会滚档：最新的留在产品目录，更旧的进「历史版本」。搜索里能看到整段历史。
5. 预览里看清「从哪到哪、为什么」之后才移动。同卷用 `rename`。跨卷不会复制，因为真正的移动要删掉源文件，而这个工具不删除。重名会加成片_2026-11-16.mp4，还撞就再加时间。
6. 归档写进产物库的 `.chanwu/index.sqlite`。可以按原名、现名、类型、项目、日期、平台、发布状态、版本和路径搜索。点一下用访达打开。⌥⌘O 弹出搜索。
7. 监视新文件。安静一会儿、大小不再变，才进入待确认。菜单栏图标显示待确认数量。
8. 「报告」里列出最大的文件，以及渲染帧、历史版本、缓存、日志占了多少。只是建议，不删除。
9. 预览里有图片和视频缩略图。视频可以拖进度条，或把指针停在画面上看某一帧。
10. 待发布超过设定天数（默认 14）会在报告里提醒。
11. 路径或文件名里的 FCCV1、案头、YUUKI 会自动成为项目标签，也可以自己加。
12. 按项目标签把最新版本打成 zip，里面有 `清单.json`（路径、大小、SHA256）。
13. `image_1234.png`、`output (3).mp4` 这类名字会改成「项目_内容_日期」。原名留在索引里，还能搜到。可选本地模型，默认关闭。
14. 菜单栏「产物」显示今日归档和待确认，并能打开搜索、扫描、撤回上次。
15. 设置里可以写规则：名称包含、扩展名、路径包含，按顺序套用，存成 JSON。
16. 每周日把产出、归档、发布、待发布写成 Markdown，放在桌面的「产物整理器报告」。应用里也能看。

每个产物库的第一次确认只演练，不移动文件。

## 安全

- 没有删除、清空废纸篓或覆盖已有文件。
- 不碰系统目录、`~/Library`、`.app`、`.git`。
- 不会把产物库的目录移进它自己里面。已经在「社媒」「待删」「网站相关」里的文件不会再被扫出来搬一次。产品目录会参加版本滚档。
- 正在写入的文件要等大小稳定后才进入待确认。
- 看起来像密钥的文件只记录一句「未改动」。

偏好在 `~/.chanwu/preferences.json`，桌面结构和规则在 `~/.chanwu/desk.json`，导入的发布列表在 `~/.chanwu/published.json`。快捷键、安装标识和平台令牌优先放钥匙串。

## 第一次使用

1. 打开应用。它是菜单栏程序，Dock 里没有图标。点菜单栏「产物」。
2. 核对产物库（默认桌面）和扫描位置。
3. 点「按这个结构开始」。
4. 点「开始扫描」，看预览。第一次点确认只是演练。
5. 再确认一次才会真正移动。记录页或菜单栏「撤回上次」可以撤回去。

## 在 Linux 上验证核心

需要 Swift 6.3.3 和系统的 `libsqlite3`。不需要 macOS SDK。

```bash
swift test
swift build --product chanwu
swift package describe
./scripts/make_app.sh
```

`swift package describe` 在 Linux 上不应该出现 `ChanwuApp`。`./scripts/make_app.sh` 会直接退出。

```bash
swift run chanwu scan --root ~/Downloads --library ~/Desktop
swift run chanwu apply --library ~/Desktop --confirm
swift run chanwu apply --library ~/Desktop --confirm
swift run chanwu index --library ~/Desktop --query 案头
swift run chanwu runs --library ~/Desktop
swift run chanwu undo --library ~/Desktop --run <记录ID>
swift run chanwu pack --library ~/Desktop --project FCCV1 --output ~/Desktop/FCCV1-交付.zip
swift run chanwu report --library ~/Desktop --desktop ~/Desktop --write
```

第一次 `apply --confirm` 是演练。省略 `--confirm` 会拒绝，并且不会动文件。

## 在 Mac 上构建和安装

目标机器是 Apple M4、macOS 26.4、Command Line Tools 里的 Swift 6.3.3。不要用 `xcodebuild`。链接系统的 `libsqlite3`，Command Line Tools 里就有。

```bash
swift test
./scripts/make_app.sh
open "dist/产物整理器.app"
```

脚本还会写出 `dist/产物整理器.zip`。

```bash
./scripts/make_app.sh --install
INSTALL_DIR="$HOME/Applications" ./scripts/make_app.sh --install
./scripts/make_app.sh --debug --open
```

脚本会确认系统是 macOS、包里有 `ChanwuApp`，然后 `swift build -c release --product ChanwuApp`，组装 `dist/产物整理器.app`（`LSUIElement`，菜单栏应用，bundle id `app.chanwu.organizer`），ad-hoc 签名，再用 `ditto` 打 zip。

第一次打开若被 Gatekeeper 拦住，在访达里按住 Control 点「打开」。从浏览器下载的副本还可以：

```bash
xattr -dr com.apple.quarantine "dist/产物整理器.app"
```

扫描桌面、文稿、下载时，系统会按这个 bundle id 要文件权限。到「系统设置 → 隐私与安全性 → 文件与文件夹」允许「产物整理器」。

## 怎么连各个平台

不连也能用。把已发布列表贴进设置，或选一个 CSV/JSON 文件的内容。CSV 表头可以是 `标题,时长,发布日期,编号,平台`。

要走官方接口时，先在对应开发者后台建一个应用，把回调地址设成 `http://127.0.0.1:8765/callback`：

1. YouTube：Google Cloud 里启用 YouTube Data API，OAuth 范围是 `youtube.readonly`。把 Client ID 填进设置，Client Secret 点「保存 YouTube 密钥」（进钥匙串，不进 JSON）。
2. TikTok：Login Kit / Display API，范围 `video.list`。Client ID 填 TikTok 的 client key。
3. Facebook：Graph API，范围 `user_videos`。

然后点「打开授权」。浏览器同意后，把地址栏里的 `code` 贴回来，点「换取令牌」，再点「同步」。这个程序没有自带的开发者账号，也没有本地回调服务器，所以 code 要自己贴。令牌只放钥匙串账号 `oauth.youtube.token`、`oauth.tiktok.token`、`oauth.facebook.token`。

本地模型默认关闭。打开之后才会访问设置里的地址（默认 `http://127.0.0.1:11434`）。连不上就当没问过，规则照旧。

## 平台怎么接在一起

```text
chanwu 命令行 ──┐
                ├── OrganizerCore（Foundation + libsqlite3，Linux / macOS）
产物整理器.app ─┘         │
                          ├ 分类、规则、版本滚档、发布打分、重命名、周报、交付清单
Sources/OrganizerApp      │  只在 Package.swift 的 #if os(macOS) 里
  SwiftUI / AppKit        │  菜单栏、窗口、访达、规则编辑器
  CoreServices FSEvents   │  新文件 → 大小稳定后才进待确认
  Carbon 热键             │  ⌥⌘O 打开搜索
  AVFoundation            │  时长、缩略图、抽帧做感知哈希
  Security 钥匙串         │  快捷键、安装标识、OAuth 令牌
```

`lstat` / `rename` 在 `OrganizerPosix`。SQLite 也从这里调用系统的 `libsqlite3`，避免 Swift 把 Glibc 的 `stat` 结构体当成函数。

## 在这台 Mac 上构建失败时先看这里

| 现象 | 位置 | 怎么改 |
| --- | --- | --- |
| 找不到 `ChanwuApp` | `Package.swift` | 在 Mac 上跑 `swift package describe`。Linux 上这个目标不存在。 |
| `ld: library not found for -lsqlite3` | `Package.swift` | Command Line Tools 应该自带 sqlite3。确认 `xcrun --show-sdk-path` 里有 `usr/lib/libsqlite3.tbd`。 |
| Carbon 热键类型对不上 | `MacBridges.swift` 的 `HotkeyCenter` | 热键失败时菜单栏「产物」仍可打开搜索。`import Carbon` 失败就改成 `import Carbon.HIToolbox`。 |
| `FSEventStreamCreate` 对不上或一监视就崩 | `FolderWatcher` | 回调假定 `kFSEventStreamCreateFlagUseCFTypes`。若路径是 `char **`，去掉这个 flag。关掉设置里的监视也能扫描。 |
| `NSApp.activate(ignoringOtherApps:)` 不可用 | `AppModel.showWindow` | 改成 `NSApp.activate()`。 |
| `asset.load(.duration)` 或 `generator.image(at:)` 不存在 | `AVProbe` / `VideoFingerprints` | 缩略图和抽帧失败时，预览仍显示路径和识别依据，发布匹配退回到标题和时长。 |
| `CGContext` 或灰度图编译失败 | `VideoFingerprints.grayHash` | 可以让 `grayHash` 直接返回 nil。匹配不再使用画面哈希。 |
| 钥匙串弹窗或写入失败 | `KeychainStore` | ad-hoc 签名的身份每次构建可能变。快捷键会改写 `~/.chanwu/sealed/sealed.bin`。平台令牌没有文件后备，失败就改用 CSV。 |
| 扫桌面提示无法读取 | 系统隐私 | 允许 `app.chanwu.organizer`。请打开 `.app`，不要直接跑 `.build` 里的二进制。 |
| `onChange`、`@Bindable` 或 `onContinuousHover` 报错 | `RootView.swift` | 按 macOS 14 写的。目标机是 macOS 26.4，这些 API 在那里存在。 |
| 中文 `.app` 或 zip 路径乱码 | `scripts/make_app.sh` | 终端用 UTF-8。脚本是 LF。 |
| 应用开了但 Dock 里没有图标 | `Info.plist` 的 `LSUIElement` | 这是菜单栏应用。点状态栏「产物」。 |

另外：移动做到一半如果磁盘满了，有的文件可能已经换了位置，而 `runs/<id>.json` 还没写完。撤销只看路径还在不在，不比较内容。跨卷文件在界面和命令行里会被留下，不会复制。

## 布局

```text
Package.swift
Sources/OrganizerPosix    lstat / rename / SQLite
Sources/OrganizerCore     分类、计划、移动、索引、规则、报告
Sources/OrganizerCLI      chanwu
Sources/OrganizerApp      仅 macOS 的 SwiftUI 菜单栏应用
Tests/OrganizerCoreTests  Linux 上的单元测试
scripts/make_app.sh       打 .app 和 .zip，不用 Xcode
```
