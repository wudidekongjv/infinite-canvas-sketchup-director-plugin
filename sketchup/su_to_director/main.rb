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
      @preview = nil      # { path:, url:, width:, height:, at: } 当前视角那一张
      @scenes = []        # 场景（= 机位）缓存，只在主线程刷新
      @scene = ''
      @last_view = nil    # 最近一次读到的相机姿态
      @video = nil        # { size:, at: } 合成好的 mp4
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

    # ---------- 场景 = 机位 ----------
    # SketchUp 的场景本身就存着相机，所以机位列表直接取场景，不再单独"记录起点/终点"。
    def scenes
      model = Sketchup.active_model
      return [] unless model
      selected = model.pages.selected_page
      picked = selected ? selected.name.to_s : ''
      list = []
      model.pages.each_with_index do |page, index|
        list << { index: index, name: page.name.to_s, active: (page.name.to_s == picked) }
      end
      list
    rescue StandardError => e
      log("读取场景失败：#{e.message}")
      []
    end

    def refresh_scenes
      @scenes = scenes
      active = @scenes.find { |item| item[:active] }
      @scene = active ? active[:name].to_s : ''
    rescue StandardError
      nil
    end

    def inch_to_desk(value)
      [(value.x * Coords::INCH).round(4), (value.z * Coords::INCH).round(4), (-value.y * Coords::INCH).round(4)]
    end

    def desk_to_su_point(value)
      raise '机位数据不完整' unless value.is_a?(Array) && value.length >= 3
      Geom::Point3d.new(value[0].to_f / Coords::INCH, -value[2].to_f / Coords::INCH, value[1].to_f / Coords::INCH)
    end

    def current_view_hash
      view = Sketchup.active_model.active_view
      cam = view.camera
      {
        eye: inch_to_desk(cam.eye),
        target: inch_to_desk(cam.target),
        up: [cam.up.x.round(5), cam.up.z.round(5), (-cam.up.y).round(5)],
        fov: cam.fov.to_f.round(2),
        vp: { w: view.vpwidth.to_i, h: view.vpheight.to_i }
      }
    end

    # 切到某个场景：SU 相机跟着变，导演台再读 /su/status 就知道该摆哪了
    def apply_scene(params = {})
      pages = Sketchup.active_model.pages
      page = nil
      index = params['index']
      page = pages[index.to_i] if index && !index.to_s.empty?
      name = params['name'].to_s
      if page.nil? && !name.empty?
        pages.each { |item| page = item if item.name.to_s == name }
      end
      raise "没有找到场景：#{name.empty? ? index : name}" if page.nil?
      pages.selected_page = page
      refresh_scenes
      @last_view = current_view_hash
      log("机位已切到场景：#{page.name}")
      { ok: true }
    end

    # 导演台把它的相机发过来，让 SU 站在同一个视角（这样截图才对得上）
    def follow_camera(params = {})
      view = Sketchup.active_model.active_view
      eye = desk_to_su_point(params['eye'])
      target = desk_to_su_point(params['target'])
      up = if params['up'].is_a?(Array)
             point = desk_to_su_point(params['up'])
             Geom::Vector3d.new(point.x, point.y, point.z)
           else
             Geom::Vector3d.new(0, 0, 1)
           end
      up = Geom::Vector3d.new(0, 0, 1) if up.length < 1e-9
      cam = Sketchup::Camera.new(eye, target, up)
      fov = params['fov'].to_f
      cam.fov = fov if fov > 1.0 && fov < 179.0
      view.camera = cam
      @last_view = current_view_hash
      { ok: true }
    end

    def write_image_file(view, path, width, height)
      begin
        # SketchUp 2026 的 View#write_image 只接受一个 Hash 参数
        view.write_image({
          filename: path,
          width: width,
          height: height,
          antialias: true,
          compression: 0.9,
          transparent: false
        })
      rescue StandardError
        view.write_image(path, width, height, true, 0.9)
      end
      File.exist?(path) && File.size(path) > 0
    end

    # 一键：只截当前视角这一张。不循环、不批量，所以不会把界面占死。
    def shot_now(params = {})
      ensure_out_dir
      view = Sketchup.active_model.active_view
      vw = view.vpwidth.to_f
      vh = view.vpheight.to_f
      vw = 1280.0 if vw < 1.0
      vh = 720.0 if vh < 1.0
      max_w = (params['width'] || 1280).to_i
      max_w = 1280 if max_w <= 0 || max_w > 2400
      scale = [1.0, max_w / vw].min
      width = (vw * scale).round
      height = (vh * scale).round
      path = File.join(@out_dir, 'bg', 'preview.png')
      raise '当前视角截图失败' unless write_image_file(view, path, width, height)
      @preview = {
        path: path,
        url: "/su/bg/preview.png?v=#{Time.now.to_i}",
        width: width,
        height: height,
        at: Time.now.to_i
      }
      @bg_state = 'done'
      @bg_done = 1
      @bg_total = 1
      @last_view = current_view_hash
      log("已截取当前视角：#{width}x#{height}")
      status_hash
    rescue StandardError => e
      @bg_state = 'error'
      log("当前视角截图失败：#{e.message}")
      raise
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
      raw_up = cam.up
      up = Geom::Vector3d.new(raw_up.x.to_f, raw_up.y.to_f, raw_up.z.to_f)
      up = Geom::Vector3d.new(0, 0, 1) if up.length < 1e-9
      up.normalize!

      # 只做纯数值运算，不依赖 SketchUp 的向量运算符重载
      step = distance * Math.tan(half)
      target = cam.target
      probe = Geom::Point3d.new(
        target.x + up.x * step,
        target.y + up.y * step,
        target.z + up.z * step
      )
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

    # 一键传模型：有选中就传选中，没选中就传整个可见模型，不再让用户选参数
    def export_model(params = {})
      source = params['source'].to_s
      if source.empty?
        source = Sketchup.active_model.selection.empty? ? 'visible' : 'selection'
      end
      # 没选中就传整个可见模型。上限压在 20 万面：整个教室 60 万面会导成 48MB，
      # 导演台解析会明显变慢；遮挡只要墙和家具的轮廓，20 万面够用。
      export_occluders('source' => source, 'maxFaces' => (params['maxFaces'] || 200_000))
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
      # 旧实现用 UI.start_timer 逐帧写 145 张 1920×1080，全部跑在主线程里，
      # 界面直接被占死（这就是"SketchUp 无响应"的真因）。现在只截一张。
      shot_now(params)
    rescue StandardError
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
      refresh_scenes
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

    # 面板（走 HTTP）与 Extension 菜单（走 Ruby）共用的命令分发
    def run_command(data)
      data = {} unless data.is_a?(Hash)
      cmd = data['cmd'].to_s
      opts = data['options'].is_a?(Hash) ? data['options'] : {}
      case cmd
      when 'list_scenes' then refresh_scenes
      when 'apply_scene', 'goto_scene' then apply_scene(opts)
      when 'follow_camera' then follow_camera(opts)
      when 'shot_now', 'shot_once', 'shot' then shot_now(opts)
      when 'export_model' then export_model(opts)
      when 'record_start' then record_view('start')
      when 'record_end' then record_view('end')
      when 'build_shot' then build_shot(opts)
      when 'export_occluders' then export_occluders(opts)
      when 'render_bg' then render_background(opts)
      when 'stop_bg' then stop_background
      when 'start_bridge' then start_bridge(opts['port'])
      when 'stop_bridge' then stop_bridge
      when 'encode_video' then encode_video(opts['fps'])
      when 'open_out_dir'
        dir = ensure_out_dir
        SuToDirector.open_folder(dir) if dir
      when 'open_video_dir'
        dir = video_dir
        SuToDirector.open_folder(dir) if dir
      when 'status', '' then nil
      end
      nil
    rescue StandardError => e
      log("命令失败：#{e.message}")
      nil
    end

    def video_dir
      dir = ensure_out_dir
      return nil unless dir
      sub = File.join(dir, 'video')
      FileUtils.mkdir_p(sub)
      sub
    end

    def latest_video_path
      dir = video_dir
      return nil unless dir
      # 不用 Dir.glob：Ruby 的 glob 在中文路径上会返回空，这里直接列目录
      names = Dir.entries(dir) rescue []
      files = names.select { |name| name.to_s.downcase.end_with?('.mp4') }
                   .map { |name| File.join(dir, name) }
                   .select { |path| File.exist?(path) }
      files.sort_by { |path| File.mtime(path) }.last
    rescue StandardError
      nil
    end

    # ---------- 视频编码 ----------
    # 不依赖 python：直接找 ffmpeg 可执行文件（插件自带 tools/ffmpeg.exe 优先）
    def find_ffmpeg
      list = []
      list << ENV['SU_DIRECTOR_FFMPEG']
      list << File.join(__dir__, 'tools', 'ffmpeg.exe')
      list << File.join(__dir__, 'tools', 'ffmpeg')
      (ENV['PATH'] || '').split(File::PATH_SEPARATOR).each do |dir|
        list << File.join(dir, 'ffmpeg.exe')
        list << File.join(dir, 'ffmpeg')
      end
      list.compact.find { |item| File.file?(item.to_s) }
    rescue StandardError
      nil
    end

    def encode_video(fps = nil)
      dir = ensure_out_dir
      raise '还没有输出目录，请先回传一次帧' unless dir
      fps = (fps || (@shot && @shot[:fps]) || config['fps']).to_i
      ffmpeg = find_ffmpeg
      raise '找不到 ffmpeg：把 ffmpeg.exe 放到插件目录 su_to_director/tools/ 下即可' unless ffmpeg

      # 优先用导演台合成好的 composite（人物 + SU 背景已经叠好）；
      # 这里用 File.exist? 而不是 Dir.glob —— Ruby 的 glob 在中文路径上会返回空。
      composite_first = File.join(dir, 'composite', 'composite_00000.png')
      if File.exist?(composite_first)
        pattern = 'composite'
        first = composite_first
      else
        pattern = 'layer'
        first = File.join(dir, 'layer', 'layer_00000.png')
        raise '还没有收到导演台回传的帧' unless File.exist?(first)
      end
      input = File.join(dir, pattern, "#{pattern}_%05d.png")
      stamp = Time.now.strftime('%Y%m%d_%H%M%S')
      out = File.join(dir, 'video', "#{pattern}_#{fps}fps_#{stamp}.mp4")
      FileUtils.mkdir_p(File.dirname(out))

      # 注意：SU 截图的视口高度常常是奇数（比如 671），yuv420p 要求宽高都是偶数，
      # 所以必须先 scale 到偶数，否则 libx264 会直接报 "Could not open encoder before EOF"。
      args = [ffmpeg, '-y', '-framerate', fps.to_s, '-start_number', '0', '-i', input,
              '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
              '-c:v', 'libx264', '-preset', 'medium', '-crf', '18',
              '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out].map(&:to_s)

      log("开始合成视频（#{pattern}，后台跑 ffmpeg）……")
      begin
        pid = Process.spawn(*args, in: File::NULL, out: File::NULL, err: File::NULL)
        ticker = ::UI.start_timer(0.5, true) do
          begin
            finished = Process.waitpid(pid, Process::WNOHANG)
            next unless finished
            ::UI.stop_timer(ticker)
            if File.exist?(out) && File.size(out).to_i > 0
              @video = { path: out, size: File.size(out), at: Time.now.strftime('%H:%M:%S') }
              log("视频已输出：#{File.basename(out)}")
            else
              log('视频编码失败：ffmpeg 没有产出文件')
            end
          rescue Errno::ECHILD
            ::UI.stop_timer(ticker)
          rescue StandardError => e
            ::UI.stop_timer(ticker)
            log("视频编码失败：#{e.message}")
          end
        end
      rescue StandardError => e
        # 退一步：同步跑（少数环境 Process.spawn 不可用）
        log("后台启动失败，改为前台编码：#{e.message}")
        ok = system(*args)
        if ok && File.exist?(out)
          @video = { path: out, size: File.size(out), at: Time.now.strftime('%H:%M:%S') }
          log("视频已输出：#{File.basename(out)}")
        else
          log('视频编码失败：ffmpeg 返回非 0')
        end
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
      when '/su/command'
        begin
          data = JSON.parse(body.to_s)
        rescue StandardError
          data = {}
        end
        run_command(data)
        [200, 'application/json; charset=utf-8', JSON.generate(status_hash)]
      when '/su/occluders.obj'
        path_obj = @occluder && @occluder[:path]
        if path_obj && File.exist?(path_obj)
          [200, 'text/plain; charset=utf-8', File.binread(path_obj)]
        else
          [404, 'text/plain; charset=utf-8', 'no occluder']
        end
      when '/su/scenes'
        [200, 'application/json; charset=utf-8', JSON.generate({ ok: true, scenes: @scenes })]
      when '/su/video.mp4'
        file = latest_video_path
        if file && File.exist?(file)
          [200, 'video/mp4', File.binread(file)]
        else
          [404, 'text/plain; charset=utf-8', 'no video']
        end
      when %r{^/su/bg/([A-Za-z0-9_]+)\.png$}
        # 白名单：preview（当前视角那一张）或 bg_00001 这种逐帧图，防路径穿越
        name = Regexp.last_match(1)
        file = nil
        if name == 'preview'
          file = @preview && @preview[:path]
        elsif name.start_with?('bg_')
          index = name[3..-1].to_i
          file = @out_dir && File.join(@out_dir, 'bg', format('bg_%05d.png', index))
        end
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
        scenes: @scenes,
        scene: @scene,
        view: @last_view,
        shot: @shot,
        keys: key_summary,
        occluder: @occluder ? { faceCount: @occluder[:face_count], bytes: @occluder[:bytes], hash: @occluder[:hash] } : nil,
        bg: {
          state: @bg_state,
          done: @bg_done,
          total: @bg_total,
          url: @preview ? @preview[:url] : nil,
          width: @preview ? @preview[:width] : nil,
          height: @preview ? @preview[:height] : nil
        },
        video: video_status,
        received: @received,
        outDir: @out_dir,
        messages: messages,
        deskUrl: "http://127.0.0.1:#{bridge_port}/su/session"
      }
    end

    def video_status
      file = (@video && @video[:path]) || latest_video_path
      return nil unless file && File.exist?(file)
      { url: '/su/video.mp4', size: File.size(file), at: File.mtime(file).to_i }
    rescue StandardError
      nil
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
    # 面板与 Ruby 的通信走 37740 上的 HTTP 接口（SketchUp 2026 的 HtmlDialog
    # JS 桥实测不可用），所以打开面板时先把服务拉起来。
    begin
      SESSION.start_bridge
    rescue StandardError => e
      SESSION.log("同步服务启动失败：#{e.message}")
    end
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
      rescue StandardError
        data = {}
      end
      SESSION.run_command(data)
      payload_json = JSON.generate(SESSION.status_hash)
      # SketchUp 2026 的 HtmlDialog JS 桥实测不可用，面板主要走 37740 的 HTTP 接口；
      # 这里尽量推一次状态，推不动就静默。
      begin
        @dialog.execute_script("window.__su && window.__su(#{payload_json})") if @dialog
      rescue StandardError
        nil
      end
      payload_json
    end

    @dialog.show
  end

  def self.build_menu
    menu = UI.menu('Plugins')
    sub = menu.add_submenu('SU ⇄ 3D 导演台')
    sub.add_item('打开同步面板') { open_panel }
    sub.add_separator
    sub.add_item('截取当前视角（一张）') { SESSION.run_command('cmd' => 'shot_now') }
    sub.add_item('一键导出遮挡模型') { SESSION.run_command('cmd' => 'export_model') }
    sub.add_separator
    sub.add_item('启动同步服务') { SESSION.start_bridge }
    sub.add_item('停止同步服务') { SESSION.stop_bridge }
    sub.add_item('合成 mp4') { SESSION.encode_video }
  end

  unless file_loaded?(__FILE__)
    build_menu
    # 扩展一加载就把同步服务点起来：导演台面板打开就能连上，不用再点菜单
    ::UI.start_timer(2.5, false) do
      begin
        SESSION.start_bridge
      rescue StandardError => error
        puts "SU ⇄ 导演台：自动启动同步服务失败：#{error.message}"
      end
    end
    file_loaded(__FILE__)
  end
end
