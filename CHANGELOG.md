# 变更记录

各端分开版本：**控制台**（Hana v2 App，`apps/hana-desktop-pet`）、**macOS 桌宠**（Swift + AppKit，`pet-macos`）和 **Windows 桌宠**（WPF，`pet-windows`）。公开基线是控制台 `0.6.6` / 协议 v3 / macOS `0.5.8` / Windows `0.2.0`；上一轮配套版本是控制台 `0.6.7` / 协议 v4 / macOS `0.5.9` / Windows `0.3.0`；本轮已发布控制台 `0.6.8` / macOS `0.5.10` / Windows `0.3.1`（协议仍为 v4），控制台下载入口已跟到这两版桌宠；各端只需下载所用平台的桌宠，市场收录进度以市场条目为准。

逐轮的详细记录（任务边界、验证数据、未验证项）在 [`docs/迭代记录.md`](docs/迭代记录.md)。

## 控制台 0.6.8 — 2026-10-22

- **下载入口跟到带铁盆功能的桌宠**：`PET_DOWNLOADS` 与 `panel.html` 的两个备用链接改为 Windows `windows-0.3.1` / macOS `pet-0.5.10`，安装说明的来源提示同步改为 `windows-0.3.1`。仍是固定白名单、仍只经 `hana.external.open`，没有新增网络抓取、自动下载或安装能力。
- **版本文档**：README 的本轮版本行、安装步骤与 Windows 源码状态跟到 `0.6.8 / 0.5.10 / 0.3.1`。
- **配对守卫**：`tests/desktop-compat.test.mjs` 新增 `0.6.8 → Windows 0.3.1 / macOS 0.5.10`（协议 4），保留 `0.6.7` 与 `0.6.6` 两组；`tests/panel-onboarding.test.mjs` 里控制台钉住的版本同步为 `0.3.1` / `0.5.10`。
- 协议 v4、DTO、manifest 能力、localhost 声明与素材目录一律未动；App 包内 `ATTRIBUTION.md` 已是含铁盆署名的版本，重打包逐字节带出。
- 验证：`sh tools/run-checks.sh` exit 0（Node 186/186，面板布局在 560×664 无溢出）；官方 validator `--dir` 与 `--archive dist/app-hana-desktop-pet-0.6.8.zip` 均 0 error / 1 已知 warning（`DYNAMIC_DEPENDENCIES_NOT_PROVEN`）；包内 606 个文件与源码逐字节一致。
- 发布：`console-0.6.8`（Latest），附件 `app-hana-desktop-pet-0.6.8.zip` + `.entry.json`；`dist/app-hana-desktop-pet-0.6.7.zip` 保留不删（PR #124 原审版本）。市场 PR #124 在**同一分支**追加 commit 更新 `approvals.json`。

## 桌宠 0.5.10 / Windows 0.3.1 — 2026-10-22（已发布）

双击扣铁盆功能与本轮按角色调参的正式版本：macOS `0.5.10`、Windows `0.3.1`、协议仍是 v4；两个 Release 分别在标签 `pet-0.5.10` 与 `windows-0.3.1`（提交 `4031b70`）。控制台保持 `0.6.7`（其下载地址仍指向 macOS `0.5.9` / Windows `0.3.0`，下次控制台发版再跟随；App 包内 `ATTRIBUTION.md` 已是新文本）。

- **双击扣盆**：双击桌宠会在头上扣一只铁盆，可连续叠加（上限 10 只）。每只从上方 20pt 掉落并弹一下；第 11 只进来时最底下一只淡出、其余下沉一格重新压回头顶。切换角色立即清空，退出随进程消失，不落盘。
- **纯表现层**：盆只跟窗口坐标，不随呼吸/摇晃/拎起帧抖动；不写姿态、活动状态或工作节奏，协议 v4、DTO、manifest 与 catalog 一律未动，控制台未改。
- **实现**：新增纯模型 `pet-macos/Sources/PetCore/PetBasinStack.swift` 与 `pet-windows/HanaDesktopPet.Core/Animation/PetBasinStack.cs`（几何、掉落/下沉/淡出、上限、双击判定），渲染分别接在 macOS `draw(_:)` 与 Windows `DrawCurrentFrame()` 的现有绘制通道里；不加图层、不加依赖、不新增计时器（唤醒合并进原有单一 deadline）。
- **素材**：新增 `assets/crosspet/shared/basin.png`（117×47 通用铁盆；非 catalog 立绘、非 CrossPet 上游素材，按 CC BY-NC-SA 4.0 随包使用，署名写进 `ATTRIBUTION.md`）。查找顺序 `{角色ID}/basin.png` → `shared/basin.png` → 代码内矢量盆；缺图或解码失败仍能画出盆，不崩溃。
- **按角色调参**：右键菜单「铁盆调试…（宽×高）」打开一个浮动面板，当前角色的**宽度 / X 偏移 / Y 偏移**三条滑块（60–120pt、±30pt、10–80pt），拖动即时重绘；「保存」把该角色的配置写进偏好，「重置」清掉覆盖、回到内置表。高度固定按素材 117:47 比例由宽度算出，不做拉伸。
- **七个角色的定稿参数**（用户逐角色实测后写死进 `characterConfigs`，macOS 与 Windows 同一组数值）：claude `112.66 / -3.44 / 43.39`、gpt `98.12 / -3.06 / 42.95`、deepseek `112.28 / -9.57 / 46.07`、gemini `107.69 / -4.59 / 41.61`、glm `97.36 / -3.44 / 37.59`、deepseek-hoodie `109.98 / -12.63 / 52.77`、gpt-onesie `112.66 / -5.36 / 42.50`（宽度 / X 偏移 / Y 偏移，单位 pt）。
- **拎起不再变小**：`picked-up` / `picked-up-2` 两帧的可见内容只有 ~163–165pt 高、头顶还低 5.5pt，现在按不透明内容框缩放并上移，拎起来时角色与 idle 同高、头顶仍在同一条线上，盆继续扣在头上。
- **窗口与气泡**：窗口为盆预留顶部透明空间（245×217 → 245×300，全透明可穿透，角色屏幕位置不变，调尺寸不改变窗口大小）；气泡改为挂在盆堆顶上方，顶部角落停靠按立绘顶边对齐，保证无盆时与改动前视觉一致。
- **版本与守卫**：macOS `0.5.10` / Windows `0.3.1` / 协议仍 v4。控制台不重打，下载地址仍指 `0.5.9` / `0.3.0`；`tests/desktop-compat.test.mjs` 与 `tests/panel-onboarding.test.mjs` 把「控制台钉住的下载对」与「仓库里的桌宠版本」分开，只要求后者不旧于前者（桌宠可以先打补丁版）。
- **打包**：`dist/HanaDesktopPet-crosspet-v0.5.10-local.app` + `.zip`（ad-hoc 签名，`unzip -t` 无错误）；Windows `0.3.1` 便携包**本机无法产出**（没有 `csc.exe`），需要在 Windows 上跑 `python3 tools/build-windows-portable.py`。
- 验证与未验项见 [`docs/迭代记录.md`](docs/迭代记录.md)；Windows C# 本轮**未编译**（本机无 `csc.exe`）。

## 控制台 0.6.7 / macOS 0.5.9 / Windows 0.3.0 — 2026-10-20

- **修掉串版下载**：0.6.7 候选是协议 v4，下载入口却还指向 v3 的 Windows 0.2.0 / macOS 0.5.8，用户点下载会拿到与 v4 控制台不兼容的桌宠。`PET_DOWNLOADS` 与 `panel.html` 备用链接统一改为 Windows `windows-0.3.0` / macOS `pet-0.5.9`；安装说明的来源提示同步改为 `windows-0.3.0`。两处地址仍是固定白名单，仍只经 `hana.external.open` 打开，未新增网络抓取、自动下载或安装能力。
- **保留公开基线**：0.6.6 / 协议 v3 的包与旧地址（Windows 0.2.0、`console-0.6.5` 里的 macOS 0.5.8）原样保留，不重写已发布包、不覆盖旧附件。当前市场收录的 0.6.6 经统筹核对与公开 asset 一致，没有已确认的版本错配。
- **Windows 0.3.0/v4 源码回灌**：只回灌回传的 10 项实际差异，保留本仓库既有 Mac/控制台 v4 改动。修掉编译失败与测试失配；气泡改为按 Windows 向下坐标、从立绘实际顶边向上挂（原实现挂在脚下），扣除透明留白；DPI 统一换算；长字幕走两行档；圆角按 `height/2 - 3` 封顶；光晕/尾巴各自按窗口坐标裁剪；`version.json` 成为 0.3.0/4 的单一来源并由构建脚本校验 `PetAPI.cs`；`--check-assets` 增加台词表解析（7 角色 × 20 状态 × 2 = 280 条）。
- 兼容判定写进 `tests/desktop-compat.test.mjs`：0.6.6 → 0.2.0/0.5.8（协议 3），0.6.7 → 0.3.0/0.5.9（协议 4）；并守卫已发布 0.6.6 包与 Windows 0.2.0 附件不被改写成 v4、当前候选不出现旧 v3 地址。将来控制台小版本可共用同一桌宠，按协议与所需字段/功能判断，不要求版本号相等。
- 验证：`sh tools/run-checks.sh` exit 0（Node 184 项、拖拽 D 段 233 项恢复真实编译、E/F/G 与 PetCore 全过）；`build-windows-portable.py --check-assets-only` 211 张；`run-windows-checks.py` 在 macOS 按缺失 `csc.exe` exit 2；官方 validator `--dir` 与 `--archive dist/app-hana-desktop-pet-0.6.7.zip` 均 0 error / 1 已知 warning。`dist/HanaDesktopPet-windows-0.3.0-portable.zip` 原样复制自回传成品，SHA-256 不变。
- macOS 0.5.9 在 `.build/release-20261020/` 独立暂存重建（不改动 `dist/` 里正在运行的旧 `.app`），`ditto` 归档为 `dist/HanaDesktopPet-crosspet-v0.5.9-local.zip`：版本 0.5.9、211 张 WebP、`pet-lines.json`、许可/署名、图标齐全，arm64，ad-hoc 签名 `codesign --verify --deep --strict` 通过。
- **Windows 与真实 Hana 的联动**：用户已于 2026-10-20 实测验收通过；统筹本轮未在 Mac 独立复跑（本机无 Hana v4 宿主）。Windows 端编译、合成检查与单屏 100% DPI 的 WPF/拖动/穿透证据来自回传报告。
- **验证边界**：Windows 与真实 Hana 的联动由用户实测通过；Mac 气泡版已有用户本地试用反馈。多屏/混合 DPI/负坐标、真实屏幕边缘夹紧、减少动态效果细节、Intel/旧 macOS 与新旧版本混装未完成专项验证。
- 发布顺序：先让 `windows-0.3.0` 与 `pet-0.5.9` 附件可用并核对，再发控制台 0.6.7，最后更新市场；旧公开 v3 附件与 Release 保留给旧控制台用户。

## 状态字幕气泡实现记录（2026-10-18，随上述版本发布）

以下保留 10 月 18 日的阶段性记录；Windows 最终编译、实机与用户联动验收以本轮 10 月 20 日记录为准。

- 桌宠气泡从「只在确认/完成时弹两行通知」扩展成**按状态出单行台词**：每个姿态对应一句字幕，让你知道她在干嘛。姿态→状态归一化表覆盖全部 47 个姿态名；词条 7 角色 × 20 状态 × 2 条，全部自写，不含上游 CrossPet 任何台词。
- 展示优先级：拎起 > 确认通知 > 完成通知 > 状态台词。通知的两行格式完全保持原样。单行台词最短停留 2.5 秒，期间来的新状态排队合并；带时长的状态到点收起且姿态不变就不回弹，`null` 状态常挂。
- 气泡外观定稿为「细描边 + 彩色光晕」：大圆角矩形（r18）、1pt 主题色描边、纯白不透明填充、独立小椭圆尾巴（22×15，1pt 描边）。描边外侧三层主题色光晕 + 一层中性落影，**只往上、左、右扩散，下方一个像素都不洇**（角色就在正下方）。窗口高度含光晕边距与尾巴：单行 64、折行 82、两行通知 78。
- 气泡贴近头顶：`gapAbovePet` 由 4 改为 0，尾巴尖正好贴住角色窗口顶边，不重叠不留缝。
- 协议 v4、DTO、manifest、权限、素材目录一律未动；台词表是原生层资源，靠姿态驱动，不读任何会话内容。
- 验证：`sh tools/run-checks.sh` exit 0。**Windows C# 本轮只改代码未编译**（本机无 `csc.exe`）；真实桌面视觉未实测，气泡外观用离屏渲染真实视图类验证。

## 控制台 0.6.6 — 2026-10-18

- 未连接时给出引导：说明为什么没连上、下一步做什么、按平台去哪下载。连接失败先提示启动现有桌宠，再给下载入口；协议不匹配保留原错误；连上后整块收起。不把「未连接」断言成「未安装」。
- 新增最小能力 `app/ui.open-external`（对应公开 SDK `hana.external.open`），只打开白名单里的两个固定 Release 附件地址。宿主拒绝或无此能力时，展示可选中、可手工复制的同一链接，不新增剪贴板或网络抓取能力。本机 localhost 声明与其余最小权限不变。
- 安装说明只保留可校验的来源提示与系统安全提示，不再给出任何「打不开 = 还没上线」一类关于发布状态的推断。
- 包内补齐许可与署名：`LICENSE`（MIT）、`assets/ATTRIBUTION.md`、`assets/CHARACTERS-LICENSE.md`，与仓库 canonical 文本逐字节相同。App 自带 README 同步改正：不再声称「archive 不含角色图片」或禁止一切对外分发，改为按 CC BY-NC-SA 4.0 说明允许非商业分发、需保留署名与相同方式共享。
- 验证：`sh tools/run-checks.sh` exit 0（Node 157/157），专项 `panel-onboarding-probe` 为 `PANEL_ONBOARDING_OK`，含「已连接多行 → 宿主读取失败」的状态转换实测；官方 validator `--dir` 与最终包 `--archive` 均 0 error / 1 warning。
- 发布：`console-0.6.6`（Latest）与 `windows-0.2.0` 已发布；首次 Hana 市场登记 PR 已提交（待维护者审核，尚未上架）。安装包与两个 tag 均指向 `05c1f08`。
- 仍未验证：真实 Hana 宿主里点击打开外链的实际效果，以及 `app/ui.open-external` 授予后的行为。

## Windows 0.2.0（单文件便携版）— 2026-10-18

- 形态：**预编译单文件**，7 个角色 211 张 PNG 全部内嵌（`Assets.bin` + 偏移索引），解压双击即用；不再首次启动现场编译，不再依赖旁边的 `CrossPet/` 目录。
- 运行时：`IPetAssetStore` 抽象 + `EmbeddedPetAssetStore`（按偏移在锁内 seek，不整块读入内存）与 `DirectoryPetAssetStore`（本地调试用）；DPI 开关从 sidecar config 移进 `Main`。
- 协议兼容放宽：`/v3/snapshot` 的 `activity` 必填集收窄为 `status` + `lastActivityAt`，其余字段缺失视为 `null`；旧控制台不受影响。
- 最终源码已回灌到 `pet-windows/`（含 `PetAssetStore.cs`）；素材由 canonical `assets/crosspet` 重建成 `102358834` 字节 blob，与已验收 exe 的 `embeddedArtworkBytes` 一致。
- 构建入口重定向到仓库布局：`python3 tools/build-windows-portable.py`（单文件出包，需 Windows `csc`）、`python3 tools/run-windows-checks.py`（C# 合成检查，仅 Windows）、`node tools/package-windows-pet.mjs --prepare-assets`（macOS 素材准备）。旧的首次启动脚本与 sidecar config 退役，旧预览打包入口现在直接报错。
- 验证边界：exe 编译与实机运行由作者本人在 Windows 实测；本仓库没有 Windows csc，**不把 macOS 侧检查当作 Windows 运行验收**。

## Windows 0.1.0-preview.1 — 2026-10-18（已被 0.2.0 取代，未单独发布）

- 新增独立 Windows WPF 桌宠，保留 Hana 控制台和 macOS 代码，继续使用固定 IPv4 loopback 端口及完整 v3 协议。
- 移植角色选择、状态过期、姿态/情绪/工作节奏、淡入淡出、点击和两帧拎起动画；提供透明置顶窗口、像素 alpha 命中、拖动、原生菜单、锁定和角落停靠。
- 便携测试包解压双击启动，首次使用系统自带 .NET Framework 编译器生成 exe，并运行合成检查及全部图片加载检查；不要求安装 SDK、Node 或额外解码器。
- 211 张目录内 WebP 转 PNG，每张比较解码后的像素；保留原始署名许可、来源目录和逐张转换哈希。
- 验证边界：macOS 本地检查及转换/打包校验通过；Windows 首次编译、C# 测试、透明穿透、多屏/DPI 与真实 Hana 连接仍待 Windows 实机执行。本测试包不是已完成 Windows 验收的预编译安装包。

## 桌宠 0.5.8 — 2026-10-18

- 桌宠 `.app` 补上自己的图标：以控制台同款角色群像为底，按 macOS Big Sur 图标网格（1024 画布、824 内容、圆角遮罩）生成 `AppIcon.icns`，Finder/Dock 不再显示通用占位图标。
- `Info.plist` 增加 `CFBundleIconFile=AppIcon`；`tools/package-pet-app.sh` 把 `pet-macos/Resources/AppIcon.icns` 拷进 `Contents/Resources`，缺图标时直接失败。
- 验证：`plutil -lint`、`codesign --verify --deep --strict`、包内 `AppIcon.icns` 存在；`run-checks.sh` exit 0。协议、姿态、控制台均未改动。

## 控制台 0.6.5 — 2026-10-18

- 控制台从「会话调试面板」改为「以宠物为主角」：主标题改为角色名（18px），会话标题降为第二行「跟随会话：…」；连接条只表达连接，不再重复会话名与业务状态；主卡时间只出现一次。
- 会话状态文案统一：生成中 / 工具执行 / 本轮结束 / 操作成功 / 出错 / 空闲；工具结果的 `success` 不再冒充「本轮结束」。
- 姿态显示中文标签（含「被拎起 / 被拎起·扑腾」），原始姿态 ID 只在诊断可见；`fallback` 标为「替代姿态」。
- 跟随行在自动与固定模式下都高亮（淡强调底 + 左侧细条 + 标记），删除「当前」胶囊；每行最多一个状态胶囊 + 一个跟随标记。
- 会话行按 `sessionId` 复用节点，每秒刷新不再丢键盘焦点、不再把列表滚回顶部。
- 立绘画框固定 164×143.8，比例覆盖目录里最宽的姿态（730×640），角色高度不再随姿态画布大小跳变，主卡不再被撑高或压矮。
- 角色条名称 11px、选中项浅底 + 描边 + 加粗；诊断新增回读角色 / 原始姿态 / fallback / revision / since，明细区限高内滚。
- 验证：`run-checks.sh` exit 0（Node 135、面板烟测、布局探针 11 组、跨层生命周期、PetCore 16）；560×664 深浅各 5 整行；420×640 5 行；560×560 4 行；390×640 4 行；深色对比度 ≥4.5:1。

## 桌宠 0.5.7 / 控制台 0.6.4 — 2026-10-17

- 桌宠拖拽时有了「被拎起」两帧往返动画：跨过拖动阈值且位置允许移动才触发，160 ms/帧；按下不拖、单击、AXPress、锁定位置都不触发。
- 松手/取消/换角色/换会话/失窗立即退出并恢复当时最新真实状态，不误触点击，旧定时器不会复活。
- 拖动期间盖住所有真实姿态（连等待确认、报错也一起盖），松手立刻回到当时最新状态。
- 拎起帧是硬切换，不套 0.20 秒交叉淡入，避免两套胳膊叠影；两帧共用同一画布与缩放，拖动时窗口坐标增量不变。
- 减少动态效果时只显示静态首帧，拖动照常。
- 新增 14 张本地生成拎起帧（7 角色 × 2 帧）：素材 193 上游 + 18 本地 = 211 张。**`gpt-onesie`（傻龙/龙崽睡衣）按用户最终选择用较早版本，其余六款用新挥手版**。
- 控制台显示「被拎起 / 被拎起·扑腾」中文标签，姿态白名单补入两张新图；布局未改。
- 验证：`run-checks.sh` exit 0（Node 116、Planner 438、Scheduler 415、Timeline 172、拎起检查 233、跨层 272、PetCore 16）；560×664 等五档无溢出。GUI 拖动观感未验收。

## 控制台 0.6.3 — 2026-10-17

- 修「刚点固定就被自动解除」：会话关闭后又被继续使用（宿主仍报过 `session_closed`）时，该会话不再被判为已关闭，因此可以正常固定。
- 关闭判定加第二道防线：只有关闭之后没有任何活动才算关闭，旧存储里残留的关闭时间也不会误伤。
- 自动解除的提示文案改为「已自动解除固定「X」：会话已关闭」，不再谎称是用户自己取消了固定。
- 验证：`run-checks.sh` 全绿（Node 115），`validate_app` 0 error；560×664 等 5 个尺寸实测无溢出。

## 控制台 0.6.2 — 2026-10-17

- 一屏定高：560×720 默认窗口（内容区 560×664）下整页不再滚动，只有会话列表内部滚动。
- 会话列表按整行对齐，行数不足时面板收成内容高；标题显示「会话 · N」。
- 角色条改 7 列网格，窄窗口等比缩小，去掉横向滚动。
- 舞台立绘 150→128，状态 pill 进标题行，姿态说明并入文案，空态居中。
- 主题跟随宿主：注入宿主主题 CSS 并订阅 `hana.theme`，`data-appearance` 切深浅，暖纸 fallback。
- 验证：560×664 一屏无溢出，列表 5 整行；420/560/720/900 宽均无横向溢出；`run-checks.sh` 全绿；`validate_app` 0 error。

## 控制台 0.6.1 — 2026-10-17

- 修舞台溢出：显式网格 + `overflow: hidden`，图片宽度约束，≤390px 舞台竖排。
- 配色改为宿主变量优先、系统深浅兜底，组件只读桥接变量。
- 补 4 张本地生成姿态，素材共 197 张（193 上游 + 4 生成）。

## 控制台 0.6.0 — 2026-10-17

- 控制台改版：连接条、舞台（立绘 + 会话信息）、会话列表、换角色、诊断四段。
- 真实姿态回读：读桌宠 `GET /v3/state` 的最终姿态，含回退后的替代图角标；未连接时明确提示。
- 跟随防乒乓：钉住某条会话后不被其他会话抢走。

## 控制台 0.5.x — 2026-10-17

0.5.0–0.5.5 完成会话清单与跟随、诊断记录、宿主事件表现（等待确认 / 上下文压缩 / 插话被丢弃）与协议 v3 对齐。逐轮细节见 `docs/迭代记录.md`。

## 桌宠 0.5.6 — 2026-10-17

- 同一会话里有了连续动作节奏：普通工作按 思考 6s → 左忙 4s → 思考变体 7s → 右忙 5s 循环（共 22 秒）。
- 第三阶段用角色自己的思考变体：Claude `thinking-2`、DeepSeek 与大肥鱼卫衣 `deepthink`，其余回 `thinking`。
- 工具动作结束后留 1.2 秒回归宽限，且保证工具姿态至少出现 2 秒；成功/报错/提示/情绪/会话切换会立即接管。
- 会话跟随、防乒乓、协议 v3、路由、权限、素材与 catalog 全部未改。
- `/v3/state` 的 `pose` 现在是最终展示姿态；主动轮换不误报 `fallback`。
- 删掉未被生产使用的 `PetArtworkPoseMapper`（它会把 working 映射成 writing 交替）。
- 验证：`run-checks.sh` exit 0（Node 111、Planner 438、Scheduler 415、Timeline 172、跨层 272、PetCore 16）。GUI 观感未验收。

## 桌宠 0.5.5 — 2026-10-17

- 协议与 schema 升到 v3，新增可选 `hint`（确认 / 压缩 / 插话丢弃）。
- catalog 支持 `generatedPoses`，打包数量与哈希分类改为动态。
