# AGENTS.md

## 工作区用途

这个目录用于在 macOS Intel 机器上本地运行、测试和管理 GGUF 语言模型。

当前主模型：

- `models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf`

当前还存在一个额外本地模型：

- `models/Hermes-3-Llama-3.1-8B.Q4_K_M.gguf`

## 本地环境

- 操作系统：macOS
- CPU：Intel i9
- 内存：32 GB
- 显存：4 GB
- 首选推理栈：`llama.cpp`
- 可用工具：`llama-cli`、`llama-server`、`ollama`、`wget`、`curl`、`node`、`npm`

## 重要文件

- `models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf`：当前主要使用的本地 GGUF 模型文件
- `models/Hermes-3-Llama-3.1-8B.Q4_K_M.gguf`：额外可切换的本地 GGUF 模型文件
- `index.html`：当前本地小说写作主页，已包含工具菜单入口
- `novel2img.html`：小说正文转长图、排版和导出工具页
- `datas/setting.json`：页面默认配置，包含模型名、系统提示词和采样参数
- `datas/roles.json`：小说角色卡列表
- `datas/chapters.json`：章节数据持久化文件
- `server.js`：本地静态页面服务（含 JSON 写入 API）
- `package.json`：页面启动脚本，支持 `npm start`

除非用户明确要求，不要重命名、移动或删除这类大型模型文件。

## 默认运行建议

这台机器运行 12B GGUF 时，应默认优先使用 CPU 推理。

推荐基础命令（CPU）：

```bash
llama-cli -m ./models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf -c 8192 -ngl 0
```

可选的显卡分层测试（macOS Metal）：

```bash
llama-cli -m ./models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf -c 8192 -ngl 8
```

本地服务模式，仅本机访问：

```bash
llama-server -m /Users/cyril/NSFW_AI/models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf -c 8192 --host 127.0.0.1 --port 8080 --alias hermes3-local -ngl 0
```

本地服务模式，尝试分层到显卡：

```bash
llama-server -m /Users/cyril/NSFW_AI/models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf -c 8192 --host 127.0.0.1 --port 8080 --alias hermes3-local -ngl 8
```

当前 `datas/setting.json` / 首页默认提示给用户的一键启动命令是绝对路径版：

```bash
llama-server -m /Users/cyril/NSFW_AI/models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf -c 8192 --host 127.0.0.1 --port 8080 --alias hermes3-local -ngl 8
```

局域网访问版本：

```bash
llama-server -m ./models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf -c 8192 --host 0.0.0.0 --port 8080 --alias hermes3-local -ngl 0
```

## OpenAI 兼容接口调用示例

`llama-server` 提供 OpenAI 兼容接口，包含 `/v1/models` 和 `/v1/chat/completions`。

先查看当前服务暴露的模型名：

```bash
curl -s http://127.0.0.1:8080/v1/models
```

如果按上面的命令启动服务，模型别名就是 `hermes3-local`，可以直接这样请求：

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "hermes3-local",
    "messages": [
      {"role": "system", "content": "你是一名擅长长篇叙事的小说助手。"},
      {"role": "user", "content": "写一个开场场景，长度约 800 字。"}
    ],
    "temperature": 0.9,
    "top_p": 0.95,
    "max_tokens": 1200,
    "stream": false
  }'
```

如果要流式输出：

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "hermes3-local",
    "messages": [
      {"role": "user", "content": "写一个开场场景，长度约 800 字。"}
    ],
    "temperature": 0.9,
    "top_p": 0.95,
    "max_tokens": 1200,
    "stream": true
  }'
```

常见说明：

- 如果启动时没有设置 `--alias hermes3-local`，先调用 `/v1/models` 查看实际模型名，再把请求里的 `model` 改掉。
- 如果只是本机调用，保持 `--host 127.0.0.1` 更安全。
- 默认端口这里使用 `8080`，如果改了 `--port`，请求地址也要一起改。

## 当前页面与工具

当前工作区已经包含一个本地网页写作台，默认文件如下：

- `index.html`：前端页面
- `novel2img.html`：长图排版与导出页面
- `server.js`：Node 静态服务
- `package.json`：包含 `npm start`
- `datas/setting.json`：页面默认配置
- `datas/roles.json`：角色卡数据

页面当前特性：

- `index.html` 当前为护眼羊皮纸风格的写作主页，顶部提供"工具菜单"
- 通过 `llama-server` 的 OpenAI 兼容接口调用本地模型
- 页面采样参数支持直接手调：`temperature`、`top_p`、`min_p`、`repeat_penalty`、`repeat_last_n`、`max_tokens`
- 系统提示词默认从 `datas/setting.json` 读取，支持页面手改，默认 2 行高度可拖拽
- 角色卡从 `datas/roles.json` 读取，支持多选并注入到故事设定中
- 支持叙事视角约束：`第一人称`（默认）、`第三人称有限`、`全知上帝视角`
- 选择 `第一人称` 或 `第三人称有限` 时，必须指定主视角角色
- 支持接续写作模式：当前正文草稿可继续微调后发给模型；模型输出会直接更新草稿区
- 模型输出的 `<think>`、`<analysis>` 等标签内容会单独显示在思考过程区域，不混入正文
- 支持"查看提示词"弹窗，预览最终发送给模型的完整消息序列
- 当接口不可达时，页面会显示推荐的 `llama-server` 启动命令并支持一键复制
- 支持章节管理：可新建 / AI 生成大纲 / 保存 / 删除章节，数据持久化至 `datas/chapters.json`
- 章节下拉菜单支持选取历史大纲
- `novel2img.html` 支持标题输入、正文自动分段重排、主题切换、字号调整和图片导出
- `novel2img.html` 支持背景平铺水印和 PNG 长图导出

## 多提供商支持（2025-06 新增）

当前页面支持多 LLM 提供商切换：

### 已内置的提供商

| 提供商 ID | 名称 | 需 API Key | 典型模型 |
|-----------|------|-----------|---------|
| `local` | 本地模型 (llama-server) | 否 | `hermes3-local` |
| `groq` | Groq (免费高速) | 是 | `llama3-70b-8192`, `llama3-8b-8192` |
| `openrouter` | OpenRouter (免费模型) | 是 | `google/gemma-4-31b-it:free` 等 |
| `deepseek` | DeepSeek (低价优质) | 是 | `deepseek-chat` |

### 切换方式

1. 打开页面，在「采样参数」面板中找到「模型提供商」下拉菜单
2. 选择目标提供商（本地 / Groq / OpenRouter / DeepSeek）
3. 如果提供商需要 API Key，页面自动从 `datas/setting.json` 的 `apiKeys` 字段读取，无需手填
4. 点击「探测服务」验证连通性
5. 在「模型选择」下拉菜单中选取具体的模型变体

### API Key 配置

**API Key 直接写在 `datas/setting.json` 的 `apiKeys` 对象中**，以提供商 ID 为 key：

```json
{
  "currentProviderId": "openrouter",
  "apiKeys": {
    "local": "",
    "groq": "gsk_你的_Groq_Key",
    "openrouter": "sk-or-v1-你的_OpenRouter_Key",
    "deepseek": "sk_你的_DeepSeek_Key"
  }
}
```

- 切换提供商时，Key 自动填入
- 切换提供商时，Key 自动填入
- **不要将包含真实 Key 的 `setting.json` 提交到 Git**

### OpenRouter 免费套餐限制

OpenRouter 免费套餐（不充值）每天仅 **50 次请求**，用满后返回 `429` 错误：
```
Rate limit exceeded: free-models-per-day
```

**解决方案：**
- **充值 $10+** — 解锁每日 1000 次免费模型请求配额（免费模型依然免费，只是配额提升）
- **或切回本地模型** — 提供商选「本地模型 (llama-server)」，用本机的 Magnum 12B GGUF

### 模型 NSFW 标注

2025-06 已对 OpenRouter 所有可用模型逐一测试成人内容响应，`datas/setting.json` 中 `note` 字段标注：
- `🔞 NSFW 可用` — 生成成人内容通过（92 个）
- `🙅 拒绝成人内容` — 明确拒绝（57 个）
- `⏳ 限流未测` — 测试时被限流（2 个）
- `✅ 成人` — 用户指定保留、不测试的模型

模型选择下拉使用 `<datalist>` 实现，点击输入框弹出全部选项，输入文字实时过滤，无需额外搜索框。

### 代理机制

外部提供商请求通过 Node 服务端 `/api/proxy` 转发，避免浏览器的 CORS 限制。API Key 从 `setting.json` 读取，每次请求时传给服务端用于代理转发。

### 添加新的提供商

编辑 `datas/setting.json` 中的 `providers` 数组，格式示例：

```json
{
  "id": "my-provider",
  "name": "我的提供商",
  "baseUrl": "https://api.example.com/v1",
  "needsApiKey": true,
  "defaultModel": "my-model",
  "models": ["my-model", "my-model-2"]
}
```

要求：目标提供商必须兼容 OpenAI `chat/completions` 接口格式。

### 已知功能缺口（资深作者视角）

当前页面满足基础对话式生成，但离完整小说工具有以下差距：

核心缺失：
1. **章节 / 大纲管理** — 当前支持章节增删改、AI 生成大纲和 JSON 持久化，但还缺少分卷、拖拽排序和批量操作。
2. **长期记忆与摘要压缩** — 当前只拼接历史指令和正文草稿，token 超限后旧内容直接丢失，缺少自动摘要压缩机制。
3. **局部改写 / 选中重写** — 不能选中正文某段让模型改写、扩写或删减，只能全量接续。
4. **写作风格指南 / 禁用词表** — 没有统一管理用词偏好、禁止词汇、描写风格约束的地方。

次一级缺口：
5. **多版本草稿 / 对比** — 只有一个草稿区，无法保留多个版本或回退。
6. **导出** — 只有复制剪贴板，缺少 Markdown / TXT / EPUB 导出。
7. **会话保存 / 恢复** — localStorage 只存当前状态，没有多会话管理。
8. **场景卡 / 节拍规划** — 先列场景清单，再逐个展开成正文。

页面本地启动方式：

```bash
npm start
```

或：

```bash
node server.js
```

默认页面地址：

```bash
http://127.0.0.1:3000
```

长图工具地址：

```bash
http://127.0.0.1:3000/novel2img.html
```

当前 `datas/setting.json` 默认模型接口：

```bash
http://127.0.0.1:8080/v1
```

当前 `datas/setting.json` 默认模型名：

```bash
hermes3-local
```

## 实际下载方式

本工作区当前模型是通过镜像成功下载的，下面这条命令已经实际验证可用：

```bash
wget -c -O models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf \
  "https://hf-mirror.com/InferenceIllusionist/magnum-12b-v2.5-kto-iMat-GGUF/resolve/main/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf?download=true"
```

如果需要使用 `curl`：

```bash
curl -L -C - -o models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf \
  "https://hf-mirror.com/InferenceIllusionist/magnum-12b-v2.5-kto-iMat-GGUF/resolve/main/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf?download=true"
```

官方 Hugging Face 直链版本：

```bash
wget -c -O models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf \
  "https://huggingface.co/InferenceIllusionist/magnum-12b-v2.5-kto-iMat-GGUF/resolve/main/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf?download=true"
```

说明：

- 下载前先检查 `models/` 目录里的目标 GGUF 是否已经存在。
- 优先使用支持断点续传的方式：`wget -c` 或 `curl -C -`。
- 当前环境里，直连 `huggingface.co` 曾出现超时，因此镜像是实际成功的下载方式。
- 除非用户另有要求，下载文件默认放在 `models/` 目录。

## 目录约定

当前工作区已经部分采用以下结构，后续建议继续沿用：

- `models/`：存放 GGUF 模型
- `prompts/`：存放可复用的提示词模板
- `scripts/`：存放启动、测速、转换等脚本
- `output/`：存放生成结果和测试输出

不要为了满足这个结构而自动移动当前已有模型文件，也不要为了整理目录复制大型模型。

## Agent 工作规则

- 优先做小范围、可回退的修改。
- 不要重复复制大型模型文件。
- 除非确有必要，避免执行会重写或复制这个 7 GB GGUF 的命令。
- 做测速或测试时，明确记录实际执行的命令。
- 如果以后初始化 Git，不要提交 GGUF 二进制文件，应将其加入 `.gitignore`。

## 校验信息

当前模型校验值：

- `models/magnum-12b-v2.5-kto-iMat-Q4_K_M.gguf`
- `sha256: c679c575d909e52e4c92444ded142001b46c07fc6aff5f398e25da1c5433e0da`
