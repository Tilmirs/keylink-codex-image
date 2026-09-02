# Keylink Image Skill

这是一个给 Codex 等支持 skills 的 AI 软件使用的图片生成与编辑 skill。用户只需用自然语言描述图片、模型、画幅和保存位置，AI 负责模型发现、接口调用、权限申请、凭据读取和结果验证。

## 在 Codex 中一行安装（Windows / macOS / Linux，推荐）

在 Codex 对话框中直接发送下面这一行，不需要克隆仓库、输入 PowerShell 或复制文件：

```text
$skill-installer 请从 https://github.com/Tilmirs/keylink-codex-image 的仓库根目录安装 skill，并将安装名称设为 keylink-image。
```

Codex 会使用内置的 skill 安装器下载公开仓库，并在联网和写入 skills 目录前申请所需权限。Windows 通常安装到 `%USERPROFILE%\.codex\skills\keylink-image`，macOS/Linux 通常安装到 `$HOME/.codex/skills/keylink-image`；设置了 `CODEX_HOME` 时则使用该目录下的 `skills/keylink-image`。

这是首次安装命令；如果目标目录已经存在，内置安装器会停止而不是覆盖。安装完成后，skill 会在 Codex 的下一轮对话中可用；如果没有被发现，重启 Codex。相关机制见 [OpenAI 官方 Codex Skills 文档](https://developers.openai.com/codex/skills)。

## 在 Codex 中同步 GitHub 最新版本

GitHub 更新后，在 Codex 对话框直接说：

```text
请从 GitHub 同步更新 Keylink Image skill 到最新版本。
```

新版 skill 会执行随包提供的跨平台远程更新器，而不是再次调用只支持首次安装的 `$skill-installer`。更新器从本仓库 `main` 分支下载并验证新包，先备份旧版本，再替换 `~/.codex/skills/keylink-image`（设置了 `CODEX_HOME` 时使用对应目录）；不会修改 secrets、CCSwitch 数据或生成的图片。需要网络和写入权限时，Codex 会先请求批准。

更新完成后，新版本通常从下一轮对话开始生效；如果当前窗口仍使用旧内容，重启 Codex。GitHub push 不能无提示地直接写入每位用户的本地目录，因此默认采用用户在 Codex 中触发的一键同步，而不是后台强制更新。

如果当前网络需要代理，更新器会继承系统的 `HTTPS_PROXY`/`HTTP_PROXY`（macOS/Linux 也支持 `ALL_PROXY`）；也可以由 Codex 使用已知的代理地址调用对应的 `-ProxyUrl` 或 `--proxy-url` 参数。不会默认猜测或写死端口。

## macOS Terminal 一行安装或更新

macOS 自带 `curl`、`tar` 和 `bash`。在 Terminal 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Tilmirs/keylink-codex-image/main/install.sh | bash
```

脚本会下载仓库、验证 `SKILL.md` 和运行文件，再通过临时目录完成安装。生图运行时使用 Codex 提供的 Node.js，不需要安装 PowerShell、Homebrew 或取得管理员权限。已有版本会先备份到 `$HOME/.codex/skill-backups/keylink-image`（或 `$CODEX_HOME/skill-backups/keylink-image`），不会修改 secrets 或 CCSwitch 数据。

## 克隆仓库后本地安装或更新

Windows PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

macOS/Linux Terminal：

```bash
bash ./install.sh
```

两种本地命令都可以重复运行来更新。安装器会先把新版本复制到临时目录并验证，再替换现有版本。旧版本会备份，不会修改 secrets 或 CCSwitch 数据。

如果需要直接从终端触发已安装版本的远程更新：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\keylink-image\install.ps1" -Remote
```

```bash
bash "$HOME/.codex/skills/keylink-image/install.sh" --remote
```

这些是备用入口；日常使用时，在 Codex 中说“请从 GitHub 同步更新 Keylink Image skill”即可。

## 用户怎么使用

安装后，用户不需要输入代码、JSON、参数、路径或密钥。新版 skill 已把“生成、创建、绘制、渲染、编辑图片”等普通请求放到触发描述最前面，因此即使用户没有写 Keylink，Codex 也更容易选择本 skill。但 Codex 当前没有公开的 skill 优先级字段；当内置 ImageGen 与本 skill 同时匹配时，宿主仍可能选择内置 ImageGen。

不过 OpenAI 当前没有提供 skill 优先级字段；当 `keylink-image` 与内置 `imagegen` 同时匹配时，完全不提提供方的请求仍可能被宿主分配给 `imagegen`。需要确保走 Keylink 时，推荐以下任一种自然语言方式：

- 在输入框输入 `$`，选择 **Keylink Image (Preferred)**，再描述图片。
- 直接说“用 Keylink 生成一张……”。
- 明确写“不要使用内置 ImageGen，使用 Keylink”。

显式选择 skill 时可以直接这样说：

- “`$keylink-image` 生成一张电影感黑洞图片，保存到桌面。”
- “用 Keylink 列出我当前能用的图片模型和分辨率。”
- “用 Keylink 的第二个模型，横向高分辨率。”
- “`$keylink-image` 用 Gemini，16:9，保留参考图的构图并改成水彩风格。”

当可用模型或分辨率较多时，AI 会显示简短列表并优先推荐 `gpt-image-2`。用户可以回复模型名称、序号、`1536x1024`，或者“方形 / 横向 / 竖向”等自然语言。只说一个裸数字（例如 `3840`）不足以确定画幅，AI 会先询问正方形、横向或竖向，不会擅自按 `3840x3840` 执行。用户要求提高清晰度、改变分辨率，或指定预设之外的尺寸时，AI 会先列出可用尺寸和推荐候选，等用户选择后再执行。只有用户明确选择其他图片提供方或内置 ImageGen 时，才应离开 Keylink 流程。

## 能力

- 支持 `POST /v1/chat/completions` 生图和参考图编辑。
- 支持两种图生图流程：把上一轮生成结果作为下一轮输入继续修改，或直接把用户上传的图片和新的 prompt 一起发送；Images Edits 使用 `/v1/images/edits` 的 multipart `image` 文件字段，Chat 使用 `/v1/chat/completions`，同时发送标准 `messages[].content[].image_url` 和兼容的 `images[].image_url`，并返回保存后的修改图片。
- 未显式指定端点时，`gpt-image-2` 先尝试 Images（Generations/Edits），再尝试 Chat；Gemini 图片模型先尝试 Chat，再尝试 Images。HTTP 错误、200 但没有图片、图片下载失败都会继续尝试另一个端点；两个端点都失败才汇总错误并询问是否切换模型。显式选择 `images`、`chat` 或自定义端点时不切换。
- 支持 `POST /v1/images/generations` 文生图。
- 自动识别以下模型并按模型类型尝试两个端点，同时仍允许用户显式固定 Chat Completions：
  - `gpt-image-2`
  - `gemini-3-pro-image`
  - `gemini-2.5-flash-image`
  - `gemini-3.1-flash-image`
- 通过 `GET /v1/models` 发现当前凭据可用的图片模型和服务端公布的尺寸信息。
- `gpt-image-2` 和支持的 Gemini 图片模型统一使用保守尺寸 `1024x1024`、`1536x1024`、`1024x1536`，按用户要求的画幅选择；平台没有公布尺寸时不假定 `2048x2048`。
- 分辨率选择会优先展示 `1024x1024`、`1536x1024`、`1024x1536`；用户要求更清晰或指定其他尺寸时，会先展示服务端公布的尺寸，以及 `2560x1440`、`3840x2160` 这类“可尝试但渠道可能不支持”的候选，用户确认后才发起请求。
- “更高分辨率 / 高分辨率 / 高清 / 超高清 / 2K / 4K / UHD”或明确更大的像素尺寸都算高分辨率意图。16:9 高分辨率先尝试 `2560x1440`（2K 级），4K 尝试 `3840x2160`；用户选择的 `gpt-image-2` model ID 保持不变。
- 如果 4K 在模型目录中没有公布，会列出实际支持尺寸，同时提示可以尝试 `3840x2160` 但可能返回“不支持高分辨率”；用户确认前不会发起请求或本地放大，也不会把低分辨率结果称为 4K。已经发出的高分辨率请求会按端点策略重试但不降到 1K、不换模型；如果 Chat 成功，会注明像素尺寸不保证。
- 用户说“不满意”“画面不对”“把刚才的……改成……”等纠正意图时，会自动把最近一次成功生成的图片作为参考图；编辑提示只保留用户要求的变化，避免重复发送整段会话。无法判断是图生图还是全新生成时，会先询问用户；用户确认图生图后直接复用上一张图。
- 最近一次成功图片会按 Codex 任务线程保存，避免模型漏传参考图参数时产生无图请求；用户明确上传的新图片始终优先。
- 动态读取 Codex/CCSwitch 当前代理地址，并允许 AI 处理用户手动修改后的代理地址。
- 支持常见 OpenAI 兼容返回格式，包括 URL、Base64 和 Chat 消息中的图片。

模型 ID 是透传值，Keylink 后续新增模型时不一定需要修改 skill。只有需要加入自动路由白名单、适配新请求字段或新响应格式时，才需要改代码。

## 凭据与权限

- 直接访问 Keylink 时，可在用户批准后只读获取 CCSwitch 当前 Codex provider 的 Keylink 凭据。
- 凭据只保存在内存中，并且只能发送到 `keylinkclub.com`。
- 不会把直接 Keylink 凭据转发给本地代理，不会打印、提交或写入生成结果。
- 如果需要独立凭据，AI 应使用隐藏输入流程，不能要求用户把 API Key 粘贴到对话中。
- 读取 CCSwitch、向外发送请求或写入受保护位置前，由宿主软件向用户申请相应审批。

## 模型和分辨率

API Key 只负责鉴权，本身不包含模型列表或分辨率列表。skill 会查询 `/v1/models`：

- `AdvertisedSizes` / `AdvertisedAspectRatios` 表示 API 实际公布的能力。
- `AdvertisedResolutionTiers` 会按长边把已公布尺寸归类为 1K、2K、4K，便于选择；它不保证后端每个渠道都接受每个尺寸。
- `SuggestedSizes` / `SuggestedAspectRatios` 只是 API 未提供元数据时的候选项，必须明确标记为“未验证”。
- 默认分辨率策略是 GPT Image 和 Gemini 图片模型统一的保守 1K 尺寸：`1024x1024`、`1536x1024`、`1024x1536`。
- 裸写 `3840` 等单个数字不能确定画幅；需要先确认完整尺寸或宽高比，不能默认解释成 `3840x3840`。
- 用户提出更高分辨率时，16:9 使用 `2560x1440` 或 `3840x2160`；请求失败时返回原始错误和“不支持高分辨率”的具体原因，不自动降级。
- `3840` 级 4K 请求默认至少等待 8 分钟；如果用户指定更长超时，则使用更长时间。
- 如果 4K 未在模型能力中公布，先列出实际支持尺寸，同时提示 `3840x2160` 可以尝试但可能被渠道拒绝，再询问是尝试服务端生成还是本地放大；返回结果必须检查实际宽高。
- Nano Banana 参考梯度（模型级资料，当前 Keylink 渠道仍以 `/v1/models` 为准）：`gemini-2.5-flash-image` 为 1K；`gemini-3-pro-image` 支持 1K/2K/4K；`gemini-3.1-flash-image` 支持 512p/1K/2K/4K。Gemini 3 的 16:9 示例为 1K `1376x768`、2K `2752x1536`、4K `5504x3072`。
- Images Generations 使用像素尺寸；Chat Completions 优先使用宽高比。
- 保存图片后，AI 还会检查实际格式和宽高。

## 代理和端点规则

- 默认直连地址：`https://keylinkclub.com`
- Chat Completions：`/v1/chat/completions`
- Images Generations：`/v1/images/generations`
- Images Edits（参考图）：`/v1/images/edits`（`multipart/form-data`，文件字段 `image`）
- 模型发现：`/v1/models`
- Codex/CCSwitch 路由会在每次执行时读取当前 provider 地址，不固定 localhost 端口。
- 手动代理覆盖顺序为：显式代理地址、`KEYLINK_PROXY_BASE_URL`、Codex `config.toml`。
- 设置 `--proxy-base-url` 或 `KEYLINK_PROXY_BASE_URL` 后，自动生图也会使用该代理；没有代理覆盖时，已知图片模型的自动模式默认直连 Keylink。需要绕过代理时使用 `--route direct`。
- 某些本地 Codex 路由只支持 chat/responses，不支持 Images Edits。自动模式会按 GPT/Gemini 顺序测试两个端点并汇总失败信息；显式指定 `images`、`chat` 或自定义端点时保持用户选择不变。

## 项目结构

```text
keylink-image/
|-- SKILL.md                         AI 运行时入口
|-- AGENTS.md                        后续 AI 维护指南
|-- README.md                        安装与用户说明
|-- install.ps1                      Windows 首次安装和远程更新
|-- install.sh                       macOS/Linux 首次安装和远程更新
|-- agents/openai.yaml               Codex 展示信息
|-- scripts/generate_image.js        跨平台生图、编辑和保存（首选）
|-- scripts/list_image_models.js     跨平台模型与分辨率发现（首选）
|-- scripts/keylink_common.js        跨平台路由、凭据和请求公共逻辑
|-- scripts/*.ps1                    Windows 旧版兼容入口
|-- scripts/read_ccswitch_credential.js
|-- scripts/configure_key.ps1
|-- references/api.md
|-- references/troubleshooting.md
`-- tests/
```

后续由 AI 修改本项目时，先阅读 `AGENTS.md`。API 契约见 `references/api.md`，历史故障和恢复方式见 `references/troubleshooting.md`。

## 本地验证

维护者发布前运行：

```powershell
node .\tests\test_node_runtime.js
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_generate_image.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_list_image_models.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_install.ps1
```

macOS/Linux 安装器测试：

```bash
node ./tests/test_node_runtime.js
bash ./tests/test_install.sh
```

这些测试使用本地 mock 服务和假凭据，不会调用真实 Keylink API。
