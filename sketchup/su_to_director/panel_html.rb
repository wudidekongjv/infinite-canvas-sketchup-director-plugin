# encoding: UTF-8
module SuToDirector
  PANEL_HTML = <<~HTML
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <title>SU ⇄ 3D 导演台</title>
      <style>
        :root { color-scheme: dark; }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 14px; font: 13px/1.5 "Microsoft YaHei", system-ui, sans-serif;
               background: #16181d; color: #e6e8ec; }
        h1 { font-size: 14px; margin: 0 0 4px; font-weight: 600; letter-spacing: .5px; }
        .sub { color: #8b93a1; font-size: 11px; margin-bottom: 12px; }
        .card { background: #1e2229; border: 1px solid #2a2f38; border-radius: 10px; padding: 10px 12px; margin-bottom: 10px; }
        .card h2 { font-size: 12px; margin: 0 0 8px; color: #b9c1cf; font-weight: 600; }
        .row { display: flex; gap: 8px; align-items: center; margin-bottom: 8px; }
        .row > * { flex: 1; }
        label { color: #96a0af; font-size: 11px; display: block; margin-bottom: 2px; }
        input, select { width: 100%; background: #12151a; color: #e6e8ec; border: 1px solid #333a45;
                        border-radius: 6px; padding: 5px 7px; font-size: 12px; }
        button { background: #2b6cff; border: 0; color: #fff; border-radius: 7px; padding: 7px 10px;
                 font-size: 12px; cursor: pointer; }
        button.ghost { background: #262c36; color: #cfd6e2; border: 1px solid #333a45; }
        button:disabled { opacity: .5; cursor: default; }
        .pill { display: inline-flex; align-items: center; gap: 6px; font-size: 11px; color: #96a0af; }
        .dot { width: 8px; height: 8px; border-radius: 50%; background: #47505d; }
        .dot.on { background: #35d07f; box-shadow: 0 0 8px #35d07f88; }
        .kv { display: flex; justify-content: space-between; font-size: 11.5px; color: #a9b2c0; padding: 2px 0; }
        .kv b { color: #e6e8ec; font-weight: 500; }
        pre { margin: 0; max-height: 120px; overflow: auto; font-size: 11px; color: #8892a0;
              white-space: pre-wrap; word-break: break-all; }
        .hint { font-size: 11px; color: #7d8794; margin-top: 6px; }
        code { background: #12151a; padding: 1px 5px; border-radius: 4px; color: #8ec7ff; }
      </style>
    </head>
    <body>
      <h1>SU ⇄ 3D 导演台 同步</h1>
      <div class="sub">机位轨道 + 遮挡几何体 → 导演台角色层 → 合成成片</div>

      <div class="card">
        <div class="row" style="margin-bottom:6px">
          <span class="pill"><span id="dot" class="dot"></span><span id="svc">同步服务未启动</span></span>
          <button class="ghost" id="btnToggleBridge" style="flex:0 0 96px">启动服务</button>
        </div>
        <div class="kv"><span>导演台连接地址</span><b id="deskUrl">http://127.0.0.1:37740/su/session</b></div>
        <div class="kv"><span>输出目录</span><b id="outDir" style="font-size:10.5px">—</b></div>
      </div>

      <div class="card">
        <h2>1. 机位轨道</h2>
        <div class="row">
          <button class="ghost" id="btnStart">记录起点机位</button>
          <button class="ghost" id="btnEnd">记录终点机位</button>
        </div>
        <div class="row">
          <div><label>时长(秒)</label><input id="duration" type="number" min="0.5" max="30" step="0.5" value="6"></div>
          <div><label>帧率</label><input id="fps" type="number" min="6" max="60" step="1" value="24"></div>
        </div>
        <div class="row">
          <div><label>宽</label><input id="width" type="number" min="320" step="16" value="1920"></div>
          <div><label>高</label><input id="height" type="number" min="240" step="16" value="1080"></div>
        </div>
        <div class="row">
          <div><label>FOV 轴</label>
            <select id="fovAxis">
              <option value="auto">自动校准（推荐）</option>
              <option value="vertical">垂直</option>
              <option value="horizontal">水平</option>
            </select>
          </div>
          <div><label>插值</label>
            <select id="easing">
              <option value="smooth">缓入缓出</option>
              <option value="linear">线性</option>
            </select>
          </div>
        </div>
        <button id="btnBuild" style="width:100%">生成机位轨道</button>
        <div class="kv" style="margin-top:8px"><span>轨道状态</span><b id="shotInfo">未生成</b></div>
      </div>

      <div class="card">
        <h2>2. 遮挡几何体（导演台里只挡不显示）</h2>
        <div class="row">
          <div><label>来源</label>
            <select id="occSource">
              <option value="selection">当前选中对象</option>
              <option value="visible">整个可见模型</option>
            </select>
          </div>
          <div><label>最大面数</label><input id="maxFaces" type="number" min="10000" step="10000" value="400000"></div>
        </div>
        <button id="btnOccluder" style="width:100%">导出遮挡模型 (OBJ)</button>
        <div class="kv" style="margin-top:8px"><span>遮挡体</span><b id="occInfo">未导出</b></div>
      </div>

      <div class="card">
        <h2>3. SketchUp 背景帧</h2>
        <div class="row">
          <button id="btnBg">渲染背景帧</button>
          <button class="ghost" id="btnStopBg" style="flex:0 0 80px">停止</button>
        </div>
        <div class="kv"><span>进度</span><b id="bgInfo">未开始</b></div>
        <div class="hint">渲染期间 SketchUp 会被占用；建议先把窗口拉成与画幅一致的比例。</div>
      </div>

      <div class="card">
        <h2>4. 导演台回传</h2>
        <div class="kv"><span>角色层帧</span><b id="layerCount">0</b></div>
        <div class="kv"><span>合成帧</span><b id="compositeCount">0</b></div>
        <div class="hint">在导演台面板点“连接 SU → 合成导出”，帧会写进 <code>layer/</code> 与 <code>composite/</code>。</div>
      </div>

      <div class="card">
        <h2>5. 合成视频</h2>
        <div class="row">
          <button id="btnVideo">合成 mp4（用 composite 序列）</button>
          <button class="ghost" id="btnOpenVideo" style="flex:0 0 104px">视频目录</button>
        </div>
        <div class="kv"><span>输出</span><b id="videoInfo" style="font-size:10.5px">—</b></div>
        <div class="hint">需要本机有 python + imageio-ffmpeg；编码在后台跑，日志里会显示结果。</div>
      </div>

      <div class="card">
        <h2>日志</h2>
        <pre id="log">—</pre>
      </div>

      <div class="row">
        <button class="ghost" id="btnOpenDir">打开输出目录</button>
      </div>

      <script>
        var status = {};
        function call(cmd, options) {
          return new Promise(function (resolve) {
            try {
              window.sketchup.command(JSON.stringify({ cmd: cmd, options: options || {} }), function (res) {
                try { resolve(JSON.parse(res)); } catch (e) { resolve(status); }
              });
            } catch (e) { resolve(status); }
          });
        }
        function $(id) { return document.getElementById(id); }

        function render(s) {
          status = s || {};
          var bridge = (s.bridge || {});
          $("dot").className = "dot" + (bridge.running ? " on" : "");
          $("svc").textContent = bridge.running ? ("同步服务运行中 · 端口 " + bridge.port) : "同步服务未启动";
          $("btnToggleBridge").textContent = bridge.running ? "停止服务" : "启动服务";
          $("deskUrl").textContent = s.deskUrl || "—";
          $("outDir").textContent = s.outDir || "—";
          $("videoInfo").textContent = s.outDir ? (s.outDir + "/video") : "—";

          var shot = s.shot;
          if (shot) {
            $("shotInfo").textContent = shot.frameCount + " 帧 / " + shot.fps + "fps / " +
              shot.duration + "s / " + shot.width + "x" + shot.height + " / FOV=" + shot.fovAxis;
            if (!window.__shotFilled) {
              $("duration").value = shot.duration;
              $("fps").value = shot.fps;
              $("width").value = shot.width;
              $("height").value = shot.height;
              $("fovAxis").value = shot.fovAxis;
              window.__shotFilled = true;
            }
          } else {
            $("shotInfo").textContent = (s.keys || []).length + " / 2 个机位";
          }
          if (s.occluder) {
            $("occInfo").textContent = s.occluder.faceCount + " 面 · " + (s.occluder.bytes / 1048576).toFixed(1) + " MB";
          }
          var bg = s.bg || {};
          $("bgInfo").textContent = bg.state === "rendering"
            ? ("渲染中 " + bg.done + " / " + bg.total)
            : (bg.state === "done" ? ("完成 " + bg.total + " 帧") : (bg.state || "未开始"));
          var received = s.received || {};
          $("layerCount").textContent = received.layer || 0;
          $("compositeCount").textContent = received.composite || 0;
          $("log").textContent = (s.messages || []).join("\\n") || "—";
        }

        function options() {
          return {
            duration: parseFloat($("duration").value),
            fps: parseInt($("fps").value, 10),
            width: parseInt($("width").value, 10),
            height: parseInt($("height").value, 10),
            fovAxis: $("fovAxis").value,
            easing: $("easing").value,
            source: $("occSource").value,
            maxFaces: parseInt($("maxFaces").value, 10)
          };
        }

        function bind(id, cmd, extra) {
          $(id).addEventListener("click", function () {
            call(cmd, Object.assign(options(), extra || {})).then(render);
          });
        }
        bind("btnStart", "record_start");
        bind("btnEnd", "record_end");
        bind("btnBuild", "build_shot");
        bind("btnOccluder", "export_occluders");
        bind("btnBg", "render_bg");
        bind("btnStopBg", "stop_bg");

        $("btnToggleBridge").addEventListener("click", function () {
          var cmd = (status.bridge && status.bridge.running) ? "stop_bridge" : "start_bridge";
          call(cmd, options()).then(render);
        });
        $("btnOpenDir").addEventListener("click", function () {
          call("open_out_dir").then(render);
        });
        $("btnVideo").addEventListener("click", function () {
          call("encode_video", { fps: parseInt($("fps").value, 10) }).then(render);
        });
        $("btnOpenVideo").addEventListener("click", function () {
          call("open_video_dir").then(render);
        });

        setInterval(function () { call("status").then(render); }, 1500);
        call("status").then(render);
      </script>
    </body>
    </html>
  HTML
end
