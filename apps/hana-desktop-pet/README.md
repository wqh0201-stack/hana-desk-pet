# Hana 桌宠控制台（Hana v2 App）

这是配套**独立原生桌宠**的管理 App，不在卡片里绘制桌宠。macOS 与 Windows 两个平台共用这一个控制台：它订阅 Hana v2 公开事件，过滤并保存最近会话的标题/Agent/工具/状态快照；用户手动选择 7 个角色/皮肤之一，把桌宠绑定（钉住）到某个具体会话，并决定是否启用 `sdk.network.fetch` 到宠物端固定 loopback 地址的本机桥接。

桌宠本体是两个独立程序，各自在自己的 Release 里分发：macOS 的 `.app` 与 Windows 的单文件 exe。控制台本身不含桌宠可执行文件。

## 未连接时的引导（0.6.6）

没连上桌宠时，面板会给一段紧凑引导：解释当前是关闭、连接中还是连接失败，指向两个平台固定的 Release 入口，并给出三步安装说明。连接失败先提示启动已装好的桌宠，再给下载；协议不匹配保留原错误；连上之后整块收起。**不会把「未连接」说成「未安装」**，也不猜你用的是哪个系统——两个平台入口始终并列。

两个下载入口是真实的 `<a href>`（保留链接语义与键盘可达），点击时交给宿主的 `hana.external.open`，对应 manifest 能力 `app/ui.open-external`。宿主拒绝或没有这项能力时，退到同一地址的可选中文本，可直接 ⌘/Ctrl+C；不调用剪贴板 API，也不尝试其它跳转路径。

包内许可与署名：`LICENSE`（本项目代码，MIT）、`assets/ATTRIBUTION.md`、`assets/CHARACTERS-LICENSE.md`。

## 许可与分发

本项目自己的代码用 **MIT**（见包内 `LICENSE`）。

角色立绘是另一套授权：控制台界面里包含 7 个角色的预览图，姿态图共 **211 张 WebP**，其中 **193 张为 CrossPet 上游原样素材**（`lokicorvus/crosspet` v1.3.6）、**18 张为本地 AI 生成补充图**。两部分均按 **CC BY-NC-SA 4.0** 使用，与代码的 MIT 分开，不得把 MIT 套到角色立绘上。

该许可**允许非商业转载与分发**，条件是：保留署名、保留完整许可文本、衍生作品以相同方式共享。**不得商用**，也不得去掉署名或换用更宽的许可。包内 `assets/ATTRIBUTION.md` 是逐来源署名与转换说明，`assets/CHARACTERS-LICENSE.md` 是许可全文，两者均不得删除。

18 张本地生成图不是 CrossPet 原图，署名不得归于 CrossPet 或任何上游原画师；193 张上游图的发布与 AI 绘制来源为 CrossPet，细节见 `assets/ATTRIBUTION.md`。

## 跟随策略

桌宠默认跟随**最近有活动**的会话；可以在控制台的「跟随的会话」下拉里钉住某个会话，钉住后其他会话再有动静也不会抢走它。解钉回到跟随最近活动。

**下拉只列未归档（`active`）会话**，按最近活动排序，最多 15 条。归档会话一条都不会进选择列表，也没有「显示已归档」开关。归档数据只在内部用于补齐快照里的空标题。

会话列表与快照里的每一行都用同一套标题解析：有标题用标题，同标题再用 Agent 名和短 ID 消歧，没有标题就兜底为「会话 · 短ID」。不会出现无法区分的裸「会话」。

被钉住的会话关闭、归档，或长时间不再出现在会话清单里时，App 会自动解钉并回到跟随最近活动，同时在界面上说明刚才取消了哪个会话、因为什么。所以绑到一个已经消失的会话不会让桌宠从此一动不动。

## 会话身份归属

事件只带 `sessionPath` 时，不使用进程自造的 `local-session-N` 假 ID：那会把真实会话的活动全部吸到一个不存在会话上，让真实会话永远看起来空闲。现在的解析顺序：

1. 事件自带的 `sessionId`；
2. `session:list` 的 `path` → `sessionId` 索引（宿主确实返回 `path`，这是最干净的来源）；
3. `session:get` 按 id；
4. 最后才试按路径的 `session:get` → `legacySessionPath` → `session:context`。这条最脆弱：宿主会校验路径是否在其 `agentsDir` 下，失败只报通用的 `APP_HOST_ERROR`。

路径索引保留**全部 active 会话**，在需要淘汰时**先删归档条目**（旧实现是无脑按插入顺序淘汰，大归档会把活跃会话挤掉，这就是占位符吃活动的真因）。查询时先精确匹配，不中再按 basename 兜底（事件回调路径与清单 `path` 可能前缀/软链/相对路径不一致）。

完全解析不出来时，活动停在由 sessionPath 派生、跨事件稳定的占位键（`unresolved:<hash>`）下；不存路径原文，只在内存里留 `path → 真实 ID` 映射。真实身份一旦从任何来源可用，占位记录的活动会被并到真实会话上并删除。占位行永远不会成为「当前会话」（除非确实没有任何可识别的活跃会话）、不会被钉住、也不会进入下拉，界面显示为「未识别会话 · 短ID」。

旧版本遗留的 `local-session-N` 行在加载时直接清掉。

## 诊断

会话类调用失败时，App 只把稳定的 `code` / `kind` / `operation` / `selector`（`id` / `path` / `legacyPath`）与几个布尔标志（`eventHasSessionId` / `listHasPath` / `pathResolvedFromList` / `legacyPathTried`，以及枚举 `pathMatch`: `exact` / `basename` / `miss`）写进 `hana-pet.session-diagnostics`，绝不存 message、会话 id、路径或正文。

## 宿主事件驱动的表现（协议 v3）

`PetActivity.hint` 是 v3 唯一新增字段，取值只能是 `confirming` / `compacting` / `interrupted` 或 `null`。

| hint | 来源 | 清除 |
|---|---|---|
| `confirming` | `session_confirmation` | `confirmation_resolved`，或 10 分钟上限 |
| `compacting` | `compaction_start` | `compaction_end`，或 10 分钟上限 |
| `interrupted` | `interjection_dropped` | 4 秒后自动过期 |

三个 hint 只对**被跟随的会话**生效：`hint` 属于某条 sessionId，看的是 `current` 那一行，与 follow/pin 同源。`confirmation_resolved` 的归属**不保证存在**（终端提案传 `null`）：此时清掉全部 `confirming` 而不是猜一个会话，且绝不新建记录。

**隐私**：这三个事件的 payload 夹带正文、工具参数、用户输入、错误信息与被丢弃插话原文。代码只读 `event.type` 与会话归属，不读、不记、不序列化其它任何字段。测试用唯一哨兵值对存储与 DTO 做全量断言。

`queue_update` 本轮未接，静态分析找不到实际发射点，等探针验证后再议。重启后 `hint` 一律清空，与 `recoverSnapshot` 的其余清理纪律一致。

## 诊断

会话类调用失败时，App 只把稳定的 `code` / `kind` / `operation` / `selector`（`id` / `path` / `legacyPath`）与几个布尔标志（`eventHasSessionId` / `listHasPath` / `pathResolvedFromList` / `legacyPathTried`，以及枚举 `pathMatch`: `exact` / `basename` / `miss`）写进 `hana-pet.session-diagnostics`，绝不存 message、会话 id、路径或正文。

**会话清单是命名与 path→id 的主来源**，所以只有清单本身失败才会显示「会话清单不可用 · 原因：<种类>（<code>）」；`session:get` 只是可选补强，它失败时只用低干扰的次要说明（「个别会话详情暂不可读（按路径查询，<code>）；会话名称仍取自会话清单。」），不会让用户以为功能坏了。后续成功自动清掉对应提示。这是定位「会话接口到底为什么失败」的唯一手段，不要把它改回静默 catch。

清单请求使用 `lifecycle: "all"`：归档会话也有名字值得显示（用于补齐快照标题），但**只有 `active` 会进入下拉**。`path` 只在内存里充当 path→id 映射键，不落盘。

## 授权与数据

- `app/sessions.read` 只用于读取会话标题和 Agent 元数据；缺少授权时显示稳定会话 ID 回退。`sdk.sessions.list`（`scope: "all"`、`lifecycle: "active"`）同样只在这一项授权下使用；被拒时不算错误，降级为继续按事件活动工作。
- `app/ui.open-external` 只用于你点击下载入口时打开固定 Release 页面。没有这项授权也能正常使用控制台，只是需要自己复制链接。它不授予读文件、执行或任意导航能力。
- 持久化的会话清单只保留元数据白名单：sessionId / title / agentId / agentName / lifecycle。不保存 `path`、`cwd`、消息内容、`modelId`、`messageCount` 等任何其它字段，也不把它们送到宠物端。会话路径只在内存里充当映射键，既不入库也不外发；占位键是路径的单向散列，不含路径原文。
- 诊断记录（`hana-pet.session-diagnostics`）只存 `code` / `kind` / `operation` / `selector` / `pathMatch` 五个枚举与四个布尔标志，不存 message、会话 id 或路径。
- 跟随选择（`hana-pet.follow`）只存 mode / 会话 ID / 时间戳与回落原因；释放提示是临时 UI 上下文，超时后不再保留。
- `network.allowedHosts` 只含 `127.0.0.1`，`allowLocalhost` 显式开启；仅用 `GET/POST`。Bridge 默认关闭，固定地址位于 `pet-bridge.mjs`，桌宠端绑定 `127.0.0.1:43127`。App 后台的网络访问只限于这条本机回环：会话内容不上传、不转发到任何远端。你点击下载入口时，是由系统浏览器去访问 GitHub Release 页面，不是 App 自己发请求。
- Bridge 仅使用 v3 `/v3/*` 路由与 `schemaVersion: 3`。v2 及更早的旧 peer 不再受理（握手与 schema 双向 fail closed）；新 Pet 只接受本机固定目录，不允许 Hana DTO 覆写角色集合。
- 角色选择、Bridge 开关和活动快照各自保存在 App 的 global storage。事件处理和发往宠物的数据都不包含聊天正文、工具参数/结果、sessionPath 或凭据；活动事件不能更改角色。
- 不申请 runtime、Hana window、local-machine、usage、model 权限；不访问已安装 CrossPet。

## 本地验证

在项目根目录执行：

```sh
node --test tests/*.test.mjs
node tools/demo-event.mjs
sh tools/run-checks.sh
cd pet-macos && swift run PetCoreChecks && swift build
```

`tests/session-follow.test.mjs` 用一个合成 Hana 宿主驱动真实 `index.js` 入口（捕获它的定时器、可改会话清单），覆盖标题解析、钉住优先级、关闭/归档/消失后的回落、元数据白名单和缺权限降级；`tests/synthetic-host.mjs` 就是这个宿主，不接任何真实 Hana。`tests/panel-onboarding.test.mjs` 是连接引导的状态机与静态标记断言；`tools/panel-onboarding-probe.mjs` 在 headless Chrome 里跑生产页面 + 合成宿主，测真实布局。全部使用合成数据，不读真实会话。

随后运行本机 Hana App Creator 官方 `validate_app.mjs` 的目录和 archive 检查。不要把 App 安装到正式 Hana，也不要批准本机网络或会话权限；测试只使用合成事件。独立桌宠构建/打包见 `tools/package-pet-app.sh`。
