// Infinite Canvas 第三方节点插件：SU ⇄ 3D 导演台
// 通过公开 CDN 安装（dist/director.js）。节点负责把导演台页面装进 overlay iframe，
// 把 SUP 桥接地址（?suBridge=）带进去，并把导演台回传的截图变成画布图片节点。

const DEFAULT_DIRECTOR_URL = "http://127.0.0.1:5199/";
const DEFAULT_SU_BRIDGE = "http://127.0.0.1:37740";

const READY = "storyai:director-desk-ready";
const SESSION = "storyai:director-desk-session";
const CAPTURES_SENT = "storyai:director-desk-captures-sent";
const VIDEO_SENT = "storyai:director-desk-video";
const CLOSED = "storyai:director-desk-close";

function readText(value, fallback) {
    if (typeof value !== "string") return fallback;
    const text = value.trim();
    return text || fallback;
}

function normalizeBase(value, fallback) {
    const text = readText(value, fallback);
    try {
        return new URL(text, window.location.href).toString();
    } catch {
        return fallback;
    }
}

function normalizeBridge(value, fallback) {
    // 桥地址按段拼路由（/su/ping 之类），不能留尾斜杠
    return readText(value, fallback).replace(/\/+$/, "");
}

function originOf(url, fallback) {
    try {
        return new URL(url).origin;
    } catch {
        return fallback;
    }
}

function withQuery(base, params) {
    const url = new URL(base);
    for (const [key, value] of Object.entries(params)) {
        if (value) url.searchParams.set(key, value);
    }
    return url.toString();
}

function randomId(prefix) {
    if (typeof crypto?.randomUUID === "function") return `${prefix}-${crypto.randomUUID()}`;
    return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function themeMode(ctx) {
    const background = String(ctx.theme?.canvas?.background || "").replace("#", "");
    if (background.length !== 6) return "dark";
    const red = Number.parseInt(background.slice(0, 2), 16);
    const green = Number.parseInt(background.slice(2, 4), 16);
    const blue = Number.parseInt(background.slice(4, 6), 16);
    return (red * 299 + green * 587 + blue * 114) / 1000 > 150 ? "light" : "dark";
}

function buildPanoramas(ctx) {
    const upstream = ctx.getUpstream();
    const connections = ctx.getConnections();
    return upstream
        .filter((node) => node?.type === "image" && typeof node.metadata?.content === "string" && node.metadata.content)
        .map((node) => {
            const connection = connections.find((item) => item.fromNodeId === node.id && item.toNodeId === ctx.node.id);
            return {
                edgeId: connection?.id || `${node.id}->${ctx.node.id}`,
                sourceNodeId: node.id,
                imageUrl: node.metadata.content,
                fileName: node.title || "画布图片.png",
            };
        });
}

function imageSize(dataUrl) {
    return new Promise((resolve) => {
        const image = new Image();
        image.onload = () => resolve({ width: image.naturalWidth || 1024, height: image.naturalHeight || 576 });
        image.onerror = () => resolve({ width: 1024, height: 576 });
        image.src = dataUrl;
    });
}

function fitImageSize(width, height) {
    const maxWidth = 720;
    const maxHeight = 540;
    const scale = Math.min(1, maxWidth / Math.max(width, 1), maxHeight / Math.max(height, 1));
    return { width: Math.max(220, Math.round(width * scale)), height: Math.max(160, Math.round(height * scale)) };
}

async function sendCaptures(ctx, captures) {
    if (!captures.length) return;
    const director = ctx.node;
    const nodes = ctx.getNodes();
    const connections = ctx.getConnections();
    let y = director.position.y;
    for (const connection of connections) {
        if (connection.fromNodeId !== director.id) continue;
        const output = nodes.find((node) => node.id === connection.toNodeId);
        if (output?.type === "image") y = Math.max(y, output.position.y + output.height + 36);
    }

    const ops = [];
    for (const [index, capture] of captures.entries()) {
        const dataUrl = typeof capture?.dataUrl === "string" ? capture.dataUrl : "";
        if (!dataUrl.startsWith("data:image/")) continue;
        const natural = await imageSize(dataUrl);
        const size = fitImageSize(natural.width, natural.height);
        const id = randomId("su-director-capture");
        const title = typeof capture.fileName === "string" && capture.fileName.trim()
            ? capture.fileName.trim()
            : `导演台截图-${index + 1}.png`;
        ops.push({
            type: "add_node",
            id,
            nodeType: "image",
            title,
            x: director.position.x + director.width + 96,
            y,
            width: size.width,
            height: size.height,
            metadata: { content: dataUrl, status: "success", naturalWidth: natural.width, naturalHeight: natural.height, mimeType: "image/png" },
        });
        ops.push({ type: "connect_nodes", fromNodeId: director.id, toNodeId: id });
        y += size.height + 36;
    }
    if (ops.length) ctx.applyOps(ops);
}

/** 导演台合成好的 mp4：在画布里落一个视频节点。同一条视频重复发来只认第一次（幂等） */
function addVideoNode(ctx, payload) {
    const url = typeof payload?.url === "string" ? payload.url : "";
    if (!/^https?:\/\//.test(url)) return;

    const nodes = ctx.getNodes();
    if (nodes.some((node) => node?.metadata?.content === url)) return;

    const director = ctx.node;
    let y = director.position.y;
    for (const connection of ctx.getConnections()) {
        if (connection.fromNodeId !== director.id) continue;
        const output = nodes.find((node) => node.id === connection.toNodeId);
        if (output) y = Math.max(y, output.position.y + output.height + 36);
    }

    const title = typeof payload?.name === "string" && payload.name.trim() ? payload.name.trim() : "导演台成片.mp4";
    const width = Number(payload?.width) > 0 ? Math.round(Number(payload.width)) : 1122;
    const height = Number(payload?.height) > 0 ? Math.round(Number(payload.height)) : 670;
    const id = randomId("su-director-video");
    // 画布只认 nodeType:"image"；视频靠 metadata.mimeType="video/mp4" + content=mp4 地址 来当视频素材。
    // 位置同时写 position 和顶层 x/y，兼容两种 applyOps 实现。
    const x = director.position.x + director.width + 96;
    const ops = [
        {
            type: "add_node",
            id,
            nodeType: "image",
            title,
            position: { x, y },
            x,
            y,
            width: 480,
            height: Math.round(480 * height / width),
            metadata: {
                content: url,
                status: "success",
                mimeType: "video/mp4",
                naturalWidth: width,
                naturalHeight: height,
                isVideo: true,
            },
        },
        { type: "connect_nodes", fromNodeId: director.id, toNodeId: id },
    ];
    try {
        ctx.applyOps(ops);
    } catch (error) {
        console.warn("[su-director] 新建视频节点失败", error);
    }
}

function makeFieldStyle(ctx) {
    return {
        width: "100%",
        boxSizing: "border-box",
        border: `1px solid ${ctx.theme.node.stroke}`,
        borderRadius: 8,
        padding: "6px 8px",
        background: "transparent",
        color: ctx.theme.node.text,
        fontSize: 12,
        outline: "none",
    };
}

function makeLabelStyle(ctx) {
    return { color: ctx.theme.node.muted, fontSize: 11, marginBottom: 2 };
}

function DirectorContent({ ctx, React }) {
    const h = React.createElement;
    const [open, setOpen] = React.useState(false);
    const [status, setStatus] = React.useState("");
    const ctxRef = React.useRef(ctx);
    const panoramasRef = React.useRef([]);
    const sendRef = React.useRef(null);

    ctxRef.current = ctx;

    const savedDirectorUrl = ctx.node.metadata?.directorUrl;
    const savedBridge = ctx.node.metadata?.suBridge;
    const [directorUrl, setDirectorUrl] = React.useState(() => normalizeBase(savedDirectorUrl, DEFAULT_DIRECTOR_URL));
    const [suBridge, setSuBridge] = React.useState(() => normalizeBridge(savedBridge, DEFAULT_SU_BRIDGE));

    // 只在真的和节点已有的 metadata 不同时才写回：ctx 每次渲染都是新对象，
    // 直接依赖 ctx 会导致「写 metadata → 节点更新 → 重渲染 → 再写」的无限循环（React #185）。
    React.useEffect(() => {
        const meta = ctxRef.current.node?.metadata || {};
        if (meta.directorUrl === directorUrl && meta.suBridge === suBridge) return;
        ctxRef.current.updateMetadata?.({ directorUrl, suBridge });
    }, [directorUrl, suBridge]);

    React.useEffect(() => {
        if (!open) return undefined;
        let disposed = false;
        let frame = null;
        let sessionSent = false;
        let send = null;

        const directorOrigin = originOf(directorUrl, window.location.origin);
        panoramasRef.current = buildPanoramas(ctxRef.current);

        const overlay = document.createElement("div");
        overlay.style.cssText = "position:fixed;inset:0;z-index:2147483000;background:#090909";
        const loading = document.createElement("div");
        loading.textContent = "正在加载 3D 导演台…";
        loading.style.cssText = "position:absolute;inset:0;display:grid;place-items:center;color:#fff;font:14px system-ui,sans-serif;z-index:1;text-align:center;padding:24px;line-height:1.7";
        overlay.appendChild(loading);
        document.body.appendChild(overlay);

        const closeButton = document.createElement("button");
        closeButton.type = "button";
        closeButton.textContent = "关闭导演台";
        closeButton.style.cssText = "position:absolute;right:16px;top:12px;z-index:3;border:1px solid #ffffff44;border-radius:8px;padding:6px 10px;background:#0008;color:#fff;cursor:pointer";
        closeButton.onclick = () => setOpen(false);
        overlay.appendChild(closeButton);

        const handleMessage = (event) => {
            if (disposed || !frame) return;
            if (event.source !== frame.contentWindow) return;
            if (event.origin !== directorOrigin) return;
            const type = event.data?.type;

            if (type === READY) {
                if (sessionSent) return;
                sessionSent = true;
                loading.remove();
                send = (message) => frame?.contentWindow?.postMessage(message, directorOrigin);
                sendRef.current = send;
                send({ type: SESSION, payload: { instanceId: ctxRef.current.node.id, theme: themeMode(ctxRef.current) } });
                for (const panorama of panoramasRef.current) {
                    send({ type: "storyai:director-desk-panorama", payload: panorama });
                }
                return;
            }

            if (type === CAPTURES_SENT) {
                const captures = Array.isArray(event.data?.payload?.captures) ? event.data.payload.captures : [];
                void sendCaptures(ctxRef.current, captures);
                return;
            }

            if (type === VIDEO_SENT) {
                addVideoNode(ctxRef.current, event.data?.payload);
                return;
            }

            if (type === CLOSED) {
                setOpen(false);
            }
        };

        window.addEventListener("message", handleMessage);

        const url = withQuery(directorUrl, {
            hostOrigin: window.location.origin,
            theme: "dark",
            suBridge,
        });

        frame = document.createElement("iframe");
        frame.title = "SU 同步 3D 导演台";
        frame.allow = "fullscreen; clipboard-write";
        frame.referrerPolicy = "no-referrer";
        frame.style.cssText = "position:absolute;inset:0;width:100%;height:100%;border:0;z-index:2";
        frame.src = url;
        frame.onload = () => {
            // 导演台加载后自己会发 ready；这里只兜一个超时提示，避免用户面对黑屏。
            window.setTimeout(() => {
                if (!disposed && loading.parentNode && !sessionSent) {
                    loading.textContent = "导演台没有回传 ready，请确认它在运行、且地址带上了 hostOrigin 参数。";
                }
            }, 12000);
        };
        frame.onerror = () => {
            loading.textContent = `导演台加载失败：${directorUrl}`;
        };
        overlay.appendChild(frame);

        return () => {
            disposed = true;
            sendRef.current = null;
            window.removeEventListener("message", handleMessage);
            overlay.remove();
        };
    }, [open, directorUrl, suBridge, React]);

    React.useEffect(() => {
        if (!open || !sendRef.current) return;
        panoramasRef.current = buildPanoramas(ctxRef.current);
        for (const panorama of panoramasRef.current) {
            sendRef.current({ type: "storyai:director-desk-panorama", payload: panorama });
        }
    }, [open, React]);

    const buttonStyle = {
        border: `1px solid ${ctx.theme.node.stroke}`,
        borderRadius: 10,
        padding: "8px 16px",
        background: ctx.theme.toolbar.itemHover,
        color: ctx.theme.node.text,
        cursor: "pointer",
        fontSize: 13,
    };
    const labelStyle = makeLabelStyle(ctx);
    const fieldStyle = makeFieldStyle(ctx);

    return h(
        "div",
        {
            "data-canvas-no-zoom": true,
            style: {
                display: "flex",
                height: "100%",
                width: "100%",
                flexDirection: "column",
                alignItems: "stretch",
                justifyContent: "center",
                gap: 8,
                padding: 14,
                boxSizing: "border-box",
                color: ctx.theme.node.text,
            },
        },
        h("div", { style: { fontSize: 26, textAlign: "center" } }, "🎥"),
        h("div", { style: { fontSize: 15, fontWeight: 600, textAlign: "center" } }, "SU ⇄ 3D 导演台"),
        h("div", { style: { color: ctx.theme.node.muted, fontSize: 11, textAlign: "center", lineHeight: 1.6 } },
            "用 SketchUp 的机位和遮挡，驱动导演台里的人物与动作"),
        h("div", null,
            h("div", { style: labelStyle }, "导演台地址"),
            h("input", {
                style: fieldStyle,
                value: directorUrl,
                spellCheck: false,
                onMouseDown: (event) => event.stopPropagation(),
                onChange: (event) => setDirectorUrl(event.target.value),
            })),
        h("div", null,
            h("div", { style: labelStyle }, "SU 桥接地址"),
            h("input", {
                style: fieldStyle,
                value: suBridge,
                spellCheck: false,
                onMouseDown: (event) => event.stopPropagation(),
                onChange: (event) => setSuBridge(event.target.value),
            })),
        h("button", {
            type: "button",
            style: { ...buttonStyle, marginTop: 2 },
            onMouseDown: (event) => event.stopPropagation(),
            onClick: () => { setStatus(""); setOpen(true); },
        }, open ? "导演台已打开" : "打开导演台"),
        status ? h("div", { style: { color: "#ef9a9a", fontSize: 11, textAlign: "center" } }, status) : null,
    );
}

export default function createSuDirectorPlugin(runtime) {
    const React = runtime.React;
    return {
        id: "su-director",
        name: "SU ⇄ 3D 导演台",
        version: "0.1.0",
        minAppVersion: "0.12.0",
        description: "把 SketchUp 的机位轨道与遮挡几何体接进 3D 导演台，逐帧合成后回传成片。",
        nodes: [
            {
                type: "su-director:scene",
                title: "SU 同步导演台",
                icon: "🎥",
                description: "SketchUp 机位 + 遮挡 → 导演台角色层 → 合成视频",
                defaultSize: { width: 380, height: 340 },
                defaultMetadata: { directorUrl: DEFAULT_DIRECTOR_URL, suBridge: DEFAULT_SU_BRIDGE },
                hasSourceHandle: true,
                hidePanel: true,
                Content: (props) => DirectorContent({ ...props, React }),
            },
        ],
    };
}
