# ebook_reader（工作名）

Android 优先的 EPUB 阅读器，Flutter 编写。**这是 MVP，只跑通一条主线**：

```
本地导入 EPUB → 阅读 → 高亮(颜色)+批注 → 导出 Markdown
```

OPDS、RSS 自动成书、多设备同步、TTS 都**尚未实现**，但数据模型已经为它们留好位置。

> 应用名和包名（现在是 `阅读` / `com.example.ebook_reader`）都是占位，随时可改。

---

## 装到手机（无需电脑）

1. 在手机上打开本仓库，进入 **`release/`** 目录
2. 点 **`ebook_reader-1.0.0.apk`** → 下载
3. 点它安装；系统提示「未知来源」时选**仍要安装**
   （它没有正式证书，是自签名包 —— 详见下方「关于签名」）
4. 顺手下载同目录的 **`test-book.epub`**，打开 App → 导入 EPUB → 选它，即可立刻验证

要求 **Android 7.0 及以上**。APK 内含 arm64-v8a / armeabi-v7a / x86_64 三种架构，主流手机都能装。

**装的时候可能遇到的拦截**（各家系统不同）：

- **小米 / 红米**：设置 → 应用设置 → 应用管理 → 右上角 ⋮ → 特殊权限 → **安装未知应用**，给你打开 APK 的那个应用授权
- **华为 / 荣耀**：若有「**纯净模式**」，需在 设置 → 系统和更新 里先退出
- **OPPO / vivo**：提示「未经过安全检测」时选**继续安装**

### 关于签名

`release/` 里的 APK 是 **Release 构建**（已优化、已裁剪），但用的是 **debug 签名** ——
Flutter 在没有配置 signingConfig 时的默认行为。所以：

- ✅ 可以侧载安装、正常使用
- ❌ **不能上架应用商店**，那需要自建 keystore 并配置 `signingConfigs`

<details>
<summary>为什么 APK 被直接提交进仓库（而不是走 Releases）</summary>

为了让你能在手机上从仓库里直接下载，省掉数据线。代价是它占 50.8 MB 且会进入 git 历史 ——
每次改动都会让仓库变大。如果之后不想要了，建议改成 GitHub Releases 承载二进制，仓库里只留源码。

仓库体积构成：APK 50.84 MB + `assets/`（foliate-js 全量快照，含 12 MB EPUB 用不到的
PDF.js 字库与 CMap）+ 源码与 Android 工程 ≈ 63 MB。

</details>

---

## 架构

```
Flutter (Dart)                          WebView (Chromium)
┌────────────────────────┐              ┌──────────────────────────────┐
│ 书架 / 导入 / 导出      │              │ host.html                    │
│ SQLite (books/progress │              │  └ bridge.js                 │
│        /annotations)   │              │     └ foliate-js (vendored)  │
│                        │  JS Bridge   │        ├ view.js             │
│  AssetServer ──────────┼─────────────▶│        ├ epubcfi.js          │
│  127.0.0.1:<随机端口>   │  DshBridge   │        ├ overlayer.js        │
│   ├ /reader/*  资源     │  JavaScript  │        └ vendor/zip.js       │
│   └ /book/<id> EPUB     │  Channel     │                              │
└────────────────────────┘              └──────────────────────────────┘
```

### 为什么用回环 HTTP 服务，而不是直接加载本地文件

三个理由，每一个都是硬约束：

1. **安全上下文**。`file://` 不是"可信来源"，`crypto.subtle` 在那里不可用，而 foliate 需要它做 IDPF 字体解混淆。`http://127.0.0.1` 是安全上下文，问题消失。
2. **Range 请求**。foliate 的 zip.js 加载器会对 EPUB 发 Range 请求，真正的 HTTP 服务才能正确应答（`AssetServer` 实现了 206 / `Content-Range`）。
3. **CSP 只能在响应头下发**。这是下面那条安全约束的前提。

### 安全：为什么必须强制 CSP

EPUB 允许内嵌 JavaScript。foliate 把每一节渲染在 `blob:` iframe 里，而 blob 文档**继承父文档的 CSP** —— 所以 `script-src 'self'` 能挡住书里的任何内联或远程脚本。

这不是可选项：本项目的书源规划包含 OPDS 书源和 RSS 抓取，**那些内容我们控制不了**。`AssetServer.csp` 里的策略是：

```
default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline';
img-src 'self' blob: data:; font-src 'self' blob: data:;
media-src 'self' blob: data:; connect-src 'self' blob: data:;
frame-src 'self' blob: data:; child-src 'self' blob: data:;
worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'
```

配套的 `android/app/src/main/res/xml/network_security_config.xml` 把明文 HTTP **仅**豁免给回环地址，`base-config` 仍是 `cleartextTrafficPermitted="false"`。

### 为什么用 CFI 而不是页码

高亮和进度都以 **EPUB CFI**（Canonical Fragment Identifier）存储。CFI 跨设备稳定，且**不随字号、行距、屏幕尺寸变化而漂移** —— 页码做不到这一点。这正是后面能做多设备同步的前提。

进度还有个容易踩的点：`view.init({ lastLocation })` 内部走 `resolveNavigation()`，它**只对 CFI 字符串**（或数字 / `{fraction}`）走 CFI 分支。传 `{cfi: "..."}` 这种包装对象会掉进 `resolveHref()` 然后失败。`bridge.js` 里的 `restore()` 因此显式接收裸 CFI 字符串。

### 数据模型

三张表，全部带 `updated_at` + `deleted`（墓碑）+ `dirty`（待推）——MVP 不同步，但字段已按"Supabase 按 `updated_at` 的 LWW 合并"设计好：

| 表 | 主键 | 说明 |
|---|---|---|
| `books` | EPUB 内容的 sha256 | 内容寻址，重复导入自动去重 |
| `progress` | `book_id` | 每本书一条，存 CFI + fraction |
| `annotations` | 生成的 id | CFI + 选中文本 + 颜色 + 可选笔记 |

---

## 第三方代码

`assets/reader/foliate/` 是 [foliate-js](https://github.com/johnfactotum/foliate-js)，**MIT**，锁定到上游 commit `78914aef4466eb960965702401634c2cb348e9b1`。

锁定方式与校验：

- 该仓库**没有任何 release / tag**（作者 README 明确说库不稳定、API 可能随时变），所以按 commit 锁定是唯一正确做法；
- `assets/reader/foliate/SOURCE.json` 记录了 commit、抓取时间和**每个文件的 SHA-256**；
- 曾评估过 npm 上的 `foliate-js` 包，但**发布者是第三方**（不是作者 John Factotum），且全包只有一个版本 —— 属于转发包，因此**没有采用**；
- 226 个文件已逐一比对上游哈希，全部一致。升级时：重跑取回脚本，用新 commit 覆盖，并重新核对哈希。

MIT 只覆盖代码；Foliate 那个**桌面应用**是 GPL，两者是不同仓库，本项目不受其影响。

---

## 构建环境（这台机器上的非显然之处）

工具链装在 **`.toolchain/`**（工作区内），而非用户目录 —— 因为这个环境有文件沙箱，而 pub 缓存、Gradle 缓存、Flutter 配置默认都往用户目录写。

| 组件 | 位置 / 版本 |
|---|---|
| Flutter | `.toolchain/flutter` — 3.47.5 stable / Dart 3.13.4 |
| Android SDK | `.toolchain/android-sdk` — platform-tools 37.0.1、platforms;android-36、build-tools;36.0.0 |
| JDK | `C:\Program Files\Java\jdk-21.0.10` |
| pub 缓存 | `.toolchain/pub-cache` |
| Gradle 缓存 | `.toolchain/gradle-home` |

构建用 `.toolchain/fl.ps1` 包装，它注入了四个必需的环境变量：

1. `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` —— **必需**。`storage.googleapis.com` 在这台机器上被重置（TLS 阶段 ECONNRESET），不指向镜像则 Flutter 首次运行下不了 Dart SDK 和引擎产物。
2. `HOME` / `USERPROFILE` / `APPDATA` / `LOCALAPPDATA` 重定向到 `.toolchain/home` —— **必需**。Flutter 启动时要往 `%APPDATA%\.flutter_settings` 写配置，被沙箱拒绝会导致 "Unable to create dart snapshot for flutter tool"。
3. `PUB_CACHE` / `GRADLE_USER_HOME` 重定向 —— 否则每次构建都撞权限。
4. `JAVA_HOME` / `ANDROID_HOME` / `ANDROID_SDK_ROOT` / `ANDROID_USER_HOME`。

### 沙箱与子进程（重要）

受限文件沙箱下 **Dart 无法创建子进程**：`Process.runSync` 报
`ProcessException: 拒绝访问 (process_win.cc:744)`，因为该沙箱禁止程序打开命名管道。
而 Flutter 全程都在 spawn 子进程（git / java / gradle / adb / dart），所以
**构建必须在 `danger-full-access` 策略下进行**。

症状伪装得很像别的问题：`flutter --version` 会陷入无限重建快照循环
（`bin/cache/flutter_tools.snapshot.old1..oldN` 每 50 秒新增一个），
因为 `dart --snapshot-kind=app-jit` 是训练式快照，它会真的执行 `flutter_tools` 的
`main()` → `Git.runSync()` → 抛异常 → 非零退出 → `shared.bat` 判定失败并重试。

### 网络可达性（实测）

| 域名 | 状态 |
|---|---|
| `storage.flutter-io.cn` | ✅ Flutter 镜像 |
| `dl.google.com` | ✅ Android SDK |
| `pub.dev` / `pub.flutter-io.cn` | ✅ |
| `registry.npmjs.org` / npmmirror | ✅ |
| `cdn.jsdelivr.net` / `ghproxy.net` / `gh-proxy.com` | ✅（取上游 GitHub 文件走这里）|
| `github.com` / `storage.googleapis.com` | ❌ TLS 被重置 |

### Gradle 侧的两个坑（都真的踩过）

**1. 一条卡死的连接会把 Gradle 永久挂住。**

`services.gradle.org` 能通，但它 **307 重定向到 `github.com`**（被墙），所以 wrapper 下载发行版失败。
解法是给本机 wrapper 缓存"播种"：Gradle 的缓存目录名是 `distributionUrl` 的 **MD5 再转 36 进制**，
用镜像下好 zip 放进该目录并解压即可，**工程文件不用改**
（`.toolchain/gradle-hash.mjs` 复现了这个哈希算法，`.toolchain/probe-gradle.mjs` 验证了重定向链）。

更麻烦的是依赖下载：曾观察到守护进程对同一个 IP 保持 **8 条 ESTABLISHED 连接、25 分钟零进展**，
期间只消耗 3 秒 CPU —— Gradle 默认 HTTP socket 超时实际等于"永远"。
`.toolchain/gradle-home/gradle.properties` 收紧超时后，同样故障 3 分钟内快速失败：

```
systemProp.org.gradle.internal.http.connectionTimeout=30000
systemProp.org.gradle.internal.http.socketTimeout=60000
systemProp.org.gradle.internal.repository.max.retries=3
```

> 顺带确认：`dl.google.com`、`repo.maven.apache.org`、`plugins.gradle.org` **实测都很快**
> （348ms / 1072ms / 804ms）。所以病因不是"域名被墙"而是个别连接卡死，**不要为此替换仓库镜像**。

**2. 千万不要在 init 脚本里清空或接管 Gradle 仓库列表。**

Flutter 的 Gradle 插件在**项目级**注入引擎仓库（`FlutterPlugin.kt:91,97,100`）：

```
System.getenv(FLUTTER_STORAGE_BASE_URL) ?: "https://storage.googleapis.com"
"$hostedRepository/${engineRealm}download.flutter.io"
repositories.maven { ... }
```

`io.flutter:flutter_embedding_release` **只存在于这个仓库**。一旦用
`repositories.clear()` / `RepositoriesMode.PREFER_SETTINGS` 接管仓库列表，它会被静默移除，
而报错是 "Could not find io.flutter:flutter_embedding_release" —— **看起来像网络问题，其实不是**。

结论：`FLUTTER_STORAGE_BASE_URL` 必须指向镜像（已验证：
`storage.flutter-io.cn/download.flutter.io` → 200/120ms，而
`storage.googleapis.com/download.flutter.io` → ECONNRESET），且**不要动仓库列表**。
曾写过的 `init.gradle` 已停用并留档为 `.toolchain/gradle-home/init.gradle.disabled`。

### 构建结果（实测）

```
√ Built build\app\outputs\flutter-apk\app-release.apk (50.8MB)
```

| 项 | 值 |
|---|---|
| 包名 / 应用名 | `com.example.ebook_reader` / 阅读 |
| minSdk / target / compileSdk | 24 / 36 / 36 |
| 原生 ABI | arm64-v8a, armeabi-v7a, x86_64 |
| 打包的 reader 资源 | 37 项 |
| SHA256 | `3D67D1788BF655419F0C99E8B97CA93553B645B8F7D164A45B34837BD93C4DFE` |

构建过程中 Gradle 自动补装了 `platforms;android-35`、`ndk;28.2.13676358`、`CMake 3.22.1`。

`assets/reader/foliate/vendor/pdfjs/` 下的 **190 个 PDF.js 字库与 CMap 有意未打包** ——
只有渲染 PDF 才需要，本项目只支持 EPUB。

资源完整性用 `.toolchain/verify-reader-assets.mjs` 校验：它把 foliate 所有 JS 里的相对
`import` / `import()` 以及 host.html 的引用全部抽出来，逐一确认目标文件在 APK 内。
结果 **21/22 通过**，唯一"缺失"是 `rollup/zip.js` 引用 `node_modules` —— 那是 **Rollup 打包配置**，
用于**生成** `vendor/zip.js`，不是运行时依赖，属误报。

---

## 构建与测试

```powershell
cd D:\Deepseek\Harness\ebook_reader

# 注意：必须在 danger-full-access 文件策略下运行
powershell -NoProfile -ExecutionPolicy Bypass -File ..\.toolchain\fl.ps1 analyze
powershell -NoProfile -ExecutionPolicy Bypass -File ..\.toolchain\fl.ps1 test
powershell -NoProfile -ExecutionPolicy Bypass -File ..\.toolchain\fl.ps1 build apk --release
```

产物：`build\app\outputs\flutter-apk\app-release.apk`

> 该 APK 使用 **debug 签名**（Flutter 在没有 signingConfig 时的默认行为），
> 可以侧载安装，但不能上架应用商店。要正式发布需自建 keystore。

---

## 实机验证结果（Android 16 / API 36 模拟器）

已在本机 Android 模拟器上实际运行并逐项确认，**不是只有静态检查**：

| 验证项 | 结果 |
|---|---|
| 安装 / 启动 / 无崩溃 | ✓ `libflutter.so` 加载，Impeller 渲染后端就绪，无 FATAL |
| SQLite 建表 | ✓ 三张表 + 三个索引在设备上按设计创建 |
| 书架读取 | ✓ 标题 / 作者 / 首字头像 / 悬浮按钮全部正确 |
| 打开 EPUB | ✓ 资产服务器（`127.0.0.1:39661`）→ WebView → foliate 解析 → 渲染 |
| 中文排版 | ✓ 标题、正文、标点、首行缩进、两端对齐 |
| 字号 / 主题 | ✓ 字号 18→34 实时缩放；浅色 / 羊皮纸 / 深色切换生效 |
| 选中 → CFI | ✓ `epubcfi(/6/2!/4/4,/1:23,/1:24)` |
| 高亮落库 | ✓ `annotations` 表记录 CFI + 颜色 + 文本 |
| 高亮回显 | ✓ `Overlayer.highlight` 绘制，角标计数更新 |
| **CFI 与排版无关** | ✓ 字号 18→34 巨变后，高亮仍精确锚在同一字上 |
| 重启后恢复 | ✓ 高亮、进度、字号、主题全部保留 |
| 进度落库 | ✓ `cfi` + `fraction=0.3043` + `section_label=第一章 · 潮汐` |

### 实机跑出来才发现的 bug（已修）

**CSP 拦掉了 `blob:` 样式表，导致字号与主题静默失效。**

foliate 的 `renderer.setStyles()` 是通过 **blob: URL** 注入阅读样式的，而最初的
`style-src 'self' 'unsafe-inline'` 不含 `blob:`。表现极具迷惑性：界面毫无异常，
只是样式不生效 —— 第一版截图里的首行缩进其实来自 EPUB 自带的 `style.css`，
让人误以为注入成功了。是 WebView 控制台日志揭穿的：

```
Refused to load the stylesheet 'blob:http://127.0.0.1:39661/...'
because it violates the following Content Security Policy directive:
"style-src 'self' 'unsafe-inline'"
```

修复为 `style-src 'self' 'unsafe-inline' blob:`。**这不扩大攻击面**：
blob URL 只能由脚本产生，而 `script-src 'self'` 依然禁止书内任何脚本。

> 这条也是"必须实机运行"的最好论据 —— 静态检查和单元测试都不可能发现它。

### 仍未在设备上验证

- **Markdown 导出**：逻辑有 6 个单元测试覆盖，但设备上走的是系统保存对话框（SAF），
  未通过自动化点击走完。
- **CSP 对真实恶意 EPUB 的拦截效果**：策略已确认在生效（拒绝日志是实证），但未构造
  带内嵌脚本的样本做对抗测试。

## 已知限制

- **只支持无 DRM 的 EPUB**。带 DRM 的书（京东读书、掌阅、Kindle 等）打不开，本项目不破解 DRM。
- 只支持 EPUB；PDF / MOBI / TXT / CBZ 均未接入（foliate-js 本身支持，但未接桥）。
- 悬浮泡泡、仿真翻页动画等阅读体验细节未做。
- 导入时先按文件名显示，首次打开后会用 OPF 里的真实书名/作者更新书架。
- **进度百分比取的是"当前可见页的末尾"**（foliate `relocate` 的语义），
  所以刚打开一章时会直接显示该章结束处的百分比（本测试书单章占 61%，打开即显示 60.9%）。
  章节名正确，但在意这个数字的话应改用 range 起点计算。

## 下一步（按原定路线）

1. OPDS 客户端 —— foliate-js 自带 `opds.js`（含 OPDS 1.x → 2.0 转换），能省掉整个 XML 解析层；
2. RSS → 自动组装成书（一源一本书，持续追加章节）；
3. Supabase 同步（按 `updated_at` 的 LWW，进度取最大、笔记合并去重）；
4. TTS（foliate 有 SSML 模块，可先接系统离线 TTS）。
