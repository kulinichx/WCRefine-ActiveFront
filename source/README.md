# WCRefineGroup 源码修复候选

日期：2026-10-31  
源码标识：`1.9.9-source`  
最终产品文件名：**`WCRefineGroup.dylib`**

## 当前交付状态

此目录包含修复源码和已通过 Apple 工具链构建的候选产物，**尚未真机验收**。

- 原始源码位于 `G:\WCRefine\WCRefineGroup\源码\ActiveFront.m`，没有改动。
- 原始源码 SHA-256：`49e1c7c667ffdbe43e27c83d902c74f9e161f8b027f463ec1a8d5b381473c786`。
- 工作区根目录的 `WCRefineGroup.dylib` 仍是先前的 `offline-hotfix2` 二进制。
  它不包含本轮源码修复，SHA-256 仍为
  `118a29784faf6675a8e7176dda4db4cc395b6cef68ac8786bdce295eaa316819`。
- 新编译版位于 `source/build/WCRefineGroup.dylib`，187,088 字节，
  SHA-256：`a77c2076e90dfd52f6cc51c7288ec24f8621732d386cb9352d9de7873568d632`。
- 本机为 Windows；已使用既有 GitHub Actions 的 macOS/Xcode 环境，
  完成 26 项原生 Foundation 测试、iOS ARM64 编译/链接、
  `codesign --verify` 和结构验收。构建日志零警告。
- 成功构建提交为 `679c6bf077bdc73f703ba6969e99870fec08e615`，
  Actions run 为 `41169629952`，Xcode 16.4 / iPhoneOS SDK 18.5，
  目标 ARM64、最低 iOS 14.0。具体证据见
  `../audit/source_build_acceptance.json` 和 `../audit/ci/41169629952/`。
- 下载压缩包哈希、二进制哈希、编译输入哈希均已在本地再次核对；
  CodeDirectory 代码页哈希检查通过。未验证设备签名信任与注入效果。
- 不应把根目录的旧二进制重命名、重新计算版本号后冒充本轮源码构建产物。

## 源码改动

### 账号与持久化

`WCRAFStateStore.h/.m` 将名单、保持时间和天数合为一个账号记录：

```text
com.local.wcrefine.activefront.account.v2.<当前 wxid>
```

记录含 `schema=2`、`held`、`since` 和 `days`。一次保存同时更新这些字段。
当前账号通过所提供 WCRefine 2.1-9 样本中的
`+[WCRefineHelper wcr_resolveCurrentUserWxidUncached]` 获取。
账号无法确认时禁用状态操作，不使用共享名单兜底。

检测到账号变化或暂时为空时，废弃内存缓存和异步任务，递增账号代次。
UI 行、按钮、延迟弹窗、弹窗回调以及状态刷新携带原账号上下文；
过期上下文不能写入状态或继续分组操作。持久化键永远由捕获的上下文生成，
不拿“刚刚切换到的账号”替换写入目标。

未知 schema、错误容器类型和非法字段不自动覆盖。
正常旧记录仅缺少保持时间时，可以将缺失项补为当前时间；
绝不按暂时为空的分组快照裁剪名单。
保存期间拒绝同步回调中的嵌套写入，并在保存后再次确认账号，
避免持久化通知切号后把旧账号快照装入新账号缓存。
持久化读写异常安全退出；写入异常会禁用当前账号的内存状态，
等待切号或重启重新加载，不再用可能失配的缓存继续清理。
时钟抛异常或返回无效值时，不续期、不提交过期删除。

账号代次取决于本插件实际观察到的账号值变化。没有新增未经验证的微信账号通知，
不能宣称能检测两次查询之间未被观察到的完整 A→B→A 切换。
多线程账号切换、微信内部加载时序仍需要设备验证。

### 过期处理

- 候选包含账号上下文、整体版本、逐联系人版本、保持时间、天数和批次。
- 队列票据不能取走后来批次；重新保持、修改设置、通知失效等撤销旧快照。
- 某个联系人重新被判定有效时，只撤销该联系人的快照，不使同批其他项饥饿。
- 实际提交前通过
  `-[WCRefineGroupDataProvider fulfilledSessionForUsername:fallback:]`
  重新获取会话，明确传 `fallback:nil`，不回退到排队时的旧对象。
- 重新检查用户名、账号、分组、保持时间、设置和最新消息时间。
  获取失败、异常、时间未知/非有限值时保留持久化标记。
- 一批中成功删除第一项不递增整体版本，其他有效项仍可提交；批末统一刷新。

上述方法存在及 ABI 已与给定主插件元数据核对。
“重新获取”仍受微信会话服务自身缓存和对象更新时序限制，不能视为消除了所有消息竞态。
过期策略查询仍按原语义对已过期项执行未读回退；持久化清理由异步提交负责。

### 分组开销与日志

主线程的一轮同步查询可共享自定义分组 ID 和成员并集。
缓存由主队列后续任务清空，也在分组变化通知、本插件分组修改时失效，
并与账号代次绑定。不缓存空的初始分组快照。
成员类型不支持或非主线程时使用原接口查询。
禁用分组仍计入归属判断，保留原语义；选择目标分组的 UI 继续过滤禁用项。

未引入周期定时器。Group 私有日志在默认发布构建中关闭。
没有测量 CPU、掉帧、唤醒率和能耗，不承诺实际省电幅度。

## 旧记录如何处理

旧共享键没有账号归属，**不会自动导入，也不会删除原件**。

新版本长按“保持/回组”按钮，在保持期限中选择“导入旧版保持记录…”，
再确认记录属于当前账号。新导入项从导入时刻开始计时，已有项不续期。
只有当前账号尚无 v2 记录时，才采用合法的旧天数设置。
在确认窗口期间切号，原确认操作失效。

不要因为升级后名单暂时不见，就对不属于该账号的旧名单执行导入。
回退旧二进制只能看到旧共享键；新版本的账号隔离记录不会反向同步到旧键。

## 编译与验证

在安装完整 Xcode 和 iPhoneOS SDK 的 macOS 中运行，必须同时编译两个 `.m`：

```bash
bash source/test_core.sh
bash source/build_ios.sh
```

从 `source` 目录运行时去掉命令中的 `source/` 前缀。
构建脚本首先运行真实的 Foundation 状态测试，失败即停止。
随后生成 ARM64、iOS 14 起的动态库：

```text
source/build/WCRefineGroup.dylib
source/build/WCRefineGroup.dylib.sha256
```

构建不覆盖根目录已测二进制，不上传源码。
脚本采用系统 framework 和 Objective-C runtime，不硬链接 WCRefine 私有类；
没有用 `dynamic_lookup` 掩盖缺失的实现。
最后执行 ad-hoc 签名验证、依赖检查和哈希输出。
每次构建使用独立暂存目录，通过测试和验收后才替换 `source/build/` 的输出。
原生测试生成 JSON 结果，并将编译输入的哈希快照交给 `verify_build.py`；
源码中途改变、报告失败、平台/文件名/依赖不符时拒绝验收。
`build_manifest.json` 记录源码哈希、二进制哈希和原生测试结果；
结构检查器不冒充 Apple 的签名验证器，签名另由 `codesign --verify` 检查。
这不代替隐根设备的签名信任、注入顺序或安装适配。
`build/` 中若留下失败构建产物，也不能视为可发布文件；
只有脚本整体成功并完成设备验收后才应替换使用。

`tests/StateStoreTests.m` 包含 26 个原生测试方法，覆盖账号隔离、空账号、
A→B→A 旧上下文、批次取出后续期/设置往返/撤销、逐联系人失效、
旧回调与新批次、多候选提交、未知时间、重新载入、
错误记录保护、显式迁移、非法时钟、持久化异常、保存回调内切号/嵌套写入，
以及仅有孤立时间戳的协调。它直接链接真实 `WCRAFStateStore.m`，
不是 Python 仿制模型。**26 项已在 macOS CI 实际执行并全部通过；
它们不是 UIKit 测试，也不是 iPhone 真机测试。**

Windows 可执行的源码静态契约检查：

```powershell
& 'C:\Users\KOKOL\AppData\Local\Programs\Python\Python314\python.exe' -X utf8 audit/check_source.py
```

输出 `audit/source_checks.json`，记录源码哈希、原件校验、
私有 selector/ABI、残留旧调用、参数数量和词法结构等。
此检查不是 Objective-C 编译器，不证明 ARC、链接、UIKit 或运行时正确性。
另外可运行 `audit/test_source_build.py` 的 18 项构建验收器测试，
检查错误架构、平台、依赖、报告和源码哈希是否被拒绝。
其中 Mach-O 测试使用结构样本，不是真实 dylib 编译或签名测试。

先前二进制的 38 项发布测试和 13 项 hotfix1 回归已重跑通过；
这些结果不属于新源码。ARM64 模拟执行的 Objective-C 服务仍由测试桩提供。

## 既有 GitHub 构建工程

项目记录指向 `C:\Users\KOKOL\WCRefine-ActiveFront`，当前分支为
`feature/active-front`。旧流程只编译根目录 `ActiveFront.m`，
不能直接用于本轮新增的状态核心。

`ci/build-dylib.yml` 是待同步的替换配置，放到工程的
`.github/workflows/build-dylib.yml`，并将本目录的源码/测试/脚本放到工程 `source/`。
新流程直接调用 `source/build_ios.sh`，不使用旧的单文件 Theos Makefile；
产物仍叫 `WCRefineGroup.dylib`，附带原生测试日志和验收清单。
Runner 使用 `macos-15`；Action 固定到已核对的提交，而不是浮动标签。

已取得许可并同步到既有工程、推送 `feature/active-front`。
首轮定位到缺少 CoreGraphics 链接，第二轮验收发现报告布尔值类型错误；
修正后成功构建提交为 `679c6bf077bdc73f703ba6969e99870fec08e615`。
此前失败构建未作为完成产物交付。原工程已有的未跟踪 Python 文件未加入提交。

本地 `source/build/` 是本轮验收产物；根目录旧补丁刻意保留不动。
实际测试应使用新编译文件，不要把根目录旧补丁误认成本轮版本。

## 设备验收清单

- 单账号保持/回组/分组、期限设置与重启持久化。
- 两账号含相同联系人；A→B→A；退出登录与账号未就绪。
- 弹窗打开或延迟动作排队后切号，确认不会影响新账号。
- 入队后新消息、重新保持、更改期限、修改分组或联系人被移出分组。
- 空分组加载、获取会话失败、未知时间时不丢失保存的标记。
- 原未读设置开/关与设置页显示值；群聊与好友边界。
- 左滑原菜单、右滑、长按、快速滚动、复用行、冷启动可见行和 iPad 弹窗。
- 隐根环境签名/注入、崩溃日志和真实 CPU/耗电对比。

同一进程不要同时加载旧版 Group 与新版 `WCRefineGroup.dylib`，
也不要把主插件 `WCRefine.dylib` 当作 Group 文件替换。
