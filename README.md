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

**最省事：整仓压缩包**（8.4 MB，除了 `ffmpeg.exe` 之外全都在里面）

```
https://github.com/wudidekongjv/infinite-canvas-sketchup-director-plugin/archive/refs/tags/v0.1.31.zip
```

解压后，把 `sketchup/` 里的两样东西复制到 Plugins 目录：

```
sketchup/su_to_director.rb      →  …\SketchUp\SketchUp 20xx\SketchUp\Plugins\su_to_director.rb
sketchup/su_to_director\        →  …\SketchUp\SketchUp 20xx\SketchUp\Plugins\su_to_director\
```

Windows 上通常是 `%APPDATA%\SketchUp\SketchUp 2026\SketchUp\Plugins\`。重启 SketchUp 后，菜单里会出现 **扩展程序 → SU 导演台同步**。

**只想下单个文件**也行，CDN 上都在（前缀 `https://cdn.jsdelivr.net/gh/wudidekongjv/infinite-canvas-sketchup-director-plugin@v0.1.31/sketchup/`）：

| 文件 | 作用 |
| --- | --- |
| `su_to_director.rb` | 扩展注册，放 Plugins **根目录** |
| `su_to_director/main.rb` | 命令分发、机位、导出、编码 |
| `su_to_director/occluder.rb` | 遮挡 OBJ 导出 |
| `su_to_director/bridge.rb` | 本地 HTTP 服务（主线程 `accept_nonblock` 轮询） |
| `su_to_director/camera_track.rb` | 机位帧 |
| `su_to_director/config.rb` | 默认参数（端口 37740 / 24fps / 6s） |
| `su_to_director/panel_html.rb` | 面板 HTML |
| `su_to_director/tools/encode_video.py` | 备用的 Python 编码脚本（Ruby 直接调 ffmpeg 时用不到） |

> **不用点菜单**：插件一加载就会自己把同步服务起在 `127.0.0.1:37740`，打开导演台面板就直接连上。菜单里的「启动/停止同步服务」只是备用开关。

> **出片还要一份 ffmpeg**：仓库里不带 `ffmpeg.exe`（105 MB，超过 GitHub 单文件 100 MB 硬限，已经写进 `.gitignore` 排除），放到：
>
> ```
> …\Plugins\su_to_director\tools\ffmpeg.exe
> ```
>
> 插件的查找顺序是 `SU_DIRECTOR_FFMPEG` 环境变量 → `tools\ffmpeg.exe` → `tools\ffmpeg` → 系统 `PATH`，所以丢进 `tools` 最稳，跟 PATH 有没有 ffmpeg 无关；都没有就在点 ③ 时报「找不到 ffmpeg」。
>
> 拿一份的办法：`pip install imageio-ffmpeg`，到 `site-packages\imageio_ffmpeg\binaries\` 把 `ffmpeg-win-x86_64-*.exe` 复制出来改名 `ffmpeg.exe`；或者用任意一份全功能 ffmpeg 直接改名。实测可用的版本是 `ffmpeg 9.0.2-essentials_build-www.gyan.dev`。
>
> 不想动目录，也可以用环境变量指个路（**用户级**，改完要重启 SketchUp）：
>
> ```powershell
> [Environment]::SetEnvironmentVariable('SU_DIRECTOR_FFMPEG','D:\tools\ffmpeg.exe','User')
> ```
>
> 验证这份 ffmpeg 真的能跑：
>
> ```powershell
> & "$env:APPDATA\SketchUp\SketchUp 2026\SketchUp\Plugins\su_to_director\tools\ffmpeg.exe" -version
> ```

### 2. 本机起一个静态服务（连 SU 时这一条不能省）

导演台要和 SketchUp 的 `http://127.0.0.1:37740` 说话。SU 桥是**明文 http + 本机私有地址**，https 页面调不到（混合内容 + Private Network Access 双重拦截，见第四节）。所以真正干活的时候，导演台页面必须由**本机 http** 提供：

```powershell
cd <仓库根>
node tools/serve-director.mjs 5199
```

零依赖，只用 Node 标准库，作用是把仓库里的 `director/` 目录原样提供出来。起好后地址是：

```
http://127.0.0.1:5199/?instanceId=desk_2
```

`instanceId` 自己起个名；多开画布窗口时用它区分各自的工作台状态。

### 3. 在无限画布里装节点插件

在画布的「节点插件 / 第三方插件」里填：

```
https://cdn.jsdelivr.net/gh/wudidekongjv/infinite-canvas-sketchup-director-plugin@v0.1.31/dist/director.js
```

装好后画布节点面板里会多出 **SU ⇄ 3D 导演台**。

装完还有一步：把这个节点的「导演台地址」改成上面那条本机 http 地址（`http://127.0.0.1:5199/?instanceId=desk_2`）。节点默认会按安装地址自动推断成 CDN 上的 https 页面，那样**能开、能预览，但连不上 SU 桥**——原因就是第四节那两条浏览器限制。

> **别用 `@main`**：jsDelivr 对分支有 12 小时缓存。改完代码立刻用 `@main`，可能拿到的还是旧的 `director/index.html`，而它引用的旧 assets 已经被删了，表现就是白屏。tag 不可变、立即可用，所以地址一律写 `@v0.1.25` 这种 tag。

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

几点说明：

- **没有"记起点 / 记终点"了**：SU 的场景本身就是机位，选哪个就是哪个。
- **背景只取一张**，不逐帧渲染。人物动、背景静止；要换视角，切场景后再点一次 ②。
  当初把「逐帧渲染」改成「只取一张」，就是为了避开这个卡死：原来一按就逐帧写 145 张 1920×1080，全跑在 SU 主线程，界面直接冻住。
- **画幅就是成片画幅**：面板里选 16:9 / 9:16 / 1:1 / 4:3 之后，导演台那块画面立刻变成那个比例，
  背景按 cover 铺满、多出来的边角裁掉（不拉伸、也不留黑边），相机视野按同样的裁切量收窄，
  所以人物落点和 SU 背景始终对得上。视口里看到的就是成片，不用出完片再猜。
- **第一视角看到的就是成片**：模型本体默认不显影，但它照样挡住人物（挡法见第八节）。
  面板里的「第一视角显示模型淡影（对位检查）」只在你需要肉眼核对模型和照片对没对上时才勾，
  勾上会多一层蓝色淡影；**遮挡不会因此失效**，这层淡影也永远不会进到成片里。
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
│     └─ tools/ffmpeg.exe    ← 不入库，自己放（见第二节）
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

SketchUp 2026（Ruby 3.2）上踩过几个坑，v0.1.2 前后陆续修掉。记下原因，以后遇到同类现象能自己判断：

| 现象 | 真正的原因 | 现在的做法 |
| --- | --- | --- |
| 点菜单「启动同步服务」，37740 端口在监听，但 `/su/ping` 一直超时 | `Thread` 里起的 `accept` 在 SketchUp 2026 根本不推进——线程对象在、端口在监听，就是没有代码去处理连接 | `bridge.rb` 改用 `UI.start_timer` 在主线程轮询 `accept_nonblock`，顺带让处理函数能安全碰 SketchUp API |
| 面板上的按钮点了没反应，状态一直显示「同步服务未启动」 | SketchUp 2026 的 `HtmlDialog` 里 JS 侧的 `sketchup.*` 桥不可用，回调进不到 Ruby | 面板改走 `http://127.0.0.1:37740/su/command`（与菜单同一套命令分发），状态每 1.5 秒拉一次 `/su/status`；打开面板时会自动把服务拉起来 |
| 点「渲染背景帧」，面板立刻显示「背景帧渲染失败（第 0 帧）：Too many arguments」 | SketchUp 2026 的 `View#write_image` 只接受**一个 Hash 参数**；老写法是 5～6 个位置参数，2026 直接拒绝 | 改成 Hash 形式（`filename/width/height/antialias/compression/transparent`），并对老版本保留位置参数回退（v0.1.4） |
| 模型和背景总差一点，模型看着「小一圈」 | SU 的 `Camera#fov` 是横向 FOV，被当成纵向塞进了 three | 按 `camAspect` 换算成纵向 FOV（55° → **42.751°**），见第七节（v0.1.24） |
| 人物能穿过课桌，或者勾了淡影什么也看不见 | 遮挡层被「可见性」开关串联，或淡影被同位置的深度层吃掉 | 「可见性」只管导演视角实体，深度遮挡恒开；深度层后移 `polygonOffset +1`，见第八节（v0.1.25） |
| 换了 `@main` 地址后画布节点白屏 | jsDelivr 分支缓存 12 小时，旧 `index.html` 指向已删除的 assets | 装 tag 地址（`@v0.1.31`），别用 `@main` |

> 改完 `main.rb` 这类插件代码，**必须重启 SketchUp 才会加载新代码**。这次排查时 SketchUp 2026 的 Ruby 控制台一直打不开，热重载这条路走不通，别浪费时间试。

自己确认服务是否活着（PowerShell 里跑，注意用系统自带的 curl 绝对路径）：

```powershell
C:\Windows\System32\curl.exe -s http://127.0.0.1:37740/su/ping
C:\Windows\System32\curl.exe -s http://127.0.0.1:37740/su/status
```

返回 `{"ok":true,...}` 说明插件这侧是通的；连不上就是 SketchUp 没开，或者服务没起来（重新打开一次面板即可）。

## 七、对齐的真相：SU 的 `Camera#fov` 是**纵向**，不是横向

模型和背景对不上，根子不在模型缩放，也不在机位坐标，而在一句被误读的参数。v0.1.24 把它读成横向，于是越标定越歪；v0.1.26 用真机数据一次定了性。

**怎么定的**：插件里有个 `view_probe` 命令，抓 36 个模型顶点，把它们的 `world` 坐标和 SU 视口里的真实 `uv` 一起吐出来，再拿几种投影假设反算比对。

| 假设 | 平均残差 |
| --- | --- |
| `fov` 是**纵向**（55° 直接塞进 three） | **0.02 px** |
| `fov` 是横向，按 `aspect_ratio` 4:3 折成 42.751° | 237.57 px |
| `fov` 是横向，按视口 1122×671 折 | 294.04 px |
| 纵向 + 反向叉积（手性错） | 874.90 px |

结论：**`cam.fov = 55` 就是纵向视野，直接塞给 `PerspectiveCamera.fov` 即可。**

那 v0.1.24 的 42.751° 是怎么来的？当时按「横向 ÷ camAspect」折算，把 55° 折成 42.751°，再在 1.33 的框里标定到「残差 0.01px」——等于把错口径调到了自洽，还把 42.751 当成权威值写进代码。表现就是背景照片被放大一圈、模型小一圈，怎么调都差一点。

**第二个坑：`camAspect` 的兜底是错的。** `/su/status` 的 `bg.view` 里本来就没有 `camAspect`，它常报 `0.0`，SU 的意思是「跟随视口」。前端以前把「非数值/越界」一律兜底成 1.33，可真实视口是 1122×671 = **1.6721**。现在：`fovAxis` 不是 `horizontal` 就一律按纵向、`camAspect` 为 0 不再当合法值、比例优先取 `vp.w/vp.h`，最后才兜底 4:3。

画幅切换只改变「裁多少」，不改变透视：画幅比照片宽时按 cover 裁掉上下，同时把纵向 FOV 同比收窄（`tan 收缩 = 照片宽高比 / 画幅宽高比`），剩下的可见范围仍和照片严丝合缝。

**画幅框不再被面板压住（v0.1.26）**：第一视角的虚线框以前只给右边留 16 px，理由是「SU 面板是浮层，点收起就看见了」——实际它直接钻到「属性」栏底下。现在左「场景层级」栏、右「属性」栏、浮在最上面的「SU ⇄ 导演台」面板，三者宽度**运行时按真实 DOM 量**（`measureSuStageInsets`），画幅永远只铺在中间那块可见区域，不用点收起也能看全。

## 八、遮挡是怎么做的（v0.1.25）

SU 导出的 OBJ 在这套流程里**不是模型，是深度**。同一个文件按场合换三种材质：

| 场合 | 外观 | 材质 | 结果 |
| --- | --- | --- | --- |
| 出片（离屏画布） | `depth` | `MeshBasicMaterial{ colorWrite:false, depthWrite:true, depthTest:true, side:DoubleSide }` | 只写深度、不写颜色：人物被挡的部分不出画，画面里看不到模型 |
| 第一视角（默认） | `depth` | 同上 | 和成片一模一样的遮挡关系，所以视口里就能预判成片 |
| 第一视角（勾了淡影） | `ghost` | 淡影层 `{ color:#4FA8FF, opacity:0.2, depthWrite:false }` **＋** 同几何 `clone(true)` 的深度层 | 看得见淡蓝模型，人物照样被挡住 |
| 导演视角 | `solid` | `MeshStandardMaterial{ flatShading:true, side:DoubleSide }` | 灰蓝实体，摆场景时看得见教室体积 |

两个踩过的坑，写在这里省得再踩：

1. **「SU 模型可见性」那只眼睛不是总开关。** 它只管导演视角里显不显示实体模型；第一视角和出片的深度遮挡**恒开**，眼睛关掉也照样挡人。以前把它串在遮挡层最前面，结果是一关眼睛连深度都不画了，画面就是「模型不显影 + 人物随便穿墙」，看着像遮挡完全没生效。
2. **淡影层和深度层是同一份几何、同一位置。** 深度值相等时能不能看见，取决于偏移方向：给淡影层做「往近处」偏移，很多驱动会把它判成更远、整层被深度层吃掉，表现就是「勾了淡影什么也没有、取消再勾像卡住」。现在改成**把深度层往后推一点点**（`polygonOffset +1`，约 0.1 cm 级，肉眼无差），淡影就能稳定透过来。

另外两个细节：

- **同一份几何只占一份内存**：淡影模式下的深度副本是 `clone(true)`，共享 `BufferGeometry`，不会把 50 MB 的模型再复制一遍。
- **`renderOrder`**：深度层固定排最前（`-1`），只写深度不写颜色；后面画的人物才会被判成「在模型后面」而被裁掉。

## 九、已知边界

- 机位就是 SU 的场景，**不记起点终点**；要换视角就切场景，再点一次 ②。
- 出片长度**跟着导演台时间轴走**：时间轴多长就出多长，24fps 固定（0.5–30 秒 → 13–721 帧）。面板 ③ 上方直接写着本次「几秒 / 几帧」。
- 时间轴没设过的话，用的是默认时长（和底部时间轴面板显示的那个数一致），不再是固定的 5 秒。
- 导出的是「只写深度」的遮挡层，所以**在导演台视口里默认看不见模型本体**，它只在出片和第一视角里负责挡住人物。想知道模型到底传进来没有，看面板 ① 后面的面数与体积；想肉眼核对模型和照片对没对上，勾「第一视角显示模型淡影（对位检查）」（v0.1.25 起该开关可反复开关、不会再吞掉遮挡）。
- 背景是**一张静态图**，出片时每帧把机位重新贴一次；运镜时间长了会看出背景是定住的。
- SU 侧 `main.rb` 的 `calibrate_fov_axis`（探针判断 fov 是纵向还是横向）**目前恒返回 `vertical`**：横向 FOV 时探针点会越出画面被裁成边界值，与「正好落在边界」无法区分。SU 2026 的 `fov_is_horizontal` 返回 nil、`aspect_ratio` 返回 0.0，所以这条判据暂时没法做准。实测当前 SU 确实是纵向，因此不改它也不出错；**如果哪天 SU 换成横向 FOV 口径，前端会跟着报错**——到那时先核 `view_probe` 的残差再动。
- 角色层单独渲染，**不接收 SU 场景阴影**，人物脚下没有接触阴影。
- 输出的 mp4 只有 H.264 画面，**没有音轨**。
- 视频节点必须是 `type: "video"`（`add_node` 的 `nodeType` 会被宿主直接当节点类型用）。传成 `"image"` 的话，节点会建出来但里面是空的——宿主管它叫图片节点，用 `<img>` 去加载 mp4，只能图裂。若你的画布版本不认，mp4 仍然在 `su_director_export\video\` 里可以直接打开。
- SU 的视口高度常常是奇数（比如 671），而 yuv420p 要求宽高都是偶数，所以导出时会自动补一行/列（成片是 1122×670），肉眼无差。

## 十、修过什么

| 版本 | 提交 | 关键改动 |
| --- | --- | --- |
| v0.1.31 | 见 tag | **成片时长不再写死 5 秒**：以前 `FRAME_COUNT` 是常量 120 帧，时间轴设 3 秒或 10 秒出来的片子一律 5 秒。现在帧数 = `round(时间轴时长 × 24) + 1`，跟导演台时间轴等长（口径和 SU 侧建轨道一致），面板上写明本次几秒几帧。**同时修掉一个被固定帧数掩盖的坑**：SU 的 `/su/frame` 只往里写不清目录，帧数一变少，上一轮多出来的旧帧会被 ffmpeg 一起编进成片；现在点 ③ 会先调 `reset_frames` 清掉上一轮帧，编码再用 `-frames:v 实际帧数` 兜底 |
| v0.1.30 | 见 tag | **节点建出来了但是空壳**：宿主的 `add_node` 把 `nodeType` 直接当节点 `type` 用，而类型决定渲染器。之前传 `"image"`，宿主就拿 `<img>` 去打一个 mp4，结果节点出现在画布上、里面什么都没有（缩略图图裂）。改成 `nodeType: "video"`，metadata 按宿主的视频字段补齐（`content` / `status` / `mimeType` / `naturalWidth` / `naturalHeight`），尺寸用视频默认 420 并按比例算高 |
| v0.1.29 | 见 tag | **出片落不进画布，真凶是宿主没接住消息，不是前端没发**：① 去掉 `event.origin` 严格校验——srcdoc 装配出来的页面 origin 可能是 `null`，死卡它会把整条消息悄悄丢掉且毫无提示；改用 `event.source` 认身份，宿主回消息也改成 `targetOrigin: "*"`。② 新建节点从导演台右下方挪到**正下方**——往右排会被画布视口右缘裁掉，看着就像「没建节点」。③ 面板加**真回执**：宿主处理完回一条 ack，成功显示「画布已新建视频节点」，失败显示具体原因，4 秒没回执直接报「消息没被接住」——不再有「提示发了、其实没建」 |
| v0.1.28 | 见 tag | 视频节点的落位计算加防御：下游节点缺 `height` / `position` 字段时按 0 处理，不再把 `NaN` 写进 `position`（位置是 `NaN` 的节点画布画不出来，表现和「没建节点」一样） |
| v0.1.27 | 见 tag | **出片后画布自动落视频节点**。以前点 ③ 会先拿 `/su/status` 里**上一轮**留下的旧 mp4 发进画布（这时新视频还没编完），等新 mp4 出来面板已经归空闲、不再发——表现就是「点了出片，画布里没有视频节点」。现在按「本次出片开始时刻」做门槛，只认之后写出来的 mp4，URL 带 `?v=<at>` 既能破浏览器缓存，也让画布每次新建节点而不是当成同一条跳过 |
| v0.1.26 | 见 tag | **对齐口径纠正**：SU `cam.fov` 实测是纵向（36 点残差 0.02 px），55° 直接用；v0.1.24 的 42.751° 是错口径下的自洽值，已废弃。`camAspect` 0.0 不再当合法值，比例按视口 `vp.w/vp.h` 算。**画幅框不再被面板压住**：左右边距改为运行时实测左栏 / 属性栏 / SU 浮层 |
| v0.1.25 | `47f00b3` | 第一视角恢复遮挡（「SU 模型可见性」不再当总开关）；淡影与遮挡同时生效，开关可反复切换；深度层改为后推偏移，淡影不再被自己吃掉 |
| v0.1.24 | `a97cb9e` | 当时判断「SU `Camera#fov` 是 1.33 框的横向 FOV，应换算成 42.751°」——**这个结论是错的，已被 v0.1.26 推翻** |
| v0.1.23 | `4e1e67c` | 画幅改为「视口画幅 = 成片画幅 + cover 铺满」：多出来的边角裁掉，不拉伸、不留黑，相机 FOV 同步收窄 |
| v0.1.22 | `ac0da7f` | 一度改成 contain 留黑，效果不达标，已被 v0.1.23 取代，**别照它做** |
| v0.1.21 | `595bf61` | 导出 OBJ 真缺面修复（面数上限提到 150 万、`add_face` 按本面顶点重编号、`min_area` 过滤）；背景改真实照片平面；第一视角改 depth / ghost / solid 三分支 |

想装旧版本，把 CDN 地址里的 `@v0.1.31` 换成对应 tag 即可。

## 十一、许可

- 本仓库的节点插件与 SketchUp 插件：AGPL-3.0（见 `LICENSE`）。
- 3D 导演台本体：MIT（见 `LICENSE-DIRECTOR.md`），上游参考自 `xiaozangao/3d-director-desk`。
- 节点插件形态参考 `esncy/infinite-canvas-director-plugin`。
- 导演台内置的人形/动作资源来自 Mixamo 与 Guo 3D Assets，商用前请自行确认对应模型许可。
