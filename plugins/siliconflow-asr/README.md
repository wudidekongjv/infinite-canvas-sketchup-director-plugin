# 语音转文字（硅基流动 SenseVoice）

无限画布的第三方节点插件。把画布里的音频送到
`POST https://api.siliconflow.cn/v1/audio/transcriptions`，转写结果落成文本节点。

## 安装

画布 → 设置 → 节点插件 → 第三方 → 填入：

```
https://cdn.jsdelivr.net/gh/wudidekongjv/infinite-canvas-sketchup-director-plugin@main/plugins/siliconflow-asr/dist/sf-asr.js
```

装完在节点菜单里能看到「语音转文字」。

## 用法

1. 拖一个「语音转文字」节点到画布。
2. 节点面板里填硅基流动的 API Key（`sk-…`，只保存到这个节点的 metadata，不会外发）。
3. 音频来源二选一：
   - 从左边连一个音频节点进来；或
   - 点「选本地文件」直接选一个音频文件（推荐，见下面第一条限制）。
4. 点「开始转写」。
5. 结果出来后点「落成文本节点」，会在右边生成一个文本节点并自动连线。

## 已知边界

- **画布素材库里的音频抓不到。** 素材库走 `canvas-assets` 虚拟域，禁止跨域，
  页面里的 `fetch` 拿不到文件。上游节点只有在 `metadata.content` 是 `data:` 或
  `blob:` 时才能读。所以最稳的用法是本地选文件。
- **没有时间戳、没有 SRT。** 硅基流动这个端点只返回纯文本
  `{"text","language","usage":{"seconds"}}`，`response_format` / `timestamp_granularities`
  这些参数一个都没实现，别指望出字幕时间轴。
- 单文件 ≤ 50MB、时长 ≤ 1 小时。
- 可选模型只有 `FunAudioLLM/SenseVoiceSmall` 和 `TeleAI/TeleSpeechASR`；
  填 `whisper-1` 会返回 `400 code 20012 Model does not exist`。

## 为什么是插件而不是「模型渠道」

画布渠道的能力位只有 `image / video / text / audio`，`audio` 的语义固定是
「文本 → 语音」（TTS），调用时只传文本 prompt。整份主程序里搜 `transcriptions`
零命中，`audio` 能力位下没有任何拿音频文件做输入的入口。所以 ASR 没有插座，
只能走节点插件。

## 排错

| 现象 | 原因 |
| --- | --- |
| `401 code 30014 Token is invalid` | `Authorization` 少写了 `Bearer ` 前缀 |
| `400 code 20012 Model does not exist` | 模型名写成了 `whisper-1` 之类 |
| `400 code 20015 The parameter is invalid` | 漏了 `model` 字段 |
| `403 Forbidden` | key 被禁或额度/权限不足 |
| 返回 500 空体 | 用 JSON 发的请求，必须是 `multipart/form-data` |
| 404 | Base URL 少了 `/v1` |
| 转写成功但 `text` 为空 | 音频里没有人声，或采样率过高/静音段太长 |

## 开发

```bash
npm install
npm run build      # 产出 dist/sf-asr.js
node test/smoke.mjs
```
