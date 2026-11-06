# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require 'fileutils'
require_relative 'config'
require_relative 'camera_track'
require_relative 'occluder'
require_relative 'bridge'

module SuToDirector
  SUB_DIRS = %w[bg layer composite video].freeze

  class SyncSession
    attr_reader :out_dir

    def initialize
      @lock = Mutex.new
      @keys = []          # [{ eye:, target:, up:, fov: }, ...]
      @track = nil
      @frames = []        # [{ desk: {...}, su: {...} }, ...]
      @shot = nil         # { fps:, frameCount:, duration:, width:, height: }
      @occluder = nil     # { path:, face_count:, bytes:, hash: }
      @bg_state = 'idle'  # idle / rendering / done
      @bg_done = 0
      @bg_total = 0
      @received = Hash.new(0)
      @bridge = nil
      @out_dir = nil
      @messages = []
      @timer = nil
      @restore_camera = nil
      @model_path = ''
      @model_title = ''
    end

    # HTTP 线程里绝对不能碰 SketchUp API，模型信息在这里先缓存好
    def sync_model_info
      model = Sketchup.active_model
      return unless model
      @model_path = model.path.to_s
      @model_title = model.title.to_s
    rescue StandardError
      nil
    end

    # ---------- 基础 ----------
    def log(text)
      @messages << "#{Time.now.strftime('%H:%M:%S')} #{text}"
      @messages.shift while @messages.length > 12
      puts "[SuToDirector] #{text}"
    end

    def messages
      @messages.dup
    end

    def config
      SuToDirector::Config.load
    end

    def ensure_out_dir
      return @out_dir if @out_dir && File.directory?(@out_dir)
      cfg_dir = config['out_dir'].to_s
      base = if !cfg_dir.empty?
               cfg_dir
             else
               model_path = @model_path.to_s
               if model_path.empty?
                 File.join(Dir.home, 'su_director_export')
               else
                 File.join(File.dirname(model_path), 'su_director_export')
               end
             end
      FileUtils.mkdir_p(base)
      SUB_DIRS.each { |sub| FileUtils.mkdir_p(File.join(base, sub)) }
      @out_dir = base
      base
    rescue StandardError => e
      log("创建输出目录失败：#{e.message}")
      nil
    end

    def out_path(*parts)
      dir = ensure_out_dir
      return nil unless dir
      File.join(dir, *parts)
    end

    # ---------- 机位 ----------
    def record_view(slot)
      sync_model_info
      view = Sketchup.active_model.active_view
      cam = view.camera
      key = {
        eye: cam.eye,
        target: cam.target,
        up: cam.up,
        fov: cam.fov.to_f
      }
      case slot
      when 'start'
        @keys[0] = key
        log('已记录起点机位')
      when 'end'
        @keys[1] = key
        log('已记录终点机位')
      end
      @track = nil
      @frames = []
      status_hash
    end

    def key_summary
      @keys.each_with_index.map do |key, index|
        next nil if key.nil?
        label = index.zero? ? '起点' : '终点'
        {
          slot: index.zero? ? 'start' : 'end',
          label: label,
          eye: SuToDirector::Coords.to_desk_point(key[:eye]).map { |v| v.round(3) },
          fov: key[:fov].round(2)
        }
      end.compact
    end

    def calibrate_fov_axis
      view = Sketchup.active_model.active_view
      cam = view.camera
      vw = view.respond_to?(:vpwidth) ? view.vpwidth.to_f : 0.0
      vh = view.respond_to?(:vpheight) ? view.vpheight.to_f : 0.0
      return 'vertical' if vw < 1.0 || vh < 1.0

      aspect = vw / vh
      half = cam.fov.to_f * Math::PI / 180.0 / 2.0
      distance = cam.eye.distance(cam.target)
      distance = 1.0 if distance < 1e-6
      up = cam.up
      up = Geom::Vector3d.new(0, 0, 1) if up.length < 1e-9
      up = up.normalize

      probe = cam.target + up * (distance * Math.tan(half))
      point = view.screen_coords(probe)
      y_norm = point.y.to_f / vh

      vertical_hits = [0.0, 1.0]
      horizontal_hits = [0.5 - 1.0 / (2.0 * aspect), 0.5 + 1.0 / (2.0 * aspect)]
      dv = vertical_hits.map { |value| (y_norm - value).abs }.min
      dh = horizontal_hits.map { |value| (y_norm - value).abs }.min

      dv <= dh ? 'vertical' : 'horizontal'
    rescue StandardError => e
      log("FOV 轴校准失败，按垂直处理：#{e.message}")
      'vertical'
    end

    def build_shot(params = {})
      width = (params['width'] || config['width']).to_i
      height = (params['height'] || config['height']).to_i
      fps = (params['fps'] || config['fps']).to_i
      duration = (params['duration'] || config['duration']).to_f
      easing = params['easing'] || 'smooth'
      axis = params['fovAxis'] || config['fov_axis'].to_s
      axis = calibrate_fov_axis if axis == 'auto' || axis.empty?
      axis = axis == 'horizontal' ? 'horizontal' : 'vertical'

      width = 1920 if width <= 0
      height = 1080 if height <= 0
      fps = 24 if fps <= 0 || fps > 60
      duration = 6.0 if duration <= 0.1 || duration > 30.0

      start_key = @keys[0]
      end_key = @keys[1]
      if start_key.nil? || end_key.nil?
        raise '请先记录“起点机位”和“终点机位”'
      end
      keys = [start_key, end_key]

      aspect = width.to_f / height.to_f
      @track = SuToDirector::CameraTrack.new(keys, easing: easing, fov_axis: axis, aspect: aspect)
      frame_count = (duration * fps).round + 1
      @shot = {
        fps: fps,
        frameCount: frame_count,
        duration: duration,
        width: width,
        height: height,
        aspect: aspect,
        fovAxis: axis,
        easing: easing
      }
      @frames = @track.frames(frame_count)
      SuToDirector::Config.save(config.merge('fov_axis' => axis, 'fps' => fps,
                                             'duration' => duration, 'width' => width,
                                             'height' => height))
      log("机位轨道已生成：#{frame_count} 帧 / #{fps}fps / #{duration}s / #{width}x#{height} / FOV轴=#{axis}")
      status_hash
    end

    # ---------- 遮挡体 ----------
    def export_occluders(params = {})
      source = params['source'] || config['occluder_source']
      max_faces = (params['maxFaces'] || config['max_faces']).to_i
      ensure_out_dir
      info = SuToDirector::OccluderIO.export(Sketchup.active_model, @out_dir,
                                             source: source, max_faces: max_faces)
      @occluder = info
      log("遮挡体已导出：#{info[:face_count]} 面 / #{(info[:bytes] / 1024.0 / 1024.0).round(1)}MB")
      status_hash
    end

    # ---------- 背景帧 ----------
    def actual_background_color
      style = Sketchup.active_model.styles.selected_style
      color = style.respond_to?(:background_color) ? style.background_color : nil
      color ? color.to_a[0, 3] : [255, 255, 255]
    rescue StandardError
      [255, 255, 255]
    end

    def render_background(params = {})
      build_shot(params) unless params.nil? || params.empty?
      raise '请先生成机位轨道' if @frames.empty?

      ensure_out_dir
      Dir.glob(File.join(@out_dir, 'bg', '*.png')).each { |f| File.delete(f) rescue nil }
      @bg_done = 0
      @bg_total = @frames.length
      @bg_state = 'rendering'

      model = Sketchup.active_model
      view = model.active_view
      @restore_camera = view.camera

      @timer = UI.start_timer(0.12, true) do
        begin
          if @bg_done >= @bg_total
            UI.stop_timer(@timer) if @timer
            @timer = nil
            @bg_state = 'done'
            view.camera = @restore_camera if @restore_camera
            log("背景帧渲染完成：#{@bg_total} 帧 → #{File.join(@out_dir, 'bg')}")
          else
            index = @bg_done
            frame = @frames[index]
            camera = Sketchup::Camera.new(frame[:su][:eye], frame[:su][:target], frame[:su][:up])
            camera.fov = frame[:su][:fov]
            view.camera = camera
            path = File.join(@out_dir, 'bg', format('bg_%05d.png', index))
            view.write_image(path, @shot[:width], @shot[:height], true, false, 0.9)
            @bg_done += 1
          end
        rescue StandardError => e
          UI.stop_timer(@timer) if @timer
          @timer = nil
          @bg_state = 'error'
          log("背景帧渲染失败（第 #{@bg_done} 帧）：#{e.message}")
        end
      end
      log('开始渲染背景帧，期间 SketchUp 会被占用，可随时点“停止”')
      status_hash
    end

    def stop_background
      if @timer
        UI.stop_timer(@timer)
        @timer = nil
      end
      if @bg_state == 'rendering' && @restore_camera
        Sketchup.active_model.active_view.camera = @restore_camera
      end
      @bg_state = 'stopped' if @bg_state == 'rendering'
      log('已停止背景帧渲染')
      status_hash
    end

    # ---------- 服务 ----------
    def start_bridge(port = nil)
      sync_model_info
      port = (port || config['port']).to_i
      if @bridge && @bridge.running?
        return status_hash
      end
      @bridge = SuToDirector::HttpBridge.new(port) { |method, path, query, _headers, body| handle_request(method, path, query, body) }
      @bridge.start
      log("同步服务已启动：http://127.0.0.1:#{port}/su/session")
      status_hash
    rescue StandardError => e
      @bridge = nil
      log("同步服务启动失败：#{e.message}")
      status_hash
    end

    def stop_bridge
      @bridge.stop if @bridge
      @bridge = nil
      log('同步服务已停止')
      status_hash
    end

    def video_dir
      dir = ensure_out_dir
      return nil unless dir
      sub = File.join(dir, 'video')
      FileUtils.mkdir_p(sub)
      sub
    end

    # ---------- 视频编码 ----------
    def encode_video(fps = nil)
      dir = ensure_out_dir
      raise '还没有输出目录，请先回传一次帧' unless dir
      fps = (fps || (@shot && @shot[:fps]) || config['fps']).to_i
      script = File.join(__dir__, 'tools', 'encode_video.py')
      raise "缺少编码脚本：#{script}" unless File.exist?(script)

      python = ENV['SU_TO_DIRECTOR_PYTHON'] || 'python'
      cmd = %("#{python}" "#{script}" --dir "#{dir}" --fps #{fps})
      log('开始合成视频（后台跑 ffmpeg，几秒到几十秒）……')
      Thread.new do
        ok = system(cmd)
        log(ok ? "视频已输出到 #{File.join(dir, 'video')}" : '视频编码失败：请确认 python 与 imageio-ffmpeg 可用')
      end
      status_hash
    end

    def bridge_running?
      @bridge ? @bridge.running? : false
    end

    def bridge_port
      @bridge ? @bridge.port : config['port'].to_i
    end

    # ---------- HTTP 路由 ----------
    def handle_request(method, path, query, body)
      case path
      when '/su/ping'
        [200, 'application/json; charset=utf-8', '{"ok":true,"app":"su_to_director"}']
      when '/su/session'
        [200, 'application/json; charset=utf-8', JSON.generate(session_payload)]
      when '/su/status'
        [200, 'application/json; charset=utf-8', JSON.generate(status_hash)]
      when '/su/occluders.obj'
        path_obj = @occluder && @occluder[:path]
        if path_obj && File.exist?(path_obj)
          [200, 'text/plain; charset=utf-8', File.binread(path_obj)]
        else
          [404, 'text/plain; charset=utf-8', 'no occluder']
        end
      when %r{^/su/bg/(\d+)\.png$}
        index = Regexp.last_match(1).to_i
        file = @out_dir && File.join(@out_dir, 'bg', format('bg_%05d.png', index))
        if file && File.exist?(file)
          [200, 'image/png', File.binread(file)]
        else
          [404, 'text/plain; charset=utf-8', 'no frame']
        end
      when '/su/frame'
        kind = (query['kind'] || 'layer').to_s
        index = (query['index'] || '0').to_i
        kind = 'layer' unless %w[layer composite].include?(kind)
        dir = out_path(kind) || out_path('layer')
        file = File.join(dir, format("#{kind}_%05d.png", index))
        File.binwrite(file, body.to_s)
        @received[kind] = @received[kind] + 1
        [200, 'application/json; charset=utf-8', %({"ok":true,"index":#{index}}) ]
      when '/su/done'
        log("导演台已回传：layer #{@received['layer']} 帧 / composite #{@received['composite']} 帧")
        [200, 'application/json; charset=utf-8', JSON.generate({ ok: true, received: @received })]
      else
        [404, 'text/plain; charset=utf-8', 'not found']
      end
    rescue StandardError => e
      [500, 'application/json; charset=utf-8', JSON.generate({ ok: false, error: e.message })]
    end

    def session_payload
      ensure_out_dir
      {
        ok: true,
        app: 'su_to_director',
        version: '0.1.0',
        project: { name: @model_title.to_s, path: @model_path.to_s },
        shot: @shot,
        camera: @frames.map { |f| f[:desk] },
        occluders: @occluder ? {
          url: '/su/occluders.obj',
          hash: @occluder[:hash],
          faceCount: @occluder[:face_count],
          bytes: @occluder[:bytes]
        } : nil,
        bg: {
          ready: @bg_state == 'done',
          state: @bg_state,
          count: @bg_total,
          done: @bg_done,
          urlTemplate: '/su/bg/{index}.png'
        },
        outDir: @out_dir
      }
    end

    def status_hash
      {
        ok: true,
        bridge: { running: bridge_running?, port: bridge_port },
        shot: @shot,
        keys: key_summary,
        occluder: @occluder ? { faceCount: @occluder[:face_count], bytes: @occluder[:bytes], hash: @occluder[:hash] } : nil,
        bg: { state: @bg_state, done: @bg_done, total: @bg_total },
        received: @received,
        outDir: @out_dir,
        messages: messages,
        deskUrl: "http://127.0.0.1:#{bridge_port}/su/session"
      }
    end
  end

  SESSION = SyncSession.new

  # ---------------- 面板 ----------------
  def self.open_folder(dir)
    return if dir.nil? || dir.to_s.empty?
    path = dir.to_s
    url = if Sketchup.platform == :platform_win
            "file:///#{path.tr('\\', '/')}"
          else
            "file://#{path}"
          end
    UI.openURL(url)
  rescue StandardError => e
    SESSION.log("打开目录失败：#{e.message}")
  end

  def self.panel_html
    require_relative 'panel_html'
    SuToDirector::PANEL_HTML
  end

  def self.open_panel
    if @dialog && @dialog.visible?
      @dialog.bring_to_front
      return
    end
    @dialog = UI::HtmlDialog.new(
      dialog_title: 'SU ⇄ 3D 导演台 同步',
      preferences_key: 'su_to_director_panel',
      width: 460,
      height: 680,
      resizable: true,
      style: UI::HtmlDialog::STYLE_DIALOG
    )
    @dialog.set_html(panel_html)

    @dialog.add_action_callback('command') do |_context, payload|
      begin
        data = JSON.parse(payload.to_s)
        cmd = data['cmd'].to_s
        case cmd
        when 'record_start' then SESSION.record_view('start')
        when 'record_end' then SESSION.record_view('end')
        when 'build_shot' then SESSION.build_shot(data['options'] || {})
        when 'export_occluders' then SESSION.export_occluders(data['options'] || {})
        when 'render_bg' then SESSION.render_background(data['options'] || {})
        when 'stop_bg' then SESSION.stop_background
        when 'start_bridge' then SESSION.start_bridge((data['options'] || {})['port'])
        when 'stop_bridge' then SESSION.stop_bridge
        when 'encode_video' then SESSION.encode_video((data['options'] || {})['fps'])
        when 'open_out_dir'
          dir = SESSION.ensure_out_dir
          SuToDirector.open_folder(dir) if dir
        when 'open_video_dir'
          dir = SESSION.video_dir
          SuToDirector.open_folder(dir) if dir
        end
      rescue StandardError => e
        SESSION.log("命令失败：#{e.message}")
      end
      JSON.generate(SESSION.status_hash)
    end

    @dialog.show
  end

  def self.build_menu
    menu = UI.menu('Plugins')
    sub = menu.add_submenu('SU ⇄ 3D 导演台')
    sub.add_item('打开同步面板') { open_panel }
    sub.add_separator
    sub.add_item('记录起点机位') { SESSION.record_view('start') }
    sub.add_item('记录终点机位') { SESSION.record_view('end') }
    sub.add_item('生成机位轨道') { SESSION.build_shot }
    sub.add_separator
    sub.add_item('导出遮挡模型(选中)') { SESSION.export_occluders('source' => 'selection') }
    sub.add_item('渲染背景帧') { SESSION.render_background }
    sub.add_separator
    sub.add_item('启动同步服务') { SESSION.start_bridge }
    sub.add_item('停止同步服务') { SESSION.stop_bridge }
    sub.add_item('合成 mp4') { SESSION.encode_video }
  end

  unless file_loaded?(__FILE__)
    build_menu
    file_loaded(__FILE__)
  end
end
