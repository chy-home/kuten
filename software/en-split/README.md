# 英文单词与短语提取器

这是一个可直接放在内网使用的静态网页应用，可离线运行；词典已拆分为独立 JSON 文件，便于继续扩容。

## 功能

- 上传 `txt` 会议记录文件
- 直接粘贴英文文本
- 提取英文单词并统计词频
- 提取重复出现的英文短语（2-3 词）
- 分词与在线翻译分步执行
- 尽量输出音标
- 在线查询结果自动缓存到 `data/catch.json`
- 一键复制结果
- 一键下载结果为 `txt`

## 使用方式

由于离线词典和查询缓存都使用独立 JSON 文件，请通过项目内置的 Node 服务访问，而不是直接双击打开 `index.html`：

```bash
node server.js
```

然后访问：

```text
http://localhost:8080
```

也可以用 `PORT=9000 node server.js` 指定端口。

## 音标说明

音标采用两层策略：

1. 内置常见会议/业务词汇音标词典
2. 对未命中的单词使用离线规则近似生成音标

因此：

- 常见词准确率较高
- 生僻词、专有名词、人名、缩写词可能只提供近似读音

如果你后续希望把音标准确率再提高，可以继续扩展 [data/ipa-dictionary.json](./data/ipa-dictionary.json)。

当前已补充较多会议、业务、项目管理、产品、研发相关高频词。新增词条时建议统一使用：

```json
"word": "/ipa/"
```

例如：

```json
"meeting": "/ˈmitɪŋ/"
```

## 词典结构

- [data/dictionary-manifest.json](./data/dictionary-manifest.json): 词典清单
- [data/ipa-dictionary.json](./data/ipa-dictionary.json): 音标词典
- [data/meaning-dictionary.json](./data/meaning-dictionary.json): 单词释义词典
- [data/phrase-meaning-dictionary.json](./data/phrase-meaning-dictionary.json): 短语释义词典

这套结构适合继续扩展到 `10MB+` 规模。后续如果词典继续膨胀，建议再按字母、领域或频次拆成多份 JSON 分片。

## 在线翻译

当前支持：

- `MyMemory` 公共接口
- `Google Cloud Translation API`
- `LibreTranslate` 兼容接口
- `Free Dictionary API` 单词音标补充

说明：

- `Google Cloud Translation API` 需要官方 API Key
- 纯静态前端直接调用 Google API 会暴露 Key，更推荐内网代理或后端转发
- `LibreTranslate` 公共站点通常需要 API Key，自建兼容服务更适合内网
- 点击“翻译”后才会请求在线服务；每次在线请求前会随机等待一小段时间，用于降低请求频率和减少公共接口限流风险

## 查询缓存

点击“翻译”并查询成功后，结果会自动写入 [data/catch.json](./data/catch.json)。刷新页面时会自动载入这个文件，后续再次分词相同单词或短语时，会优先使用文件缓存。

浏览器不能直接写入项目目录，所以需要用 `node server.js` 启动页面；如果只用普通静态服务，页面仍可查询，但无法把新增缓存写回 `data/catch.json`。

## 测试

```bash
node scripts/test-cache-flow.js
```

这个测试会验证服务写入 `data/catch.json`、页面刷新后读取文件缓存，以及二次查询不联网直接复用缓存。
## 离线词典扩展

项目现在支持分层离线词典：

- 基础层：`data/base-*.json`
- 业务层：`data/*.json`

加载顺序是基础层先加载，业务层后覆盖，便于接入较大的开源词典，同时保留 IT 广告业务自定义释义。

推荐开源来源：

- `ECDICT`：适合作为英汉释义基础层
- `CMUdict`：适合作为英文音标基础层

已内置导入脚本：

```bash
node scripts/import-ecdict.js /path/to/ecdict.csv
```

导入后可继续运行：

```bash
node scripts/enrich-delivery-ad-dictionaries.js
node scripts/test-cache-flow.js
```
