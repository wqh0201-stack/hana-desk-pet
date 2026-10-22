# CrossPet 角色素材署名与集成说明

本项目公开非商业 demo 使用本目录 `catalog.json` 明确列出的 211 张 WebP 立绘：其中 **193 张为 CrossPet 上游原样素材**，来源为 `lokicorvus/crosspet` v1.3.6、commit `18e924659c665eb6fcfcf5e161a81a75203af0ae`；另有 **18 张本地 AI 生成补充图**，包括 4 张姿态补充（`claude/drawing.webp`、`gemini/idle-blink.webp`、`deepseek-hoodie/idle-2.webp`、`deepseek-hoodie/idle-3.webp`）与 14 张「被拎起」两帧往返图（每个角色 `picked-up.webp` + `picked-up-2.webp`）。两部分均按 **CC BY-NC-SA 4.0** 使用；随包保留完整许可文本 `CHARACTERS-LICENSE.md`。本声明不是 MIT 许可：上游 MIT 只覆盖代码，不适用于角色立绘。

署名（依原许可的来源粒度）：

- **CrossPet**：193 张上游原样素材的发布与 AI 绘制来源；本地补充图与拎起帧不归入 CrossPet 上游素材或其原画师署名。
- **DeepSeek / 大肥鱼**：上游列出「溟月」原型作者 **上善无形**（2025-06）及深蓝女仆鲸鱼娘设计 **ZipZipPipe**。
- **GPT / 白龙**：上游将「御姐白龙」设定归于 **ZipZipPipe**。
- **Claude、Gemini**：上游描述为社区流行设定，没有核实或列明单一原设作者；不将许可中的参考仓库误称为该图的直接作者。
- **GLM / 黑狐狸女仆**：上游描述为 CrossPet 原创设定，未列单独个人画师。
- **DeepSeek · Claude 卫衣、GPT · 降智龙崽**：CrossPet 在对应基础角色上的衍生服装素材，并按上述基础设定来源署名。

193 张上游图像按 catalog 原样复制，未裁切、重绘、调色、重压缩或改成精灵图。18 张本地 AI 生成图**不是 CrossPet 原图，署名不得归于 CrossPet 或任何上游原画师**；同样按 CC BY-NC-SA 4.0 使用。

**拎起两帧的来源**（`picked-up.webp` 为头帧、`picked-up-2.webp` 为尾帧）：

- `claude`、`gpt`、`deepseek`、`gemini`、`glm`、`deepseek-hoodie` 六款取自「桌宠-GPT后颈扑腾头尾帧-20261017」素材包的 `first-frame.webp` / `last-frame.webp`（GPT 双帧原稿，非 Qwen 帧）。
- `gpt-onesie`（GPT 龙崽睡衣皮肤）按用户最终选择使用较早的「桌宠-拎起两帧-20261017」素材包 `picked-up.webp` / `picked-up-2.webp`(较早 GPT 原稿 + 当时本地轻摆后处理)。

两包均为本地生成素材，未另行生图、未做局部修图；按原成品接入，保留既有的少量服饰、手指与提起处细节差异。只把图片字节复制进本仓库，运行时不读取媒体库绝对路径。

**通用铁盆道具（`shared/basin.png`，不在 catalog 内）**：桌宠双击「扣铁盆」用的单个通用道具图，由本项目为本地桌宠绘制/生成，**不是 CrossPet 上游素材，不归入任何上游原画师署名**；只有一张，随桌宠包与 Windows 便携包分发，按 **CC BY-NC-SA 4.0** 同样条件使用（署名方为本项目）。交付图带透明边距，已按不透明边界裁切为 117×47（仅裁掉透明像素，无重采样、无重绘）；两端显示尺寸固定为 96×38.5 pt。

项目以公开非商业 demo 形式在 GitHub 分发，随包保留署名说明与完整许可全文，**禁止商用**。如授权范围或署名有异议，应停止使用并移除相关素材。逐张文件清单见 `catalog.json`，许可全文见 `CHARACTERS-LICENSE.md`。
