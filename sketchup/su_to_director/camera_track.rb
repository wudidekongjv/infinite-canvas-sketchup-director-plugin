# encoding: UTF-8
module SuToDirector
  # SketchUp: 英寸、Z 轴向上、右手系
  # 导演台(three.js): 米、Y 轴向上、右手系
  # 转换 (x, y, z)_su -> (x, z, -y)_desk，单位 × 0.0254
  module Coords
    INCH = 0.0254

    module_function

    def to_desk_point(p)
      [p.x * INCH, p.z * INCH, -p.y * INCH]
    end

    def to_desk_vector(v)
      [v.x, v.z, -v.y]
    end
  end

  class CameraTrack
    # keys: [{ eye:, target:, up:, fov: }, ...]（SketchUp 坐标系，fov 为 SketchUp 原始值）
    # fov_axis: 'vertical' | 'horizontal' —— SketchUp 的 fov 作用在哪个方向
    def initialize(keys, easing: 'smooth', fov_axis: 'vertical', aspect: 16.0 / 9.0)
      @keys = keys || []
      @easing = easing == 'linear' ? 'linear' : 'smooth'
      @fov_axis = fov_axis == 'horizontal' ? 'horizontal' : 'vertical'
      @aspect = aspect.to_f
      @aspect = 16.0 / 9.0 if @aspect <= 0
    end

    attr_reader :fov_axis, :aspect

    def empty?
      @keys.empty?
    end

    def key_count
      @keys.length
    end

    # SketchUp fov -> three.js 的垂直 fov（度）
    def vertical_fov_deg(fov_deg)
      half = fov_deg.to_f * Math::PI / 180.0 / 2.0
      tan_v = @fov_axis == 'horizontal' ? Math.tan(half) / @aspect : Math.tan(half)
      2.0 * Math.atan(tan_v) * 180.0 / Math::PI
    end

    def sample_at(t)
      return nil if @keys.empty?
      t = [[t.to_f, 0.0].max, 1.0].min
      if @keys.length == 1
        key = @keys[0]
        return build_frame(key[:eye], key[:target], key[:up], key[:fov])
      end

      segments = @keys.length - 1
      pos = t * segments
      idx = pos.floor
      idx = segments - 1 if idx >= segments
      local = local_ease((pos - idx).to_f)
      a = @keys[idx]
      b = @keys[idx + 1]

      eye = lerp3(a[:eye], b[:eye], local)
      target = lerp3(a[:target], b[:target], local)
      up = lerp_vec(a[:up], b[:up], local)
      fov = a[:fov].to_f + (b[:fov].to_f - a[:fov].to_f) * local
      build_frame(eye, target, up, fov)
    end

    def frames(count)
      count = count.to_i
      count = 2 if count < 2
      (0...count).map { |i| sample_at(i.to_f / (count - 1).to_f) }
    end

    private

    def local_ease(t)
      return t if @easing == 'linear'
      t * t * (3.0 - 2.0 * t)
    end

    def build_frame(eye, target, up, fov)
      {
        desk: {
          position: Coords.to_desk_point(eye),
          target: Coords.to_desk_point(target),
          up: Coords.to_desk_vector(up),
          fov: vertical_fov_deg(fov)
        },
        su: {
          eye: eye,
          target: target,
          up: up,
          fov: fov.to_f
        }
      }
    end

    def lerp3(a, b, t)
      Geom::Point3d.new(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
    end

    def lerp_vec(a, b, t)
      v = Geom::Vector3d.new(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
      v.length < 1e-9 ? Geom::Vector3d.new(0, 0, 1) : v.normalize
    end
  end
end
