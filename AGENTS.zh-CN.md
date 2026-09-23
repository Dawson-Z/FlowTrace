# AGENTS.md（中文版）

AI agent —— 以及人类 —— 在本仓库工作的指引。

## 本仓库是上游的分支

FlowTrace 是 [foamzou/ITraffic-monitor-for-mac](https://github.com/foamzou/ITraffic-monitor-for-mac)
（*iTraffic*）的分支，MIT 许可。它以两种方式分发：本仓库里的源码，以及每个 GitHub Release 附带的
`.dmg` / `.zip`。没有 Mac App Store 上架。发布包用自签名证书签名、**未经公证**，所以 macOS 首次
启动会拦下它，直到用户手动放行 —— 「发布」一节写了它们怎么构建，以及加入公证后要改什么。

想法只能单向流动 —— **从上游流出，进入本 fork** —— 绝不能反过来。上游是一个独立且仍在维护的
项目，有自己的目标；本分支允许与它分道扬镳。

- **绝不要提交凭证、密钥、绝对家目录路径或会话日志。** 上游那条规则在这里依然适用，而且不是
  「好习惯」而是硬约束：commit 是永久的 —— 公开是单向门，事后重写历史代价高昂、追不回已经
  clone 过的人，也追不回已经被抓走的密钥。`.gitignore` 只覆盖了明显的情况
  （`.trellis/.developer`、`.claude/projects/`、`.codex/`）；它不能代替你在提交前自己看一遍 diff。
- **不要**向上游开 PR，也不要把本分支的提交推上去。
- **不要**复制其它产品的私有源码、内部设计文档或商用专用逻辑到本仓库。
- **`project.yml` 里必须保持 `CODE_SIGN_IDENTITY: "-"`。** 全新 clone 必须在没有任何证书的情况下
  能构建。发布构建改为在命令行上覆盖身份（见「发布」一节）。把身份写死进 YAML 会让所有没有那张
  证书的人构建失败 —— 那恰好和「分发源码」的目的相反。

## 项目是什么

FlowTrace 是 iTraffic 的分支。它继承上游的核心思路 —— 一个小的、按进程维度的 macOS 菜单栏
网络监控器，驱动 `/usr/bin/nettop` —— 并在其上叠加了新特性：进程搜索、SQLite 落盘的流量历史、
接口感知采样等。这些都在用户态完成，不需要 NetworkExtension 或系统 entitlements。

实验特性**与**同一作者**其它任何产品**发布的特性都不同。它们完全基于 Apple 公开文档
和上游的 user-state 代码设计，仅此而已。

## 目录布局

```
FlowTrace/                         分支自有实验
  Feature/Appearance/                强调色子系统 + 手绘控件
  Feature/History/                   环形缓冲、SQLite 持久化、历史窗口
                                     (app usage / heatmap / alerts)、CSV
  Feature/Interface/                 按接口类别采样 + 概览
  Feature/Localization/              运行时 locale 解析器（Loc.l）
  Feature/Logging/                   os.Logger + 文件 sink（Log.* 帮助器）
  Feature/Search/                    进程搜索
  Feature/Settings/                  SettingsStore、设置窗口、保留、
                                     数据清理、开机自启
  Feature/Usage/                     周期总量、配额提醒、进程告警、
                                     本地通知投递
FlowTraceForMac/                   上游继承的应用源码（本分支改动过一些，
                                   见「Active experiments」）
  Service/NettopRunner.swift       驱动 /usr/bin/nettop
  Network.swift                    解析帧、喂入模型
  Model/                           支撑两个 surface 的 ObservableObject
  ContentView.swift                popover：头部 + 进程列表
  StatusBarView.swift              菜单栏速率
docs/ARCHITECTURE.md               架构 + 逐文件参考
project.yml                        XcodeGen 唯一事实来源
changelog/<version>.md             release notes（英文）
changelog/<version>.zh-CN.md       release notes（简体中文）
```

`FlowTrace.xcodeproj` 由 `project.yml` 生成，**不**入库 —— `.gitignore` 规定「永远不提交
生成的 Xcode 工程」。改 YAML 后跑 `xcodegen generate`，只提交 YAML（工程按需重新生成；新
clone 需要执行 `xcodegen generate`）。

目录树里有两个目录属于**工具链**而非应用源码，值得单独说明 —— 它们占了已跟踪文件的一半以上，
而且没有一个是 Swift：

- **`.trellis/`** —— 本项目的工作记录，由 Trellis 工作流系统维护。`spec/` 是对改动构成约束的
  约定；`tasks/` 每个特性一个目录，内含 PRD、设计说明与实施计划（包括那些被有意推迟或砍掉的）；
  `workspace/` 是会话日志。它是有意入库的：改动背后的理由属于项目的一部分，而不是私人笔记，被
  推迟的任务留在那里，是为了下一个人不必重新推导一遍。
- **`.trae/`** —— 同一系统为本项目所用 IDE 生成的平台适配层：agent 定义、hooks、skills、
  slash commands，以及提交信息规则。构建或运行 FlowTrace 完全不需要它。

这两个目录都不影响 app。如果你是为了读代码来的，从
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 开始。

## 构建

```bash
brew install xcodegen
xcodegen generate
xcodebuild build -project FlowTrace.xcodeproj \
  -scheme FlowTrace -configuration Debug
```

单元测试位于 `FlowTraceTests/`，用 `xcodebuild test -project FlowTrace.xcodeproj -scheme
FlowTrace -configuration Debug` 跑（1.0.0 时为 205 个用例）。覆盖进程列表的比较器与合并、帧解析器、
配额跨越判定、进程告警判定、接口分类器、两个 SQLite 管道（每进程用量、interface 热力图）、
只读查询面、设置存储、强调色解析、21 种语言的字符串表，以及本地通知的投递契约。

真实依赖是**注入**而非 mock：`SettingsStore(defaults:)`、`QuotaMonitor(settings:aggregator:defaults:)`、
`ProcessAlertMonitor(settings:deliver:)`、`HistoryPersistence(dbURL:retentionSeconds:)` 都把协作者作为
参数接收，所以测试可以交出一次性的 `UserDefaults` suite、临时数据库，以及替身 `NotificationDelivery`。

**测试运行既不隔离、也不是只读 —— 这是已知属性，不是 bug。** `FlowTraceTests` 是跑在 app **内部**的
（`TEST_HOST`），所以 `applicationDidFinishLaunching` 会真实执行：一次测试运行会拉起两个 `nettop`
子进程，并读写用户真实的 `~/Library/Application Support/FlowTrace/history.sqlite3` 与
`~/Library/Logs/FlowTrace.log`。任何经过 `Loc` / `LocalizationManager.shared` 的测试还会实例化
`SettingsStore.shared`，从而读取真实 `UserDefaults` 域，并可能在其中执行一次性 key 迁移。
注入隔离的依赖只能保证每个测试的**断言**是干净的，它并不会把宿主 app 关进沙箱。
  同一事实反过来也成立：**启动时弹任何模态框都会卡死整个测试套件** —— 启动通知提醒用的是
`runModal()`，权限为 denied 时它会占住主线程，直到两个等主队列的测试超时（2026-09-23 实测）。
因此 `presentLaunchReminderIfNotSuppressed` 在 XCTest 环境下提前返回（检测
`XCTestConfigurationFilePath`）；今后任何启动期 UI 都需要同样的守卫。

需要真正干净的环境做手工验证时，用 `CFFIXED_USER_HOME=<dir>` 启动构建产物 —— macOS 的
`NSHomeDirectory()` 走 `getpwuid()`，所以只设 `HOME` 变量**不会**重定向 Application Support 或 Logs，
而 `CFFIXED_USER_HOME` 会。它只重定向文件路径；`UserDefaults` 仍解析到真实域。

本地构建注意：沙箱 shell 里 Xcode 的 index store
（`~/Library/Developer/Xcode/DerivedData`）可能被屏蔽。加 `-derivedDataPath build
COMPILER_INDEX_STORE_ENABLE=NO` 可以绕过。

`project.yml` 里 `CODE_SIGN_IDENTITY` 是 ad-hoc（`-`），所以本项目无需证书即可构建。发布是手工切的 —— 见下。

## 发布

没有 CI、没有发布脚本：一次发布就是手工跑几条命令。这一节存在的意义是让下一个人不必重新推导那套
签名安排 —— 因为下面每一步都有个从命令本身看不出来的关键点。

### 版本号

`MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION` 都在 `project.yml` 里。两个都要改，并同时新增
`changelog/<version>.md` 与它的中文版 `changelog/<version>.zh-CN.md`（两份保持同步：同样的结构、
同样的事实），然后重新生成：

```bash
xcodegen generate
```

版本号从 `project.yml` 读 —— `project.yml` 是 YAML、不是 plist，所以**不能用 `plutil`** 取版本号
（`plutil` 解析失败时把整文件当一行传给下游，后面所有变量引用都会爆错）。`awk` 才是对的：

```bash
VERSION=$(awk '/^[[:space:]]*MARKETING_VERSION:/{sub(/^[^:]+:/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' project.yml)
```

### 构建与签名

```bash
xcodebuild build -project FlowTrace.xcodeproj -scheme FlowTrace \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="<维护者的签名身份>" CODE_SIGN_STYLE=Manual
```

这条命令有三个不显然的点：

- **通用二进制靠的是 `-configuration Release`。** Release 用 `ARCHS_STANDARD`，产物是
  `x86_64 arm64`；Debug 只构建本机架构。**绝不要发 Debug 构建。**
- **签名身份在这里传，不从 `project.yml` 读。** `project.yml` 保持 `CODE_SIGN_IDENTITY: "-"` 是为了
  谁都能构建；发布构建覆盖它。身份必须是**稳定**的 —— ad-hoc 签名每次重建都是不同的身份，会让一切
  依赖 bundle 身份跨版本延续的东西失效。
- **自签名身份不能替代公证。** 它只买到一个稳定的签名，仅此而已。Gatekeeper 依然会拦下首次启动，
  这正是 README 有「首次启动」一节的原因。

上面这条命令已确认可用（Xcode 16.4，自签名身份在登录钥匙串里，`CODE_SIGN_STYLE=Manual` 在未配置
team 的情况下被接受）。请在 `Terminal.app` 里构建 —— 沙箱化 shell 可能被拒绝访问钥匙串，失败的样子
看着像项目问题；见下面 § `errSecInternalComponent` 一节。

### 上传前自检

下面这几种出错方式里有好几种，产出的 app 在构建它那台机器上跑得好好的，换台机器就不行。所以要检查
**产物**，不要相信构建日志：

```bash
APP=build/Build/Products/Release/FlowTrace.app

lipo -info "$APP/Contents/MacOS/FlowTrace"    # 架构
codesign -dv --verbose=4 "$APP"               # 身份、flags、team
spctl -a -vvv -t exec "$APP"                  # Gatekeeper 的判定
```

| 检查项 | 期望值 | 不对意味着什么 |
| --- | --- | --- |
| `lipo -info` | `x86_64 arm64`。`codesign` 输出里的 `Format=` 行说的是同一件事：`Mach-O universal (x86_64 arm64)` | `Mach-O thin (arm64)` 说明只有本机架构，即 Debug 构建。**绝不能发** —— Intel Mac 完全跑不了。 |
| `codesign -dv` → `Authority` | 签名身份的名字 | **整行不存在**、取而代之是 `Signature=adhoc`，说明压根没签上、回落成了 ad-hoc。`codesign` 从不打印 `Authority=-`，行不存在才是信号。 |
| `codesign -dv` → `flags` | 真实身份是 `0x10000(runtime)`；ad-hoc 是 `0x10002(adhoc,runtime)` | `0x0(none)` 说明 hardened runtime 没开，会挡住后续公证 —— 要么是 Debug，要么是手写 `codesign` 时漏了 `--options runtime`。 |
| `codesign -dv` → `TeamIdentifier` | `not set` | 自签名身份的预期结果 —— 也正是 Gatekeeper 无法验证这个包的原因。 |
| `spctl -a` | **rejected** | 不是故障。未公证的 app 本来就该被判 rejected，README 的「首次启动」一节就是为此而写。 |

上面这些期望值是把这几条检查跑在一个真实的 `-configuration Release` 产物上得到的，所以那两个 ad-hoc
变体就是「一个正确但未公证的产物长什么样」的基准。

要特别警惕的组合是 `Mach-O thin (arm64)` 加 `flags=0x0(none)`：那是套着 Release 路径的 Debug 构建。
这两半在启动时都看不出来，所以这项检查不是可选项。

### 打包

```bash
rm -rf dist && mkdir -p dist/dmg
cp -R build/Build/Products/Release/FlowTrace.app dist/dmg/
ln -s /Applications dist/dmg/Applications

# .dmg —— app 加一个 /Applications 替身，拖进去即装完
hdiutil create -volname FlowTrace -srcfolder dist/dmg \
  -ov -format UDZO dist/FlowTrace-<版本>.dmg

# .zip —— 同一个 bundle，去掉磁盘映像
ditto -c -k --sequesterRsrc --keepParent \
  build/Build/Products/Release/FlowTrace.app dist/FlowTrace-<版本>.zip

shasum -a 256 dist/FlowTrace-<版本>.dmg
```

`dist/` 已在 `.gitignore` 里。给 commit 打 `v<版本>` 标签，把两个文件都传到 GitHub Release，并且把
README 的「首次启动」步骤一并贴进 release notes：**「已损坏，无法打开」这句措辞读起来像下载坏了**，
找不到绕过办法的用户就会当成 bug 来报。

### 等到做公证时

上面全部保留，但有三处要改。真正值得在意的不是首次安装：用户给出的 Gatekeeper 授权是挂在「他放行的
那一份」上的，所以**每个新版本都带着全新的 quarantine 标记，会把所有人都再拦一次**，包括已经在用
旧版本的人。没有公证，这份摩擦会随每次发布累积而不是摊薄 —— 这才让那笔年费值得争论，而不是可有可无
的锦上添花。

1. 签名身份从自签名换成 Developer ID 证书。这就是「Gatekeeper 拦」与「Gatekeeper 放」的全部差别，
   也是本流程里唯一花钱的地方（付费加入 Apple Developer Program）。自签名证书无法公证。
2. 在签名与打包之间插入公证步骤：对 `.dmg` 跑 `xcrun notarytool submit`，再用
   `xcrun stapler staple` 把票据钉上去。钉在磁盘映像而不是裸 bundle 上更好 —— 票据会跟着用户实际
   下载的文件走，首次启动离线也能通过。
3. README 的「首次启动」一节删掉。

有一件已经准备好的事：Release 已经开了 `ENABLE_HARDENED_RUNTIME`，这是 Apple 公证的硬性要求之一。
没有它，提交会被拒，而给出的理由读起来和签名毫无关系。

### 签名报 `errSecInternalComponent` 时

这是本流程里唯一一个报错和原因看不出关系的错，所以值得认得它。`codesign` 在**拿不到私钥**时报这个
错，而证书本身可能完全正常 —— 于是 `security find-identity -v -p codesigning` 能把身份列得好好地，
但**任何**签名动作都失败。诊断方法是签一个和本项目毫无关系的文件：

```bash
cp /usr/bin/true /tmp/probe
codesign --force --sign <身份哈希> /tmp/probe
```

如果它也一样失败，那就不是构建的问题，本仓库里没有任何东西需要修。两个原因，按可能性排序：

1. **私钥的 partition list 里没有 `codesign:`。** 用裸 `security import` 导入 `.p12` 通常就是这个
   结果。范围最小的修法是只给这一个身份重设 ACL：
   ```bash
   security import <证书>.p12 -k ~/Library/Keychains/login.keychain-db \
     -P <p12 密码> -T /usr/bin/codesign -A
   ```
   范围大的修法是重写整个钥匙串的 partition list，需要登录密码：
   `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <密码> ~/Library/Keychains/login.keychain-db`。
2. **有个交互式钥匙串授权弹窗卡在你根本看不到的地方。** 用 `-A` 之外的方式导入的密钥，第一次被
   使用时应用会请求授权。在图形会话里允许过一次，之后就记住了；如果弹窗被错过或被拒，之后每一次
   非交互式构建都会以完全相同的方式失败。

发布构建请在 `Terminal.app` 里跑。沙箱化的 shell（IDE 里的 agent、容器）可能被直接拒绝访问钥匙串，
报出一模一样的错，从而掩盖了「配置其实是好的」这个事实。

#### 本机实例（2026-09-23）

登录钥匙链里唯一的可用 codesigning 身份是 `Dawson`（SHA-1 `BB1394A66CB92A22F19FCE4BA28735122D9807BD`）。
首次跑发布构建时 `libswift_Concurrency.dylib` 报 `errSecInternalComponent`；探针报同样的错。

- **没用的做法**：在 IDE shell 里跑 `set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '<字面密码>'`。
  那串 `<字面密码>` 字面被当成密码交给钥匙链，钥匙串判错、命令没改 ACL、下一次签名照样失败。
- **有用的做法**：同一 `set-key-partition-list` 命令**去掉 `-k`**，让钥匙链弹自己的密码框。
  之后在同一 `Terminal.app` 里跑探针，得到 `/tmp/probe: replacing existing signature`（**没有**
  `errSecInternalComponent`），真正的 `xcodebuild` 也就过了。
- **IDE shell 全程都是错的 shell**：即便 ACL 已经修好，IDE 沙箱 shell 仍然报 `errSecInternalComponent` ——
  因为 macOS 的进程级钥匙链访问对沙箱进程是拒绝的，而这个拒绝恰好也产生同样的错码。
  区分「IDE shell 的问题」与「ACL 真的坏了」的标志：**`find-identity` 正常列出证书、但探针仍失败**，
  且失败 shell 的环境变量里能搜到 `TRAE_SANDBOX_*`（Trae IDE 注入到它启动的每个 shell）。

结论：探针在 IDE 启动的 shell 里失败时，**先别动钥匙链，直到你在 `Terminal.app` 里复现了探针失败再说**。
在 Terminal.app 里复现，才能知道到底是 ACL 坏还是 shell 错。

## 从上游继承的约定

- **速率字段自带单位**（`inBytesPerSec`、`totalInBytesPerSec`）。`nettop` 以 delta 模式
  按 1 秒采样，所以一帧报的是整个窗口的字节，不是速率。归一化**只**在 `Network.parser` 发生一次——
  那是 nettop 数据进入 app 的唯一入口 —— 下游永远不要再除一遍。上游的 issue #28 就是这个：
  除法上移到聚合点后，状态栏正确了，进程列表没有，于是每个行渲染大了三个月。

- **应用只发一次网络请求，而且只在点击时。** 上游的更新检查在用户点击版本号时命中
  GitHub releases API。本 fork 移除了上游的 `UpdateChecker.swift` 和任何网络调用，原因：
  (a) 上游是移动靶子；(b) 这条规则 —— 「iTraffic 列出每个进程的流量，包括它自己；后台 poll
  在用户眼里就是「解释流量的工具自己产生的未知流量」」—— 同样适用。任何未来在网络方面的工作
  都遵循同一规则。

- **`.help(_:)` 是 macOS 11+** —— 正好是本 fork 的部署目标，所以这里不需要 `@available` 标注。
  比 11 新的 API 仍需 `#available` 守卫，而不是抬高部署目标。

- **SF Symbols 用 `.font` 缩放，禁止 `.resizable()`** —— 在菜单栏尺寸下，resize 会把它们拉成细条。
  `Text` 里用 Unicode 字形就完全规避了这个问题，也没有可用性限制。

## 分支特有约定

- **部署目标是 macOS 11.0，不是 10.15。** 上游 10.15 的底线是为了 Catalina 用户能看进程流量而设；本 fork
  在 Big Sur+ Mac 上跑，所以新底线只是「让 `Logger` 和 `@StateObject` 不需标注」。如果实验需要
  13/14 独有的 SwiftUI（`NavigationStack`、`Charts` …），我们会再次抬高，而不是把
  `@available` 撒满源码。

- **Feature 模块位于 `FlowTrace/Feature/<Name>/`**，每个模块自洽：自己的视图、模型、纯函数工具。
  `FlowTrace/Feature/...` 与 `FlowTraceForMac/...` 文件同等加入 Xcode target。

- **改动上游代码的实验必须在本 AGENTS.md 登记触点。** 如果你改了 `ContentView.swift` 容纳新的
  搜索栏，在「Active experiments」段写明。否则下个人得读 diff 才知道哪个上游文件不再是 vanilla。

- **数据不离开本机。** 没有 telemetry、没有 analytics、没有远程更新检查、没有远程 catalog fetch。
  本 fork 可能会读 `/Applications/...` 提取图标，但不会读取、解析或触碰任何其它产品的二进制
  或私有数据结构。

- **本 fork 唯一写进「不属于自己」的目录的文件是启动代理，且只在你主动要求时写。** 在 macOS 11–12 上打开
  「开机自启」会让 `LaunchAtLoginManager` 写入 `~/Library/LaunchAgents/local.FlowTrace.login.plist`
  —— 一个 launchd 用户代理，唯一职责是对本 bundle 执行 `/usr/bin/open -g`。launchd 在每次登录时
  扫描该目录，所以文件存在**就是**注册、删掉它就是注销；没有 `launchctl` 调用，也没有 UserDefaults
  标志位。macOS 13+ 走 `SMAppService.mainApp`，什么都不写。这是一条本地偏好而非 telemetry，因此
  不触碰上面那条规则 —— 但它是审计那条规则时唯一需要看的地方。
  应用**自己**的数据文件是另一回事，不在上面这句话的范围内：它始终拥有
  `~/Library/Application Support/FlowTrace/history.sqlite3`（连同 `-wal` 与 `-shm` 边车文件 ——
  备份后果见 `docs/ARCHITECTURE.md` §5.1），以及在 Debug 或设了 `ITRAFFICPLUS_FILE_LOG=1` 时写入的
  `~/Library/Logs/FlowTrace.log`。

## Active experiments

- **进程搜索栏（0.3.0 milestone 1）。** 在 `ListViewModel` 上加 `SearchFilter`，在 popover 顶部加
  `ProcessSearchBar` 视图。涉及 `ContentView.swift` 和 `ListViewModel.swift`。

- **内存级历史环形缓冲（0.3.0 milestone 1）。** 新增 `RingBuffer`、`HistoryStore` 和 `HistoryView`
  （60 采样小曲线图），挂在 popover 底部。涉及 `Network.swift`（推帧入 store）和
  `ContentView.swift`（承载 view）。

- **0.3.0 milestone 2（纯重构）。** 无新功能；把每个 `print` 替换为 `Logger`（走
  `FlowTrace/Feature/Logging/AppLogger.swift`），给 `Utils.formatBytes` 加 GB 档（之前 1 GB/s
  会显示成 `1024.0 MB/s`），把 @ObservedObject-on-singletons 的场景迁移到 @StateObject。
  非视图的 @ObservedObject（在 `Network` 和 `AppDelegate` 上）降级为普通引用，因为包装器对
  没有 `body` 的类型是 no-op。涉及 `AppDelegate.swift`、`Network.swift`、`NettopRunner.swift`、
  `ContentView.swift`、`StatusBarView.swift`、`Utils.swift`。

- **强调色子系统（0.3.0 milestone 17）。** `FlowTrace/Feature/Appearance/AccentColor.swift`
  是整个子系统（2026-09 从零重写）：`AccentColorManager`（真相源；keys `ft.accent.source` /
  `ft.accent.hex`；新装默认 custom + `#00CFFF`；通过 `AppleColorPreferencesChangedNotification`
  分布式通知监听系统强调色），`View.appAccentScope(_:)`（每个窗口根唯一应用点——应用
  `.tint` / `.accentColor` 并发布 `\.appAccent` 环境值），`AccentHexField`（校验 `#RRGGBB`
  输入）。窗口根（`ContentView.swift`、`SettingsView.swift` panes、`HistoryWindowView.swift`）
  observe manager 并调用 `.appAccentScope(accent.accent)`；手绘填充（排序下划线、热力图单元格、
  图例 swatch）读 `@Environment(\.appAccent)`。设置 UI：模式选择器（Follow system / Custom）
  + swatch + `ColorPicker` + 十六进制字段 + Reset。涉及 `ContentView.swift`、`SettingsView.swift`、
  `SettingsStore.swift`（没有强调色 key）、`HistoryWindowView.swift`、`HistoryHeatmapView.swift`。
  **规则 —— 每个独立托管的 SwiftUI 根都要应用 scope。** `.tint` 能到原生开关，所以不需要手写
  控件；但设置窗口每个 tab 一个 `NSHostingController`，没有共享父级可以着色。pane 拆出旧
  `SettingsView` 时 scope 被遗漏过，所有设置控件默默回退到系统强调色。`SettingsPane` 现在自
  应用它，任何新 pane 必须走 `SettingsPane`（或自己应用 scope）。

- **强调色全面到位（0.3.0 milestone 19）。** `.tint` 只到 SwiftUI 绘制的内容。AppKit 绘制的内容读
  app-wide semantic colours（来自**系统**强调色）—— 本机实测：`controlAccentColor` #FFC600、
  `keyboardFocusIndicatorColor` #FFFF1A、`selectedTextBackgroundColor` #8B7A3F、
  `selectedContentBackgroundColor` #D19E00 —— 这些都没法按应用/按控件通过公开 API 覆盖。所以
  需要显示自定义强调色时，控件必须在 `FlowTrace/Feature/Appearance/AccentControls.swift` 里
  手绘：
  - `AccentTextField` —— 无框 `NSTextField` 抑制原生焦点环，套一层 `.accentFieldChrome(isFocused:)`
    用强调色画环，并通过 field editor 的公开 `selectedTextAttributes` 改写文本选区颜色。AppKit
    仍拥有编辑（field editor、IME、undo）；只有环、边框和选区色是我们的。
    **触发 tint 和焦点标记的位置很重要。** 看起来正确但**实际沉默不工作**：通过 app 的事件队列
    投真实点击测得 `controlTextDidBeginEditing` 在「仅把 caret 放进字段」的点击中**不**调用 —— 只在
    文本真正被修改时触发。所以高亮保留了平台色（`#5C7654`，即系统强调色），强调环在 idle 状态，
    caret 静静坐着，caret 已在字段里 —— 即使每条编程路径都声称成功。两个 tint 现在由 field editor
    自己的通知驱动：`NSText.didBeginEditingNotification` 和 `NSTextView.didChangeSelectionNotification`，
    用归属检查 `(editor.delegate as? NSTextField) === ourField` 过滤。高亮或 caret 不可能在没有
    选区变化时出现，所以两者覆盖了所有情况。
    **提交是同一陷阱的另一半。** 拆解中的字段从不报 end-of-editing：设置窗口每次切 tab 都会重建
    pane 视图，关窗会拆掉整个 `NSHostingView`，两种情况都会让字段失去 first responder 而不 resign，
    `controlTextDidEndEditing` 不跑，于是输入被丢弃 —— 这就是设置里每个字段都看起来"没保存"的原因。
    提交必须在 teardown**之前**完成，view 还在的时候：`dismantleNSView` 里**不能**做——它跑在
    `NSHostingView.deinit` → `PlatformViewChild.destroy()` 里，从那里通过 `@Binding` 回写
    会触发 SwiftUI 排他性检查并 `EXC_CRASH / SIGABRT`。现用钩子：`controlTextDidEndEditing`
    （Return / 普通焦点切换）、`NSControl.textDidEndEditingNotification`（`object: field`）、
    `NSWindow.willCloseNotification`（匹配 `field.window`）。切 tab 的路径从另一端覆盖——
    `SettingsTabBar.commitPendingEdit()` 在翻转 `selection.tab` 前 resign，因为 SwiftUI `Button`
    点击后不会成为 first responder，所以不主动 resign 字段会带着焦点走。`updateNSView` 同理测试
    `field.currentEditor() == nil`，而不是从 `controlTextDidBeginEditing` 设的标志——用标志的话整个
    「点击然后输入」窗口会被当作"未在编辑"，重渲染会覆盖用户的首键。
  - `AccentPicker` —— 按钮 + popover 列表，所以 hover/selection 用强调色。自身按按钮大小调整
    popover，标记当前值，并用 `AccentColorManager.readableForeground(on:)` 给浅色强调色选前景。
  - `AccentDateField`（共享）—— 月历网格，本地化，hover/今天/选中用强调色，`latest` 之后禁用。
    设置 Storage pane **和**历史窗三个范围过滤器（`HistoryWindowView`、`AlertLogView`、
    `AppUsageView`）都用；`AccentTimeField` 仍只在设置里（HH:MM:SS 入寝时间）。
    **规则 —— 手绘控件必须自己做本地化。** 没有任何自动机制：`Loc.l(_:)` 覆盖字面字符串，
    但系统格式化的（星期名、月份名、日期顺序）来自默认是系统 Locale 的 `Locale`。`AccentDateField`
    因此把整个 `Calendar` 钉到 `LocalizationManager.shared.locale`，每个 `DateFormatter` 都设置
    `.locale`。表头与网格必须共用一个 calendar：第一列和 1 号落在哪一列都从 `firstWeekday` 推导，
    分别解析会静默错位。
    用户能读到的日期都走 `Loc.dateFormatter(template:locale:)` 而不是字面 `dateFormat` —— **模板**让
    locale 决定字段顺序、分隔符、12/24 小时制。
    **手撸 formatter 是陷阱，order 是咬人的那一口。** `setLocalizedDateFormatFromTemplate` 在调用瞬间
    立即按 formatter 当时的 locale 解析模板；之后再设 `.locale` 改不动已解析的 pattern。这就是
    月份标题在中文系统上无论 app 切到哪种语言都渲染「2026年9月」的根因。`Loc.dateFormatter` 先设
    locale 再展开，所以调用点不准手撸。
    机器用时间戳保留为刻意例外：`CSVExporter` 和保留期去重 key 保持固定 ISO 格式，使其在任何
    地方都可排序和解析。
  **规则 —— 永远不要给桥接 AppKit 控件固定宽度。** `Picker(.segmented)` 和 `Toggle(.switch)` 是
  AppKit 视图：不按 SwiftUI `Text` 的方式换行或截断，而是绘制到旁边的任何东西上。测量与本历史窗曾
  硬编码的宽度对比：4 段范围选择器在英文下要 324 pt、法文下要 438 pt，原固定值是 300；每个接口开关
  在英文下要 116 pt、俄文下要 162 pt，原固定值是 100。两者现在都按固有宽度（`minWidth` 至多），
  由 `Spacer` 吸收剩余。固定宽度列里的 SwiftUI `Text` 没问题（会换行），但若换行会让行高错，
  请用 `lineLimit(1)` + `minimumScaleFactor`。
  **刻意接受的代价**：失去 NSMenu 键盘导航与滚动、系统焦点环、系统日历弹窗。"Follow system" 模式无此代价。
  **刻意例外**：popover 的进程搜索字段（`Feature/Search/ProcessSearchBar.swift`）仍是平台
  `TextField`，所以其文本选区跟随**系统**强调色。app 内其它所有文本字段都是上面这些手绘控件之一。
  **设置工具栏的 tab chrome 刻意不动。** 给选中 tab 的图标上色曾被试过又被回滚：给
  `NSToolbarItem.image` 喂非模板符号会改变 AppKit 绘制整个 item 的方式（图标**和**标签），重新赋值
  image 又会让 AppKit 重建 item 并丢掉工具栏的选中项 —— 现象是 pane 跳回第一个 tab。所以 tab bar 保留
  AppKit 的原生渲染，选中高亮跟随系统强调色。涉及 `AppDelegate.swift`、`SettingsView.swift`、
  `AccentColor.swift`、`HistoryWindowView.swift`、`AlertLogView.swift`、`AppUsageView.swift`，以及新建的
  `AccentControls.swift`。

- **设置窗口（0.3.0 milestones 18, 22）。** 一个普通 `NSWindow` 承载 `SettingsRootView` ——
  pane 上方**手绘的** tab bar —— 由 `AppDelegate.showSettingsWindow()` 懒创建，按 pane 调整高度
  不带动画。`SettingsView.swift` 现在只是窗口外壳（`SettingsTab` / `SettingsMetrics` /
  `SettingsRootView` / `SettingsTabBar` / `SettingsPanes`）；自 2026-09 文件拆分后，每个
  `SettingsTab` 一个 pane 在自己的 `Settings*Pane.swift` 中，共享 `SettingsRow` / `SettingsNote` /
  `SettingsPane` / `SettingsSwitch` / `EditableNumberField` / `AccentTimeField` 这些
  `SettingsComponents.swift` 的组件 —— 系统字体与语义文本样式，无硬编码点尺寸。除非需要展示
  自定义强调色，控件都是平台控件（参见里程碑 19）：`Toggle(.switch)`、`Picker`、`ColorPicker`、
  `Stepper`、`NSAlert`。
  **tab bar 手绘（milestone 22）**，不是 `NSTabViewController` 的 toolbar tabs。AppKit 的
  preferences-toolbar 选中态会把选中项的**图标和标签**用系统强调色着色，无法覆盖 —— 但我们需要中性
  的高亮、无颜色变化 —— 所以 tab bar 是五个 SwiftUI 按钮，全状态都用 `Color.primary`，选中仅用
  背景表达。丢掉 tab controller 也消除三个 AppKit 陷阱：子视图控制器改写窗口标题（变成 "Untitled"）、
  item image 需重赋值（会丢工具栏选中）、工具栏标签需要手动本地化刷新。接受的代价：窗口没有原生
  工具栏 chrome，且 pane 每次切换重建，所以它的本地 `@State` 会丢失。
  **resize 窗口要放在 `@Published` 通知之外。** pane 完成 resize 延后一个 runloop
  （`selection.$tab.sink { DispatchQueue.main.async { applyPaneSize(for: $0) } }`）。在 sink 内同步
  resize 会让窗口大小变但 pane 不变 —— sink 在属性写入**前**运行，所以同步 `setFrame` 在 SwiftUI
  更新中重入 AppKit。同族陷阱见 `.trellis/spec/guides/swift-combine-swiftui-pitfalls.md`。
  涉及 `AppDelegate.swift`、`SettingsView.swift`、`HistoryWindowView.swift`、`AccentColor.swift`。

- **本地通知投递（0.3.0 milestone 15、16；2026-09 重做）。** 配额提醒与进程告警都走同一个可注入的缝：
  `FlowTrace/Feature/Usage/LocalNotification.swift`（`typealias NotificationDelivery` +
  `LocalNotification.deliver`）。它在调 `add` **之前**先读 `getNotificationSettings().authorizationStatus`，
  因为未授权时 `add` 同样返回 `error == nil`（本机实测）—— 相信那个 error 的调用方会把告警记成
  「已发出」并永不再试。配额只在投递成功后才写 fired key；告警监视器**先投递、成功后才写**它
  `process_alert` 的去重行；被拒时两者都退避 15 分钟，以免权限被关时每次检查都尝试并刷日志。
  `AppDelegate` 启动路径在这里也动了上游代码：调用 `SharedStore.quotaMonitor.bootstrap()` ——
  该监视器是惰性 `static let`，不触碰则 `init`（连同它的订阅）永不执行，此前配额功能因而彻底是死的 ——
  以及 `requestNotificationAuthorizationIfNeeded()`：仅在状态为 `notDetermined` 时申请；为 `denied` 时除了记 error，
  还会弹启动引导窗（说明哪些提醒将无法送达 + 直达 系统设置 → 通知 的按钮 + 「不再提醒」永久抑制，
  抑制键为 `notificationLaunchReminderSuppressed`；XCTest 下抑制弹窗——启动期 `runModal()` 会卡死整个
  测试套件，见「构建」一节）。
  设置里的「配额」「示警」「存储」三个 pane 把同一状态可视化：各自持有一个 `NotificationPermissionModel`
  （`@StateObject`，pane 出现时刷新 —— pane 每次切 tab 都会重建 —— 以及开关/选择器申请后刷新），
  `NotificationPermissionWarning`（`SettingsComponents.swift`）在「通知能力已启用但系统不可用」时显示橙色内嵌行：
  `denied`（按钮直达 系统设置 → 通知）或 `notDetermined`（按钮直接申请）；存储页对应的是清理方式 = 提醒模式。
  涉及 `AppDelegate.swift`、`QuotaMonitor.swift`、`ProcessAlertMonitor.swift`、
  `DataRetentionController.swift`、`SettingsQuotaPane.swift`、`SettingsAlertsPane.swift`、
  `SettingsStoragePane.swift`、`SettingsComponents.swift`，以及新增的 `LocalNotification.swift`。

- **接口分类优先级（0.3.0 milestone 9；2026-09 修正）。** `InterfaceClassifier.classify` 现在把两个名称启发式
  放在硬件端口表**之前**（`awdl0`/`llw0` → Local Direct，`bridge*` → Other），然后查端口表（端口名含
  `wifi`/`wi-fi` → Wi-Fi，含 `usb`/`ethernet`/`thunderbolt` → Wired），最后数字 `en*` → Wired。原顺序里有三处
  错误或不可达：`== "wifi"` 永不命中，因为 `networksetup` 报的端口名是 `Wi-Fi`，lowercase 后是 `wi-fi`，
  于是本机的 Wi-Fi 网卡（`en1`）被归到 Other；`dropFirst()` 应为 `dropFirst(2)`，`en13` 等动态接口也因此
  落到 Other；而 `bridge0` 因端口名 `Thunderbolt Bridge` 先命中 `thunderbolt` 而永不到达 bridge 分支。
  这是分支自有代码（非上游），但行为记录在 `docs/ARCHITECTURE.md` §4.3。`InterfaceClassifierTests` 里保留了
  一个用本机真实 `networksetup -listallhardwareports` 输出构造的回归用例。

## 总结一句话

**AGENTS.md 是最终仲裁者**。spec 与 AGENTS.md 冲突时以 AGENTS.md 为准
（agent 也按这条规则运行）。
