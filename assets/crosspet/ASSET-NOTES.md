# CrossPet 素材准备记录

## 核验结论

核验对象是官方公开仓库 [`lokicorvus/crosspet`](https://github.com/lokicorvus/crosspet)，锁定到 **v1.3.6**、commit `18e924659c665eb6fcfcf5e161a81a75203af0ae`（2026-10-16）。`VERSION` 文件为 1.3.6。

上游根目录 `LICENSE` 是 MIT，但其正文明确限定为**源代码**；角色立绘/设定另由 `characters/LICENSE.md` 以 **CC BY-NC-SA 4.0** 授权。本目录随附该素材许可原文 `CHARACTERS-LICENSE.md`。本地非商业原型可在注明 CrossPet 与许可中列出的设定作者、保留许可并遵守相同方式共享的前提下复用；**不得商用、上传、发布或对外分发**。本次文件均为原样下载，未对图像做裁切、重绘、调色或重新压缩。

## 可复用角色与目录

当前上游内置角色不是四个，而是五个：

| 角色 | 类型 | 本地相对路径 | 上游注明的设定来源/署名 |
|---|---|---|---|
| Claude | 基础角色 | `claude/` | CrossPet AI 生图；社区流行的 Claude 娘设定（铜橙长发、橙花、书）。许可未列单一原始设定作者；`ai-school-op`、`openpet-ai-girls` 是许可中的参考链接，不等同于已确认的直接来源。 |
| GPT 白龙 | 基础角色 | `gpt/` | CrossPet AI 生图；“御姐白龙”设定署名 B 站 ZipZipPipe（许可未给具体帖子 URL）。 |
| DeepSeek / 大肥鱼 | 基础角色 | `deepseek/` | CrossPet AI 生图；“溟月”原型署名上善无形（2025-06、CC BY-NC-SA 4.0）；深蓝女仆鲸鱼娘“大肥鱼”署名 B 站 ZipZipPipe。 |
| Gemini | 基础角色 | `gemini/` | CrossPet AI 生图；社区流行的猫耳、异色瞳、四芒星发饰设定。许可未列单一原始设定作者；所列参考仓库不代表确认了具体来源。 |
| GLM / 黑狐狸女仆 | 基础角色 | `glm/` | CrossPet 原创设定（“心机涨价狐”）；上游未另列个人画师。 |
| DeepSeek · Claude 卫衣 | 皮肤，`skinOf: deepseek` | `deepseek-hoodie/` | CrossPet 在 DeepSeek / 大肥鱼上的衍生皮肤。 |
| GPT · 降智龙崽 | 皮肤，`skinOf: gpt` | `gpt-onesie/` | CrossPet 在 GPT 白龙上的衍生皮肤。 |

角色逐项来源、所选姿态文件名及基础/皮肤关系另见 `catalog.json`。素材现已接入本机 Swift 桌宠与 Hana 手动角色选择；先前首轮原创占位图形保留在历史记录中，不再作为这些角色的运行时回退。

### 许可/来源边界

- CrossPet 的素材许可对整个 `characters/` 目录明确适用，并规定署名 CrossPet 与表中列出的原设定作者、非商业使用及衍生作品相同方式共享。本机集成范围仍只限本 catalog 明确列出的文件；完整许可和署名声明随桌宠 App 资源保留。
- Claude、Gemini 的底层“社区流行设定”没有给出单一创作者；GLM 只注明 CrossPet 原创、未点名个人画师。目录和目录清单如实保留这些来源粒度，没有补猜作者、也没有把参考链接说成直接创作来源。
- 上游称这些立绘由 AI 生图工具按角色设定绘制，但没有列出每张图的操作者/模型。可归属的许可方与项目来源是 CrossPet；个别图的实际操作者仍未具名。
- 没有复制上游的 `character.json`、台词/提示词、任何程序代码或 App 绑定数据。`catalog.json` 是本地素材索引，不是 CrossPet 角色配置。

## 文件类型、动画与适配

上游 `docs/自定义角色.md` 将每张立绘定义为一个单独的姿态文件（如 `idle.webp`、`thinking.webp`），文件名就是姿态名；`-2` / `-3` 后缀表示同一姿态的额外图，`idle-blink.webp` 是特殊眨眼图。`app/mac/App+Characters.swift` 的加载器逐文件扫描 `.webp` / `.png`，把 `-2` / `-3` 归并为同一 pose，另行识别 `idle-blink`；上游 `index.html` 将立绘按 `object-fit: contain` 放进人物区域并以交叉淡入切换。由此确认：这批素材是**独立姿态立绘，不是拼接精灵图，也不是需要切片的帧表**；运动效果由不同姿态图及应用动画层组合。

本地检查结果：193 张被清单引用的 WebP 都是单帧、有 Alpha 的图片，高度均为 640 px；宽度因原图透明画布不同而变化（477–730 px）。因此渲染适配建议：保留原宽高比、以固定人物高度缩放，使用 fit/contain，不强行裁成统一方形或切 sprite sheet；用 `idle.webp` 作为缺少姿态的回退，并按上游语义处理 `-2` / `-3` 与 `idle-blink`。逐帧检查通过；这里的“单帧”是静态 WebP 图片，不是 WebP 动画。

## 双击铁盆道具（`shared/basin.png`）

- 桌宠双击「扣铁盆」用的通用金属盆，只此一张，不属于角色立绘、不在 `catalog.json` 里，也不计入 211 / 18 的素材计数。
- 非 CrossPet 上游素材、不归入任何上游原画师署名；由本项目为这个功能准备，按 **CC BY-NC-SA 4.0** 同样条件随包使用（见 `ATTRIBUTION.md`）。
- 交付图 128×51、带透明边距；已按不透明边界裁切为 **117×47**（仅裁透明像素，无重采样、无重绘），两端都按固定 96×38.5 pt 显示。
- 同步副本：`pet-macos/Sources/HanaDesktopPet/Resources/CrossPet/shared/basin.png`（逐字节一致，`tests/pose-assets.test.mjs` 守卫）；Windows 侧由 `tools/prepare-windows-assets.swift` 复制进 `.build/windows-assets/CrossPet/shared/` 并单独记入 `build-manifest.json` 的 `sharedAssets`。
- 查找顺序是 `{角色ID}/basin.png` → `shared/basin.png` → 代码内矢量盆；缺图或解码失败仍能画出盆，不会崩溃。

## 本次选择范围

- 已准备 **5 个基础角色 + 2 个皮肤，共 193 张姿态立绘**；包含 idle/idle 变体、听/想/读/写/运行/搜索/委派/绘图、完成/出错/提问/压缩/额度紧张、多会话状态，以及上游角色特有姿态（如 GPT reset、DeepSeek 吃饭/游泳、Gemini float、GLM 面罩/价签）。精确文件集合见 `catalog.json`。
- 有意不纳入彩蛋 `egg-*`、时段问候 `greet_*`、节日 `fest_*`、贴边 `edge_*`、普通互动/甩动情绪组、其它未列动作、提示词、立绘原始生成材料及角色台词。可按未来实现需求再核验/补齐。
- 数量并非上游角色全集；“未列入 catalog 的文件”不属于本次准备集，不要在集成时自动扫描所有上游内容。

## 下载过程中的重复文件

下载器遇到重跑会自动改名，曾导致 `deepseek-hoodie/` 和 `gpt-onesie/` 中出现 **57 个**带 ` (1).webp` 后缀的重复副本。本机 SHA-256 检查确认它们与对应无后缀原图逐字节相同；用户确认后已只删除这 57 个副本，保留原图。`catalog.json` 从未引用这些重复路径。

## 核验/引用

- 仓库：<https://github.com/lokicorvus/crosspet>
- 锁定 commit：<https://github.com/lokicorvus/crosspet/tree/18e924659c665eb6fcfcf5e161a81a75203af0ae>
- 许可原文：[`CHARACTERS-LICENSE.md`](CHARACTERS-LICENSE.md)，上游 `characters/LICENSE.md`
- 角色格式与姿态约定：上游 [`docs/自定义角色.md`](https://github.com/lokicorvus/crosspet/blob/18e924659c665eb6fcfcf5e161a81a75203af0ae/docs/%E8%87%AA%E5%AE%9A%E4%B9%89%E8%A7%92%E8%89%B2.md)
- 上游加载方式：`app/mac/App+Characters.swift`、`app/web/index.html`（均在上述锁定 commit）
