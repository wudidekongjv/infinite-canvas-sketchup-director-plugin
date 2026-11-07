// 冒烟测试：只验证插件导出结构与节点契约，不触网、不依赖 DOM
import createPlugin from "../dist/sf-asr.js";

const fakeReact = {
    createElement: (tag, props, ...children) => ({ tag, props, children }),
    useState: (v) => [v, () => { }],
    useEffect: () => { },
    useRef: (v) => ({ current: v }),
    useMemo: (fn) => fn(),
};

const plugin = createPlugin({ React: fakeReact });

const checks = [];
const ok = (name, cond) => checks.push([name, !!cond]);

ok("id", plugin.id === "sf-asr");
ok("name", typeof plugin.name === "string" && plugin.name.length > 0);
ok("nodes 是数组且有 1 项", Array.isArray(plugin.nodes) && plugin.nodes.length === 1);

const node = plugin.nodes?.[0] || {};
ok("node.type", typeof node.type === "string" && node.type.includes(":"));
ok("title", typeof node.title === "string" && node.title.length > 0);
ok("defaultSize", node.defaultSize && node.defaultSize.width > 0 && node.defaultSize.height > 0);
ok("hasSourceHandle", node.hasSourceHandle === true);
ok("Content 是函数", typeof node.Content === "function");
ok("defaultMetadata.baseUrl", node.defaultMetadata?.baseUrl === "https://api.siliconflow.cn/v1");
ok("defaultMetadata.model", node.defaultMetadata?.model === "FunAudioLLM/SenseVoiceSmall");
ok("不带 key 出厂", node.defaultMetadata?.apiKey === "");

// 渲染一次 Content，确认它不炸（用假 ctx）
let rendered = null;
try {
    rendered = node.Content({ ctx: { node: { id: "n1", metadata: {}, position: { x: 0, y: 0 }, width: 380, height: 460, title: "t" }, theme: { node: { stroke: "#333", text: "#eee", muted: "#999" } }, getUpstream: () => [], updateMetadata: () => { }, applyOps: () => { } }, React: fakeReact });
} catch (error) {
    rendered = { error: String(error?.message || error) };
}
ok("Content 渲染不抛错", rendered && !rendered.error);

for (const [name, pass] of checks) {
    console.log(`${pass ? "PASS" : "FAIL"}  ${name}`);
}
const failed = checks.filter(([, p]) => !p).length;
console.log(`\n${checks.length - failed}/${checks.length} passed`);
console.log("nodeType =", node.type);
process.exit(failed ? 1 : 0);
