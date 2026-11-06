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
https://cdn.jsdelivr.net/gh/wudidekongjv/infinite-canvas-sketchup-director-plugin@v0.1.5/dist/director.js
```

> 推荐用 `@v0.1.5` 这类的 tag 地址：jsDelivr 对分支（`@main`）有 12 小时缓存，改完代码立刻用 `@main` 可能还是旧版；tag 不可变，立即可用。想跟最新提交就用 `@main`，但要做好等缓存的心理准备。

装好后画布节点面板里会多出 **SU ⇄ 3D 导演台**。

---

## 三、用起来（就三步）

打开导演台后，右上角那块面板只有三个按钮。**机位直接用 SketchUp 的场景，不用记点。**

| 面板上的东西 | 作用 |
| --- | --- |
| 机位下拉（就是 SU 的场景） | 选一个场景 → 点「切过去」，SU 相机就跳到那个视角 |
| ① 把模型传进来当遮挡 | 有选中就传选中，没选中就传整个可见模型；只写深度、不显示外观 |
| ② 取一张当前视角当背景 | 把 SU 现在这一帧画面当导演台底图，随时可以重新点一次更新 |
| ③ 出片，放进画布 | 导演台逐帧渲染人物（被 SU 模型挡住的部分自动抠掉）→ SU 编码 mp4 → 画布上多一个视频节点 |

标准流程：

```
切场景 → ① 传模型 → ② 取背景 → 在导演台里摆人物和运镜 → ③ 出片
```

三个要点：

- **没有"记起点 / 记终点"了**：SU 的场景本身就是机位，选哪个就是哪个。
- **背景只取一张**，不逐帧渲染。人物动、背景静止；要换视角，切场景后再点一次 ②。
  这也正是这次修掉卡死的原因：原来一按就逐帧写 145 张 1920×1080，全跑在 SU 主线程，界面直接冻住。
- 出片后 mp4 经本机 http 回到画布，**画布上自动多一个视频节点**，不用去文件夹里翻。


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

## 六、排错：点了没反应 / 连不上

SketchUp 2026（Ruby 3.2）上有两个坑，v0.1.2 已经修掉。记下原因，以后遇到同类现象能自己判断：

| 现象 | 真正的原因 | 现在的做法 |
| --- | --- | --- |
| 点菜单「启动同步服务」，37740 端口在监听，但 `/su/ping` 一直超时 | `Thread` 里起的 `accept` 在 SketchUp 2026 根本不推进——线程对象在、端口在监听，就是没有代码去处理连接 | `bridge.rb` 改用 `UI.start_timer` 在主线程轮询 `accept_nonblock`，顺带让处理函数能安全碰 SketchUp API |
| 面板上的按钮点了没反应，状态一直显示「同步服务未启动」 | SketchUp 2026 的 `HtmlDialog` 里 JS 侧的 `sketchup.*` 桥不可用，回调进不到 Ruby | 面板改走 `http://127.0.0.1:37740/su/command`（与菜单同一套命令分发），状态每 1.5 秒拉一次 `/su/status`；打开面板时会自动把服务拉起来 |
| 点「渲染背景帧」，面板立刻显示「背景帧渲染失败（第 0 帧）：Too many arguments」 | SketchUp 2026 的 `View#write_image` 只接受**一个 Hash 参数**；老写法是 5～6 个位置参数，2026 直接拒绝 | 改成 Hash 形式（`filename/width/height/antialias/compression/transparent`），并对老版本保留位置参数回退（v0.1.4） |

> 改完 `main.rb` 这类插件代码，**必须重启 SketchUp 才会加载新代码**。这次排查时 SketchUp 2026 的 Ruby 控制台一直打不开，热重载这条路走不通，别浪费时间试。

自己确认服务是否活着（PowerShell 里跑，注意用系统自带的 curl 绝对路径）：

```powershell
C:\Windows\System32\curl.exe -s http://127.0.0.1:37740/su/ping
C:\Windows\System32\curl.exe -s http://127.0.0.1:37740/su/status
```

返回 `{"ok":true,...}` 说明插件这侧是通的；连不上就是 SketchUp 没开，或者服务没起来（重新打开一次面板即可）。

## 七、已知边界

- 机位目前是**起点 + 终点两点插值**，多机位序列还没做。
- 角色层单独渲染，**不接收 SU 场景阴影**，人物脚下没有接触阴影。
- 输出的 mp4 只有 H.264 画面，**没有音轨**。
- 遮挡精度取决于 SU 导出的面片数量（面板里可设上限，超了会截断）。

## 八、许可

- 本仓库的节点插件与 SketchUp 插件：AGPL-3.0（见 `LICENSE`）。
- 3D 导演台本体：MIT（见 `LICENSE-DIRECTOR.md`），上游参考自 `xiaozangao/3d-director-desk`。
- 节点插件形态参考 `esncy/infinite-canvas-director-plugin`。
- 导演台内置的人形/动作资源来自 Mixamo 与 Guo 3D Assets，商用前请自行确认对应模型许可。
