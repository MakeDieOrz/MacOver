# PlayTools (MacOver 1.0)

[English](./README.md) · **简体中文**

`PlayTools` 是 [MacOver](../README.zh-CN.md) 注入至目标应用内的 Mac Catalyst（`arm64`）运行时框架（基于 `PlayCover/PlayTools@e222ce0` 衍生，遵循 **AGPL-3.0** 协议）。它直接跟随 `PlayCover.xcworkspace` 原生构建（无需 Carthage 或外部补丁），并与 `AKInterface.bundle` 协同工作，提供显示控制、键位映射、系统环境虚拟化、Safe Mode 崩溃恢复及可扩展用户插件支持。

## 核心能力

### 显示控制与 Sequoia 窗口桥接

支持按应用粒度配置显示与外观参数：

- 分辨率预设（`1080p`、`4K`、`1440p` 及自定义宽高）
- 纵横比设置（`16:9`、`16:10`、`4:3` 及自定义比例）
- 自定义缩放因子（`1.0`、`1.5`、`2.0` 等）
- 游戏内窗口方向切换与旋转
- 应用分类（`LSApplicationCategoryType`，例如设为 `game` 以归入“屏幕使用时间”游戏分类）
- 自定义 Discord Rich Presence 动态与设备型号伪装

针对 macOS 15 Sequoia 及更新版本，`AKInterface.bundle` 与 `PTCoordinateMath` 提供显式 AppKit `NSWindow` 几何与方向同步桥接，以兼容新版 macOS 窗口层级变更。

### 键位映射与触控转换

将桌面端输入实时转换为 iOS 多点触控事件（基于 `PTFakeTouch` 与 `PTCoordinateMath`）：

- **支持外设**：键盘、鼠标、触控板、游戏手柄
- **映射动作**：点击按钮（Button）、摇杆（Joystick，如 WASD）、视角控制（Camera Control）、拖拽轮盘按键（Draggable Button）

### 模块化运行时子系统（`PlayTools/PlayTools/Subsystems/`）

PlayTools 将原本高度耦合的运行时 Hook 拆分为职责清晰的子系统单元：

- **`PTFSVirtualizer` / `PTFSVirtualizerObjC`**：沙盒容器路径虚拟化、词法路径归一化与敏感路径隐藏保护。
- **`PTDyldVirtualizer`**：dyld 动态库映像过滤，拦截 `dlopen`、`dlsym`、`objc_*` 等符号/类探测请求。
- **`PTSystemSpoofer` / `PTSystemSpooferObjC`**：设备型号、`sysctl`/`uname`、环境变量与系统信息伪装。
- **`PTEntitlements`**：`csops` 签名状态、`ptrace` 调试检测及 Entitlement 查询兼容。
- **`PTNetworkVirtualizer`**：按应用生效的规则化网络拦截层（`PTNetworkBlockProtocol`）。
- **`PTGraphicsVirtualizer`**：Metal 与图形缩放 Hook。
- **`PTRegistration`**：线程安全的动态反检测注册表，彻底解耦核心运行时与第三方/用户插件元数据。
- **`PTDebugTrace`**：TLV 安全、防重入递归且保持 `errno` 不变的 C/ObjC 系统调用追踪模块。

### PlayChain（`PlayedAppleDB`）

`PlayedAppleDB` 为在 macOS 上受 Keychain 权限或登录异常影响的应用提供本地 SQLite 替代存储。在进行数据库结构升级前（例如旧版 v1 / WAL 迁移），`PlayedAppleDBBackup` 会自动创建原子化预迁移备份以防止凭据丢失。

---

## Safe Mode 安全模式（`PTSafeMode`）

为避免插件冲突或错误配置导致目标应用陷入启动闪退循环：

1. 启动时会在应用专属 PlayTools 缓存目录写入 `.launching_in_progress` 面包屑标记；当应用稳定运行超过启动窗口后自动清除。
2. 若应用在启动初期（`< 3 秒`）发生异常崩溃退出，下次启动会自动触发 **Safe Mode** 并向宿主机汇报安全模式告警：
   - 跳过加载 `UserPlugins/` 中的用户插件；
   - 停用自定义网络过滤规则；
   - 将渲染缩放因子（`customScaler`）暂时回退至 `1.0`。
3. 正常退出后会自动清理安全模式状态，后续启动恢复正常缩放与插件加载。

---

## 用户插件规范（`PTPluginContainer` & `PluginManifest.json`）

宿主机在安装及每次启动时会通过 `PlayTools.syncUserPlugins` 将如下目录中的插件同步至目标应用 `Frameworks/UserPlugins/`：

```text
~/Library/Containers/app.makedie.MacOver/PlayTools/UserPlugins/<bundleID>/
```

目录型插件或与 dylib 配对的 `<PluginName>.manifest.json` 遵循 `PTPluginManifest` 结构：

- `manifestVersion`：清单版本号（如 `"1.0"`）
- `identifier`：插件反向域名标识
- `name`：插件显示名称
- `version`：插件版本号
- `minPlayToolsVersion`：最低兼容的 PlayTools 版本（如 `"1.0.0"` 或 `"0.0.0"`）
- `targetBundleIdentifiers`：允许加载的目标应用 Bundle ID 数组（或 `["*"]`）
- `loadPriority`：加载优先级整数（数值越小越早加载，默认 `100`）
- `capabilities`：声明能力标签数组
- `entrypoint`：插件目录内入口 `.dylib` 文件名

插件可通过 `PlayTools/PlayTools/Subsystems/PTRegistration.h` 导出的 C ABI 动态向核心反检测注册表隐藏自身映像与类：

- `pt_register_hidden_module(const char *image_name_fragment)`
- `pt_register_hidden_class(const char *objc_class_name)`
- `pt_register_hidden_image_header(const void *mach_header)`

> 当 `PTSafeMode` 激活时，所有 `UserPlugins/` 加载都会被自动跳过。

---

## 运行时诊断追踪（`PLAYTOOLS_DEBUG_LOG=1`）

在目标应用环境变量中设置 `PLAYTOOLS_DEBUG_LOG=1` 时，`PTDebugTrace` 无需挂载调试器即可向 `stderr` 输出 TLV 安全、防递归且不破坏 `errno` 的拦截追踪日志，格式为：

```text
[PlayTools] [<subsystem>] <function>: <message>
```

可观测 `spoofer`、`dyld`、`fs`、`entitlements`、`network`、`graphics`、`reg` 等子系统的实时拦截与注入事件。

---

## 工作原理

IPA 安装阶段由 `PlayCoverMachO` 校验 Mach-O 架构并在二进制中写入 `LC_LOAD_DYLIB` 依赖以指向 `PlayTools.framework`。目标应用启动时，由 `PlayLoader` 在安全的初始化时序下完成子系统与 TLV 就绪初始化，加载 `AKInterface.bundle`、校验 `PTSafeMode` 与 `PTPluginContainer`，并将桌面输入与窗口几何状态实时桥接给 iOS 应用。

PlayTools 的本地化资源文件统一命名为 `PlayTools.strings`，以避免与目标应用自身的 `Localizable.strings` 发生冲突。

---

## 构建、静态分析与测试

`PlayTools` 现直接作为面向 macOS 26.0+ 的 **Mac Catalyst（`arm64`）** 原生目标通过 `PlayCover.xcworkspace` 或 `PlayTools/PlayTools.xcodeproj` 编译；旧版 Carthage 工作流与手动 `Debug-iphoneos` + `vtool` 转换脚本均已废弃。

### 跟随主工程全量构建

在仓库根目录执行以下命令即可自动编译并内嵌 `PlayTools.framework` 与 `AKInterface.bundle` 至 `MacOver.app/Contents/Frameworks/PlayTools.framework`：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCover \
  -configuration Release \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```

### 单独构建 PlayTools 与运行单元测试

```sh
# 单独构建 Mac Catalyst (arm64) PlayTools
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project PlayTools/PlayTools.xcodeproj \
  -scheme PlayTools \
  -configuration Debug \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

# 运行 PlayToolsTests 单元测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -workspace PlayCover.xcworkspace \
  -scheme PlayCoverTests \
  -configuration Debug \
  -only-testing:PlayToolsTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  test
```

### 静态分析与实时集成验证

```sh
# 校验 .clang-format / .clang-tidy 并运行 Clang Static Analyzer（目标 0 告警）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./ci/run_static_analysis.sh --check-format

# 启动真实 Mac Catalyst 进程验证注入、Safe Mode、PluginManifest 与 PLAYTOOLS_DEBUG_LOG=1
python3 Tests/RuntimeHarness/run_runtime_harness.py \
  --playtools-framework <path/to/PlayTools.framework> \
  --verbose
```

## 构建产物

- **`PlayTools.framework`**：注入目标 iOS 应用的 Mac Catalyst 核心动态库框架。
- **`AKInterface.bundle`**：位于 `PlayTools.framework/PlugIns/AKInterface.bundle` 的原生 AppKit 桥接包，负责鼠标/键盘控制与 macOS 15 Sequoia 窗口几何桥接。
- **`PlayTools.strings`**：各语言包（`*.lproj/PlayTools.strings`），在安装和启动时同步到目标应用容器中。
