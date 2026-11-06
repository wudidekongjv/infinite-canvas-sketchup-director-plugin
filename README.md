# SU ⇄ 3D 导演台 · Infinite Canvas 节点插件

把 **SketchUp 的机位与选定模型** 当作骨架，在 3D 导演台里渲染人物与动作，最后合成一段「导演台相机拍到的角色可见部分（会被 SU 模型遮挡）+ SU 同视角同画幅」的镜头运动视频。

插件不改宿主源码，只使用 Infinite Canvas 公开的第三方插件运行时契约（`runtime.React` / `ctx`），因此可以直接按 CDN 地址安装，也兼容改版/多开画布。

---

## 一、它由三块组成

| 部件 | 位置 | 作用 |
| --- | --- | --- |
| 无限画布节点插件 | `src/` → `dist/director.js` | 在画布里放一个「SU 同步导演台」节点，点开是全屏导演台，截图可回传成画布图片节点 |
| 改造版 3D 导演台 | `director/` | 带 SU 同步面板的导演台构建产物（含机位帧优先、遮挡深度层、逐帧合成导出） |
| SketchUp 插件 | `sketchup/` | 在 SU 里起一个本地服务（默认 `127.0.0.1:37740`），导出机位轨道、遮挡 OBJ、背景帧，并调用 ffmpeg 合成 mp4 |

数据流：

```
SketchUp（机位/相机参数/选定模型 + 背景帧）
   │  HTTP  127.0.0.1:37740
   ▼
3D 导演台（SU 帧优先 → 角色按机位运动 → 遮挡层只写深度）
   │  HTTP  逐帧回传 layer / composite
   ▼
SketchUp 插件 → PNG 序列 → ffmpeg → mp4
```

---

## 二、安装（三步）

### 1. SketchUp 插件

把 `sketchup/` 里的两份东西复制到 SketchUp 的 Plugins 目录：

```
sketchup/su_to_director.rb      →  …\SketchUp\SketchUp 20xx\SketchUp\Plugins\su_to_director.rb
sketchup/su_to_director\        →  …\SketchUp\SketchUp 20xx\SketchUp\Plugins\su_to_director\
```

Windows 上通常是 `%APPDATA%\SketchUp\SketchUp 2026\SketchUp\Plugins\`。重启 SketchUp 后，菜单里会出现 **扩展程序 → SU 导演台同步**。

### 2. 起导演台本地服务

`director/` 是这个仓库里的导演台构建产物，用任意静态服务器指向它即可（**必须是本机 http，原因见第四节**）：

```bash
# 任选一种
npx serve director            # 默认 3000 端口
npx http-server director -p 5199
# 或者用仓库里的 启动导演台.ps1（vite preview，5199 端口）
```

插件里默认填的导演台地址就是 `http://127.0.0.1:5199/`，端口不一致时在节点面板里改一下即可。

### 3. 在无限画布里装节点插件（CDN）

在画布的「节点插件 / 第三方插件」里填：

```
https://cdn.jsdelivr.net/gh/wudidekongjv/infinite-canvas-sketchup-director-plugin@main/dist/director.js
```

> jsDelivr 对 `@main` 有缓存，刚推完代码如果 404，等几分钟，或把地址里的 `@main` 换成某个 tag（例如 `@v0.1.0`）。

装好后画布节点面板里会多出 **SU ⇄ 3D 导演台**。

---

## 三、用起来（四步）

1. **SU 里选好机位与物体**：在 SketchUp 摆好相机（可设起点/终点两个机位），选中要参与遮挡的模型（不选则用可见的全部）。
2. **开服务**：菜单 → 扩展程序 → SU 导演台同步 → 打开面板，点「开始服务」，确认状态灯是绿的（默认端口 37740）。
3. **画布里打开导演台**：新建「SU 同步导演台」节点 → 点「打开导演台」→ 面板右上角出现「SU 同步」小窗 → 点「连接」，能看到机位摘要、轨道时长。
4. **对齐 + 合成**：点「对齐时长」让导演台相机轨道跟 SU 一致 → 选渲染开关 → 「合成导出」逐帧渲染并回传给 SU → SU 面板里点「合成 mp4」。

面板上的四个开关：

| 开关 | 作用 |
| --- | --- |
| 包含道具/建筑 | 导出时不只渲染人物，把场景道具一起画进角色层 |
| 视口显示遮挡 | 在导演台视口里也画 SU 的遮挡深度层（预览用，导出时恒定开启） |
| 角色层单独渲染 | 角色层透明背景，只画人物，方便与 SU 背景对齐 |
| 导出时联动机位 | 导出期间按 SU 帧驱动相机与走路动画 |

---

## 四、为什么导演台要走本地 http 地址

导演台要和 SketchUp 的本地服务（`http://127.0.0.1:37740`）说话。浏览器有两条硬规则：

- **混合内容**：https 页面不能 fetch http 资源（`localhost` 在部分浏览器有豁免，但不通用）。
- **私有网络访问**：https 页面访问本机地址还会被 PNA 拦一道。

所以：

- 画布是**本地 http**（多开浏览器加载本地服务）：把导演台地址填成本机 http，一切正常。
- 想用 CDN 的 `director/index.html` 作 iframe（https）：导演台本身能跑，但**连不上 SU 桥**，只能用来预览/出纯导演台内容。

也就是说：`director/` 放在仓库里的意义是「一份不用自己构建的现成产物 + 模型/动作资源来源」，实际跑建议本机 http 起服务。这是浏览器限制，不是插件没做完。

---

## 五、目录结构

```
infinite-canvas-sketchup-director-plugin/
├─ src/index.js              无限画布节点插件源码
├─ dist/director.js          ← CDN 安装的就是这个
├─ build.mjs                 esbuild 打包脚本（npm i && npm run build）
├─ director/                 改造版 3D 导演台构建产物（index.html + assets + 模型/动作库）
├─ sketchup/
│  ├─ su_to_director.rb      SketchUp 扩展注册
│  └─ su_to_director/        服务、机位、遮挡、面板、编码脚本
├─ docs/使用说明.md          更细的排错与边界说明
├─ LICENSE                   AGPL-3.0
└─ LICENSE-DIRECTOR.md       3D 导演台本体的 MIT 许可
```

重新构建画布插件：

```bash
npm install
npm run build     # 产出 dist/director.js
```

重新构建导演台产物：在 3D 导演台源码目录里 `npm run build`，把 `dist/` 覆盖到本仓库 `director/`。

---

## 六、已知边界

- 机位目前是**起点 + 终点两点插值**，多机位序列还没做。
- 角色层单独渲染，**不接收 SU 场景阴影**，人物脚下没有接触阴影。
- 输出的 mp4 只有 H.264 画面，**没有音轨**。
- 遮挡精度取决于 SU 导出的面片数量（面板里可设上限，超了会截断）。

## 七、许可

- 本仓库的节点插件与 SketchUp 插件：AGPL-3.0（见 `LICENSE`）。
- 3D 导演台本体：MIT（见 `LICENSE-DIRECTOR.md`），上游参考自 `xiaozangao/3d-director-desk`。
- 节点插件形态参考 `esncy/infinite-canvas-director-plugin`。
- 导演台内置的人形/动作资源来自 Mixamo 与 Guo 3D Assets，商用前请自行确认对应模型许可。
