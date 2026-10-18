# Hana Desk Pet

一个跟着 Hana 干活的桌面宠物。

Hana 在想事情，它歪头思考；Hana 在读文件，它翻书；Hana 在跑命令，它跑起来；你插的话被丢了，它会惊讶一下。形象用 CrossPet 原版立绘，7 个角色、211 张透明姿态图（193 张上游原图 + 18 张本地生成的补充）。

> **这是 demo。** 给群友玩玩看的，不是产品。macOS 版已可用，Windows 版有单文件便携版可下载。请按玩具的预期使用。

## 它是什么

两个独立程序，走本机回环通信：

```
Hana
 └─ 桌宠控制台（Hana App）
      │  只读：会话标题、Agent、工具名、状态、时间戳
      │  http://127.0.0.1:43127  /v3/*
      ▼
    桌宠（独立原生 App，macOS / Windows，透明悬浮窗）
```

控制台订阅 Hana 的会话事件、维护脱敏状态快照、管理角色和会话绑定；桌宠负责把状态翻成姿态、做转场、处理拖动和右键菜单。

控制台里能看到桌宠**此刻真正在摆的姿势**——不是根据最近事件猜的，是桌宠通过 `GET /v3/state` 回报的最终结果（含回退后的替代图，会打角标）。桌宠没开着的时候这里会明说「未连接」，不会拿上一次的姿态糊弄你。

它不是 CrossPet 的适配器，也不读写 CrossPet 的任何配置，只是用了它的角色素材。

## 要求

- macOS（Darwin 25 上开发；Intel 和 Apple Silicon 都没专门测）
- Hana 1.1.7-beta 或更新
- 不需要装任何依赖

**Windows 版：** 另有独立 WPF 桌宠，沿用同一个控制台和 v3 协议。发布物是**预编译的单个 exe**，211 张图片已内嵌，解压双击即可，不需要 SDK、Python、Node 或任何解码器。目标为 Windows 10 1903+ / Windows 11 x64，需要系统自带的 .NET Framework 4.8。

> **源码状态：** Windows `0.2.0` 的最终源码已回灌到 `pet-windows/`（含 `PetAssetStore.cs`、单文件构建脚本与 C# 合成检查），素材 blob 可由 canonical catalog 重建到同一字节数。对应成品 exe 已在 Windows 编译并实机跑通（作者实测），本仓库不重复声称已在 Mac 上编译过。

## 装

1. 从 [Releases](../../releases) 下载 `app-hana-desktop-pet-*.zip`，在 Hana 里本地安装，**批准 `app/sessions.read` 权限**（不批的话会话列表里全是「会话」）。控制台还会申请 `app/ui.open-external`，只用于你点击下载入口时打开固定的 Release 页面；不批准也能用，只是要自己复制链接。
2. 下载 `HanaDesktopPet-crosspet-*.zip`，解压双击 `.app`。第一次会被系统拦，提示「无法验证开发者」——右键 → 打开，或去「系统设置 → 隐私与安全性」点「仍要打开」。
3. 控制台里打开「本机桌宠连接」，状态变「已连接」就好了。
2. 下载 `HanaDesktopPet-crosspet-*.zip`，解压双击 `.app`。第一次会被系统拦，提示「无法验证开发者」——右键 → 打开，或去「系统设置 → 隐私与安全性」点「仍要打开」。

## 玩

- 单击角色：开心一下
- 按住拖动：挪位置，同时被拎起来扑腾两下
- 右键：换角色、锁定位置、停靠到角落、退出
- 控制台里：手动选角色，或把桌宠**钉在某条对话上**只跟它

默认跟「最近有活动的会话」。钉住之后，别的会话再热闹也抢不走。

## 会做什么

| Hana 那边 | 桌宠 |
|---|---|
| 空闲 | 待机，隔几秒换姿势、眨眼 |
| 空闲 5 分钟 | 打盹 |
| 生成文字 | 思考，每 22 秒换一轮 思考→左忙→思考→右忙 |
| 读文件 / 抓网页 | 看书 |
| 写 / 改文件 | 写字 |
| 搜网页 / 搜文件 | 查找 |
| 跑命令 / 构建测试 | 奔跑 |
| 派活给别的会话 | 派活 |
| 生图 | 画画 |
| 连续工作 10 分钟 | 疲惫 |
| 10 秒连调 5 次工具 | 忙翻 |
| 某个工具成功 | 开心一下（2.5 秒） |
| 某个工具出错 | 失误（2.5 秒） |
| 整轮收工 | 得意 |
| 弹确认框等你点 | 询问 |
| 上下文压缩中 | 压缩 |
| 你插的话被丢弃 | 惊讶 |
| 你把桌宠拖起来 | 被拎起来扑腾两帧（160 ms/帧） |

认不出的工具名一律退回「通用忙碌」，不猜。

## 隐私

**桌宠只知道在干什么，不知道说了什么。**

只传会话 ID、标题、Agent 名称、状态、工具名、时间戳。没有正文、没有工具参数、没有工具结果、没有文件路径、没有提示词。

控制台虽然有 `app/sessions.read`，但只读标题和 Agent 名，不读历史消息。

## 已知问题

- **本地端口没鉴权**：`127.0.0.1:43127` 是明文 HTTP，没有令牌。同机任何程序都能灌假数据让它假装在干活。**别把它当可信的状态显示器**，它只是氛围。
- **没签名没公证**：每次更新后第一次打开可能被系统拦。
- **控制台和桌宠必须版本配套**：协议是 v3，只升其中一个会导致桌宠完全不响应——不是坏了，是新版在主动拒绝旧版。两个一起换。
- **不自动启动**：每次开机要自己开。
- **只验过合成数据**：逻辑测得很细（姿态与节奏 1250 项、拖动拎起 233 项、跨层 272 项、核心 16 项、控制台 116 项），但真实桌面的观感、拖动手感、拎起节奏、鼠标穿透只有作者自己看过。
- **会话归属偶尔识别不出来**：会显示成「未识别会话」，不冒充真实会话，也不能被钉住。

## 素材来源与许可

角色立绘来自 [lokicorvus/crosspet](https://github.com/lokicorvus/crosspet) v1.3.6，许可 **CC BY-NC-SA 4.0**：不能商用、要署名、衍生要用相同许可。

其中 193 张是上游原样文件，**另有 18 张是本项目用 AI 生成的补充**（Claude 的画画、Gemini 的眨眼、DeepSeek 卫衣款的两个待机变体，以及每个角色两张「被拎起」往返帧），同样按 CC BY-NC-SA 4.0 使用，但不是 CrossPet 原图，署名不应算到上游或原画师头上。

完整许可和逐项来源见 `assets/crosspet/CHARACTERS-LICENSE.md` 和 `assets/crosspet/ATTRIBUTION.md`，打包的 `.app` 里也带了一份。CrossPet 上游的 MIT 只覆盖它的源码，不覆盖这些图。

许可要求保留署名、非商业、衍生作品相同方式共享；**不能商用**，也不要去掉署名或换用更宽松的许可。

本项目自己的代码用 MIT，见 `LICENSE`。

## 自己构建

```sh
sh tools/run-checks.sh      # 全部本地检查（Node / Swift / 面板），不启动 GUI、不安装、不连真实 Hana
sh tools/package-pet-app.sh # 打桌宠 .app
node tools/package-windows-pet.mjs --prepare-assets  # 生成 Windows 构建用的 PNG/图标（macOS）
python3 tools/build-windows-portable.py              # Windows 单文件构建（编译需 Windows csc）
```

打出来的 `.app` 用 ad-hoc 签名，本机可用，分发出去会被 Gatekeeper 拦；从 Releases 下载后仍需右键 → 打开。

Windows 的 C# 源码在 `pet-windows/`，构建用 `python3 tools/build-windows-portable.py`；素材输入是 `.build/windows-assets/`（由 canonical catalog 转换，不入 Git）。`python3 tools/run-windows-checks.py` 是 Windows 侧的 C# 合成检查入口，需要 `csc.exe`，在 macOS 上会明确报缺并 exit 2，不会冒充通过。macOS 检查通过不代表 Windows 运行验收通过。

## 目录

```
apps/hana-desktop-pet/   Hana 控制台（v2 App）
pet-macos/               桌宠（Swift + AppKit）
pet-windows/             Windows 桌宠（WPF 单文件版，C# 源码与构建入口）
assets/crosspet/         211 张姿态图（193 上游 + 18 生成）+ 许可 + 署名
tests/                   合成数据测试与检查驱动
tools/                   检查与打包脚本
docs/                    设计说明、迭代记录、事件探查、归档
CHANGELOG.md             版本变更记录
```
