# Keylink Image Skill

这是一个给 Codex 等支持 skills 的 AI 软件使用的图片生成与编辑 skill。用户只需用自然语言描述图片、模型、画幅和保存位置，AI 负责模型发现、接口调用、权限申请、凭据读取和结果验证。

## 一条命令安装

在本项目目录中打开 PowerShell，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

安装位置为 `$CODEX_HOME\skills\keylink-image`；未设置 `CODEX_HOME` 时使用 `%USERPROFILE%\.codex\skills\keylink-image`。

同一条命令也用于更新。安装器会先把新版本复制到临时目录并验证 `SKILL.md`，再替换现有版本。旧版本会备份到 `$CODEX_HOME\skill-backups\keylink-image`，不会修改 `$CODEX_HOME\secrets` 或 CCSwitch 数据。安装完成后，新 skill 会在 Codex 的下一轮对话中可用；如果没有被发现，重启 Codex。

## 从 GitHub 安装

仓库发布后，在 Codex 中直接发送下面这句话即可，不需要自己输入脚本或复制文件：

```text
请从 https://github.com/Tilmirs/keylink-codex-image 安装 keylink-image skill。
```

Codex 会使用内置的 skill 安装流程，并在写入 skills 目录前申请所需权限。

## 用户怎么使用

安装后，用户不需要输入代码、JSON、参数、路径或密钥，可以直接说：

- “生成一张电影感黑洞图片，保存到桌面。”
- “列出我当前能用的图片模型和分辨率。”
- “用第二个模型，横向高分辨率。”
- “用 Gemini，16:9，保留参考图的构图并改成水彩风格。”

当可用模型或分辨率较多时，AI 会显示简短列表。用户可以回复模型名称、序号、`1536x1024`，或者“方形 / 横向 / 竖向”等自然语言。

## 能力

- 支持 `POST /v1/chat/completions` 生图和参考图编辑。
- 支持 `POST /v1/images/generations` 文生图。
- 自动路由以下模型到 Keylink Images Generations，同时仍允许用户显式选择 Chat Completions：
  - `gpt-image-2`
  - `gemini-3-pro-image`
  - `gemini-2.5-flash-image`
  - `gemini-3.1-flash-image`
- 通过 `GET /v1/models` 发现当前凭据可用的图片模型和服务端公布的尺寸信息。
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
- `SuggestedSizes` / `SuggestedAspectRatios` 只是 API 未提供元数据时的候选项，必须明确标记为“未验证”。
- Images Generations 使用像素尺寸；Chat Completions 优先使用宽高比。
- 保存图片后，AI 还会检查实际格式和宽高。

## 代理和端点规则

- 默认直连地址：`https://keylinkclub.com`
- Chat Completions：`/v1/chat/completions`
- Images Generations：`/v1/images/generations`
- 模型发现：`/v1/models`
- Codex/CCSwitch 路由会在每次执行时读取当前 provider 地址，不固定 localhost 端口。
- 手动代理覆盖顺序为：显式代理地址、`KEYLINK_PROXY_BASE_URL`、Codex `config.toml`。
- 某些本地 Codex 路由只支持 chat/responses，不支持 images。遇到 404 时不能偷偷换模型或端点；应说明原因，并在用户批准后改用直连 Keylink。

## 项目结构

```text
keylink-image/
|-- SKILL.md                         AI 运行时入口
|-- AGENTS.md                        后续 AI 维护指南
|-- README.md                        安装与用户说明
|-- install.ps1                      一键安装和更新
|-- agents/openai.yaml               Codex 展示信息
|-- scripts/generate_image.ps1       生图、编辑和保存
|-- scripts/list_image_models.ps1    模型与分辨率发现
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
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_generate_image.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_list_image_models.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_install.ps1
```

这些测试使用本地 mock 服务和假凭据，不会调用真实 Keylink API。
