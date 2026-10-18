# Hana 桌宠 · Windows 版

一个独立的桌面宠物。透明背景、始终置顶、不抢键盘焦点，跟随 Hana 的会话状态换动作。

## 下载即用

发布物是**一个** `HanaDesktopPet.exe`。双击运行即可。

- 素材（7 个角色、211 张 PNG）全部内嵌在 exe 里，不需要旁边的素材目录，也不能单独把 exe 挪走再配目录。
- 不需要安装 .NET SDK、Visual Studio、Node、Python 或任何图片解码器，启动时不下载任何东西。
- 首次运行时 Windows 可能提示「Windows 已保护你的电脑」，因为这是未签名的程序：点「更多信息」→「仍要运行」。

## 系统要求

Windows 10 1903 或更新的 x64 系统、Windows 11 x64。需要 .NET Framework 4.8（Windows 10 1903+ 与 Windows 11 自带）。

## 连接 Hana

打开 Hana 的「桌宠控制台」App，启用「本机桌宠连接」。桌宠在 `127.0.0.1:43127` 提供本机回环接口（协议 v3），只监听本机回环地址，不需要再装别的插件。

- **单击**角色：开心一下
- **按住拖动**：拎起来移动，松手落地
- **右键**角色：换角色、锁定位置、停靠角落、退出
- **透明空白处**：鼠标事件交给后面的窗口

## 数据与隐私

- 只接收脱敏状态：会话标题、状态、工具名、时间戳。不接收消息正文，也不读取会话内容。
- 后台不联网、不上传；只监听本机回环 `127.0.0.1:43127`，不添加开机启动、不要求管理员权限。
- 角色与位置偏好存在 `%LOCALAPPDATA%\HanaDesktopPet\preferences.json`。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| 双击没反应 | 同一个用户只能运行一个实例。先在任务管理器确认没有残留的 `HanaDesktopPet.exe`。 |
| 控制台连不上 | 确认端口没被占用；`curl http://127.0.0.1:43127/v3/hello` 应返回 `{"service":"hana-desktop-pet","protocolVersion":3}`。 |
| 角色不显示 | 右键换一个角色。仍然空白时看「事件查看器 → Windows 日志 → 应用程序」。 |
| 想彻底重置 | 退出桌宠后删除 `%LOCALAPPDATA%\HanaDesktopPet`。 |

## 从源码构建

本仓库的 Windows 源码在 `pet-windows/`，不是原独立源码包那种根目录 `src/` + `CrossPet/` 布局。

```bash
node tools/package-windows-pet.mjs --prepare-assets  # macOS：从 canonical catalog 生成 .build/windows-assets（仅用系统自带 Swift/ImageIO）
python3 tools/build-windows-portable.py              # → dist/HanaDesktopPet.exe（素材内嵌）
python3 tools/run-windows-checks.py                 # 协议 / 传输 / 动画自检（仅 Windows）
```

- 编译需要 Windows 与 .NET Framework 4.8 自带的 `csc.exe`；素材打包、哈希与 zip 生成是纯 Python，macOS 上能跑（`python3 tools/build-windows-portable.py --check-assets-only`）。
- **两台机器交接：** 在 Mac 跑 `--prepare-assets` 之后，要把**同一源码提交**生成的整个 `.build/windows-assets/` 目录（含 `CrossPet/` 与 `App.ico`）原样带到 Windows 仓库的同一位置，再在 Windows 上跑 `run-windows-checks.py` 与编译。`.build/` 不入 Git，所以**干净 checkout 不能直接跑这三条命令**——本仓库目前没有配置 CI，没有自动替你搬这一步。
- 构建输入是 `.build/windows-assets/`（由 canonical `assets/crosspet` 转换而来，不入 Git）；**不维护第二份手工 `CrossPet/` 目录**。
- 构建临时目录与重新生成的清单在 `.build/windows-build/`；只会清理这个项目内的可再生产物。
- `pet-windows/package-manifest.json` 是 0.2.0 原始构建的历史记录（它记录的 `executable.sha256` 对应已验收的那个 exe），**重建时不会改写它**，新构建写 `.build/windows-build/package-manifest.json`。
- 首次启动现场编译的旧形式（`Start-HanaDesktopPet.ps1` / `Check-HanaDesktopPet.cmd` / sidecar `HanaDesktopPet.exe.config`）已退役；`node tools/package-windows-pet.mjs` 会直接报错，不会再产出旧包。

## 许可

代码使用根目录 `LICENSE` 中的 MIT 许可。角色素材为 **CC BY-NC-SA 4.0**：允许非商业转载与分发，须保留署名与完整许可文本、衍生以相同方式共享；**不得商用**。署名与来源见 `assets/crosspet/ATTRIBUTION.md`、`assets/crosspet/CHARACTERS-LICENSE.md`（这两个文件也随便携 zip 一并分发）。
