// Infinite Canvas 第三方节点插件：语音转文字（硅基流动 SenseVoice）
//
// 一句话：把这个节点接在一个音频节点后面，点「转写」，音频会被送到
// POST https://api.siliconflow.cn/v1/audio/transcriptions，结果落成一个文本节点。
//
// 设计取舍（都是踩点结论，不是拍脑袋）：
// 1. 画布的能力位只有 image/video/text/audio，audio 的语义固定是「文本 → 语音」（TTS），
//    调用时只传 prompt，拿不到音频文件。所以 ASR 做不进「模型渠道」，只能走节点插件。
// 2. 硅基流动这个端点的 CORS 是全放行的（Access-Control-Allow-Origin: *），
//    插件里直接 fetch 就行，不需要本地代理，也不会踩混合内容。
// 3. 请求里绝对不要手动设 Content-Type —— 让浏览器自己带 multipart boundary。
// 4. Authorization 必须是 "Bearer <key>"，漏掉 Bearer 会返回 401 {"code":30014,"message":"Token is invalid."}
// 5. 画布的 canvas-assets 是 DenyCors，页面 fetch 不到素材库里的文件；
//    所以本地文件选择是主路径，上游节点只在 content 是 data:/blob: 时可靠。

const DEFAULT_BASE_URL = "https://api.siliconflow.cn/v1";
const MODELS = ["FunAudioLLM/SenseVoiceSmall", "TeleAI/TeleSpeechASR"];
const MAX_BYTES = 50 * 1024 * 1024; // 官方限制：单文件 ≤ 50MB、时长 ≤ 1 小时

function randomId(prefix) {
    try {
        if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
            return `${prefix}-${crypto.randomUUID()}`;
        }
    } catch {
        // 老浏览器兜底
    }
    return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

function parseErrorBody(text, status) {
    const raw = String(text || "").trim();
    if (!raw) return `HTTP ${status}`;
    try {
        const json = JSON.parse(raw);
        const message = json?.message || json?.error?.message || json?.detail;
        if (message) return `${message}${json?.code ? `（code ${json.code}）` : ""}`;
    } catch {
        // 401 是裸字符串 "Invalid token"，不是 JSON，直接原样返回
    }
    return `HTTP ${status}: ${raw.slice(0, 200)}`;
}

function isAudioNode(node) {
    if (!node) return false;
    const mime = String(node?.metadata?.mimeType || "").toLowerCase();
    if (mime.startsWith("audio/")) return true;
    const type = String(node?.type || "");
    if (type === "audio" || type.endsWith(":audio")) return true;
    const content = String(node?.metadata?.content || "");
    return /^data:audio\//i.test(content) || /\.(mp3|wav|m4a|aac|ogg|flac|webm)(\?|#|$)/i.test(content);
}

/** 找上游第一个音频节点（连线进来的） */
function findUpstreamAudio(ctx) {
    let list = [];
    try {
        list = ctx.getUpstream?.() || [];
    } catch {
        list = [];
    }
    for (const node of list) {
        if (node?.id === ctx.node?.id) continue;
        if (!isAudioNode(node)) continue;
        const content = node?.metadata?.content;
        if (typeof content === "string" && content.trim()) {
            return { node, content: content.trim() };
        }
    }
    return null;
}

/** 把节点的 content（dataURL / blobURL / httpURL）变成 Blob */
async function contentToBlob(content, name) {
    if (content.startsWith("data:")) {
        const response = await fetch(content);
        return { blob: await response.blob(), name };
    }
    if (content.startsWith("blob:")) {
        const response = await fetch(content);
        return { blob: await response.blob(), name };
    }
    if (/^https?:/i.test(content)) {
        let response;
        try {
            response = await fetch(content, { mode: "cors", credentials: "omit" });
        } catch (error) {
            throw new Error("这个音频是画布素材库地址（canvas-assets 禁止跨域），页面抓不到。请点下面的「选本地文件」重新上传一次。");
        }
        if (!response.ok) throw new Error(`读取音频失败：HTTP ${response.status}`);
        return { blob: await response.blob(), name };
    }
    throw new Error("上游音频节点的 content 不是可读取的地址");
}

async function callTranscriptions({ baseUrl, apiKey, model, blob, name, signal }) {
    const key = String(apiKey || "").trim();
    if (!key) throw new Error("先在面板里填硅基流动的 API Key");
    if (!key.startsWith("sk-")) throw new Error("API Key 一般以 sk- 开头，确认没贴错");
    if (blob.size > MAX_BYTES) throw new Error(`文件 ${(blob.size / 1048576).toFixed(1)}MB，超过 50MB 上限`);

    const form = new FormData();
    form.append("file", blob, name || "audio.mp3");
    form.append("model", model);

    const url = String(baseUrl || DEFAULT_BASE_URL).replace(/\/+$/, "") + "/audio/transcriptions";
    const response = await fetch(url, {
        method: "POST",
        headers: { Authorization: "Bearer " + key }, // 不要加 Content-Type
        body: form,
        signal,
    });

    const body = await response.text();
    if (!response.ok) throw new Error(parseErrorBody(body, response.status));

    let json = null;
    try {
        json = JSON.parse(body);
    } catch {
        throw new Error("返回的不是 JSON：" + body.slice(0, 200));
    }
    const text = typeof json?.text === "string" ? json.text : "";
    if (!text) throw new Error("接口返回成功，但 text 是空的（可能音频里没有人声）");
    return { text, language: json?.language || "", seconds: json?.usage?.seconds ?? null };
}

function styles(ctx) {
    const node = ctx?.theme?.node || {};
    return {
        field: {
            width: "100%",
            boxSizing: "border-box",
            border: `1px solid ${node.stroke || "#ffffff33"}`,
            borderRadius: 8,
            padding: "6px 8px",
            background: "transparent",
            color: node.text || "#eee",
            fontSize: 12,
            outline: "none",
        },
        label: { color: node.muted || "#999", fontSize: 11, marginBottom: 2 },
        button: {
            border: `1px solid ${node.stroke || "#ffffff33"}`,
            borderRadius: 8,
            padding: "7px 10px",
            background: "transparent",
            color: node.text || "#eee",
            fontSize: 12,
            cursor: "pointer",
            width: "100%",
        },
    };
}

function AsrContent({ ctx, React }) {
    const h = React.createElement;
    const ctxRef = React.useRef(ctx);
    ctxRef.current = ctx;

    const meta = ctx.node?.metadata || {};
    const [baseUrl, setBaseUrl] = React.useState(meta.baseUrl || DEFAULT_BASE_URL);
    const [apiKey, setApiKey] = React.useState(meta.apiKey || "");
    const [model, setModel] = React.useState(MODELS.includes(meta.model) ? meta.model : MODELS[0]);
    const [picked, setPicked] = React.useState(null);
    const [busy, setBusy] = React.useState(false);
    const [status, setStatus] = React.useState("");
    const [result, setResult] = React.useState(meta.result || "");
    const [seconds, setSeconds] = React.useState(meta.seconds ?? null);
    const fileRef = React.useRef(null);

    // 只在真的变了才写回 metadata：ctx 每次渲染都是新对象，直接依赖会「写 → 更新 → 重渲染 → 再写」死循环
    React.useEffect(() => {
        const m = ctxRef.current.node?.metadata || {};
        if (m.baseUrl === baseUrl && m.apiKey === apiKey && m.model === model) return;
        ctxRef.current.updateMetadata?.({ baseUrl, apiKey, model });
    }, [baseUrl, apiKey, model]);

    const upstreamAudio = findUpstreamAudio(ctx);
    const s = styles(ctx);

    const stop = (event) => event.stopPropagation();

    async function resolveAudio() {
        if (picked) return { blob: picked, name: picked.name || "audio.mp3" };
        if (!upstreamAudio) throw new Error("没有音频：先在左边连一个音频节点，或点「选本地文件」");
        const name = `${upstreamAudio.node.title || "audio"}`.replace(/[\\/:*?"<>|]/g, "_");
        return contentFromUpstream(upstreamAudio.content, name);
    }

    async function contentFromUpstream(content, title) {
        const wantName = /\.[a-z0-9]{2,5}$/i.test(title) ? title : `${title}.mp3`;
        const got = await contentToBlob(content, wantName);
        return { blob: got.blob, name: wantName };
    }

    async function run() {
        if (busy) return;
        setBusy(true);
        setStatus("正在转写…");
        try {
            const audio = await resolveAudio();
            const r = await callTranscriptions({
                baseUrl, apiKey, model,
                blob: audio.blob,
                name: audio.name,
            });
            setResult(r.text);
            setSeconds(r.seconds);
            setStatus(`完成 · ${r.seconds ?? "?"} 秒${r.language ? ` · ${r.language}` : ""}`);
            ctxRef.current.updateMetadata?.({
                result: r.text,
                seconds: r.seconds,
                language: r.language,
                fileName: audio.name,
            });
        } catch (error) {
            setStatus(String(error?.message || error));
        } finally {
            setBusy(false);
        }
    }

    function addTextNode() {
        const node = ctxRef.current.node;
        const text = String(result || "").trim();
        if (!text) {
            setStatus("还没有转写结果");
            return;
        }
        const id = randomId("sf-asr-text");
        const x = (node?.position?.x ?? 0) + (node?.width ?? 360) + 96;
        const y = node?.position?.y ?? 0;
        const title = `转写 · ${(meta.fileName || "音频").slice(0, 40)}`;
        try {
            ctxRef.current.applyOps?.([
                {
                    type: "add_node",
                    id,
                    nodeType: "text",
                    title,
                    position: { x, y },
                    x,
                    y,
                    width: 380,
                    height: 240,
                    metadata: { content: text, status: "success" },
                },
                { type: "connect_nodes", fromNodeId: node?.id, toNodeId: id },
            ]);
            setStatus("已落成文本节点");
        } catch (error) {
            setStatus("建文本节点失败：" + String(error?.message || error));
        }
    }

    async function copyResult() {
        try {
            await navigator.clipboard.writeText(String(result || ""));
            setStatus("已复制");
        } catch {
            setStatus("复制失败，手动选中吧");
        }
    }

    return h("div", {
        style: {
            display: "flex",
            width: "100%",
            height: "100%",
            flexDirection: "column",
            alignItems: "stretch",
            gap: 8,
            padding: 12,
            boxSizing: "border-box",
            overflow: "auto",
            color: ctx.theme.node.text,
        },
    },
    h("div", { style: { fontSize: 15, fontWeight: 600 } }, "🎙 语音转文字 · 硅基流动"),
    h("div", { style: { color: ctx.theme.node.muted, fontSize: 11, lineHeight: 1.6 } },
        "SenseVoice 转写，结果可落成文本节点"),

    h("div", null,
        h("div", { style: s.label }, "API Key（只存在本节点，不会上传）"),
        h("input", {
            style: s.field,
            type: "password",
            autoComplete: "new-password",
            spellCheck: false,
            placeholder: "sk-…",
            value: apiKey,
            onMouseDown: stop,
            onChange: (event) => setApiKey(event.target.value),
        })),

    h("div", null,
        h("div", { style: s.label }, "模型"),
        h("select", {
            style: s.field,
            value: model,
            onMouseDown: stop,
            onChange: (event) => setModel(event.target.value),
        }, MODELS.map((name) => h("option", { key: name, value: name }, name)))),

    h("div", null,
        h("div", { style: s.label }, "音频"),
        h("div", { style: { color: ctx.theme.node.muted, fontSize: 11, marginBottom: 4 } },
            picked ? `本地文件：${picked.name}（${(picked.size / 1048576).toFixed(2)}MB）`
                : upstreamAudio ? `上游节点：${upstreamAudio.node.title || upstreamAudio.node.id}`
                    : "未连接音频节点"),

        h("input", {
            ref: fileRef,
            type: "file",
            accept: "audio/*,.mp3,.wav,.m4a,.aac,.ogg,.flac,.webm",
            style: { display: "none" },
            onChange: (event) => {
                const f = event.target.files?.[0] || null;
                setPicked(f);
                setStatus("");
            },
        }),
        h("button", {
            type: "button",
            style: { ...s.button, marginTop: 2 },
            onMouseDown: stop,
            onClick: () => fileRef.current?.click(),
        }, picked ? "换一个文件" : "选本地文件"),
        picked ? h("button", {
            type: "button",
            style: { ...s.button, marginTop: 4, borderColor: "#ffffff22" },
            onMouseDown: stop,
            onClick: () => { setPicked(null); if (fileRef.current) fileRef.current.value = ""; },
        }, "改用上游节点") : null),

    h("button", {
        type: "button",
        style: { ...s.button, marginTop: 4, fontWeight: 600 },
        disabled: busy,
        onMouseDown: stop,
        onClick: run,
    }, busy ? "转写中…" : "开始转写"),

    status ? h("div", { style: { fontSize: 11, lineHeight: 1.5, color: busy ? "#ffd54f" : "#9ccc65" } }, status) : null,
    seconds ? h("div", { style: { fontSize: 11, color: ctx.theme.node.muted } }, `音频时长：${seconds} 秒`) : null,

    result ? h("div", null,
        h("div", { style: s.label }, "转写结果"),
        h("div", {
            style: {
                border: `1px solid ${ctx.theme.node.stroke}`,
                borderRadius: 8,
                padding: "8px 10px",
                fontSize: 12,
                lineHeight: 1.7,
                maxHeight: 160,
                overflow: "auto",
                whiteSpace: "pre-wrap",
                wordBreak: "break-word",
            },
        }, result),
        h("div", { style: { display: "flex", gap: 6, marginTop: 6 } },
            h("button", {
                type: "button",
                style: { ...s.button, flex: 1 },
                onMouseDown: stop,
                onClick: addTextNode,
            }, "落成文本节点"),
            h("button", {
                type: "button",
                style: { ...s.button, flex: 1 },
                onMouseDown: stop,
                onClick: copyResult,
            }, "复制"))) : null,
    );
}

export default function createSiliconFlowAsrPlugin(runtime) {
    const React = runtime.React;
    return {
        id: "sf-asr",
        name: "语音转文字（硅基流动）",
        version: "0.1.0",
        minAppVersion: "0.12.0",
        description: "把画布里的音频交给硅基流动 SenseVoice 转写，结果落成文本节点。",
        nodes: [
            {
                type: "sf-asr:transcribe",
                title: "语音转文字",
                icon: "🎙",
                description: "上游音频节点 → /v1/audio/transcriptions → 文本节点",
                defaultSize: { width: 380, height: 460 },
                defaultMetadata: {
                    baseUrl: DEFAULT_BASE_URL,
                    apiKey: "",
                    model: MODELS[0],
                },
                hasSourceHandle: true,
                hidePanel: true,
                Content: (props) => AsrContent({ ...props, React }),
            },
        ],
    };
}
