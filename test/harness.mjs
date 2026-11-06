// 在本地用 jsdom 模拟画布 runtime，验证插件节点不会因为 updateMetadata 触发无限重渲染（React #185）。
// 两种初始状态都要收敛：节点已有的 metadata 与默认值一致 / metadata 为空需要补写一次。
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "http://canvas-app/",
    pretendToBeVisual: true,
});
const w = dom.window;
const setGlobal = (name, value) => {
    try {
        Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
    } catch {
        // Node 里有些全局（如 navigator）是只读 getter，跳过即可
    }
};
setGlobal("window", w);
setGlobal("document", w.document);
setGlobal("navigator", w.navigator);
setGlobal("HTMLElement", w.HTMLElement);
setGlobal("Image", w.Image);
setGlobal("crypto", w.crypto || { randomUUID: () => String(Math.random()) });
setGlobal("MessageEvent", w.MessageEvent);
setGlobal("CustomEvent", w.CustomEvent);
setGlobal("URL", w.URL);
setGlobal("IS_REACT_ACT_ENVIRONMENT", true);

const React = (await import("react")).default;
const { createRoot } = await import("react-dom/client");
const { act } = await import("react-dom/test-utils");

const mod = await import("../dist/director.js");
const plugin = mod.default({ React });
const node = plugin.nodes.find((item) => item.type === "su-director:scene");
if (!node) throw new Error("没找到 su-director:scene 节点");

const THEME = {
    canvas: { background: "#111111" },
    node: { stroke: "#333333", text: "#ffffff", muted: "#888888" },
    toolbar: { itemHover: "#222222" },
};

async function run(label, initialMeta) {
    let meta = { ...initialMeta };
    let renders = 0;
    let updates = 0;
    const div = document.createElement("div");
    document.body.appendChild(div);
    const root = createRoot(div);

    function makeCtx() {
        return {
            node: {
                id: "n1",
                type: node.type,
                title: "SU 同步导演台",
                metadata: meta,
                position: { x: 100, y: 100 },
                width: 380,
                height: 340,
            },
            theme: THEME,
            getUpstream: () => [],
            getNodes: () => [],
            getConnections: () => [],
            applyOps: () => {},
            updateMetadata: (patch) => {
                updates++;
                if (updates > 300) throw new Error("updateMetadata 被无限调用（循环未切断）");
                meta = { ...meta, ...patch };
                rerender();
            },
        };
    }

    function App() {
        renders++;
        if (renders > 200) throw new Error("渲染次数失控（循环未切断）");
        return React.createElement(node.Content, { ctx: makeCtx() });
    }

    function rerender() {
        root.render(React.createElement(App));
    }

    try {
        await act(async () => {
            root.render(React.createElement(App));
        });
        await act(async () => {
            await new Promise((resolve) => setTimeout(resolve, 120));
        });
        return { label, ok: true, renders, updates, meta };
    } catch (error) {
        return { label, ok: false, error: String(error && error.message ? error.message : error), renders, updates };
    } finally {
        root.unmount();
        div.remove();
    }
}

const results = [];
results.push(await run("metadata 已有默认值", { directorUrl: "http://127.0.0.1:5199/", suBridge: "http://127.0.0.1:37740" }));
results.push(await run("metadata 为空", {}));

console.log(JSON.stringify(results, null, 2));
const allOk = results.every((item) => item.ok && item.renders <= 4 && item.updates <= 2);
process.exit(allOk ? 0 : 1);
