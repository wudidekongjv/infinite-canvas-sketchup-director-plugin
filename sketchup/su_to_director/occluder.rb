# encoding: UTF-8
require 'digest'

module SuToDirector
  # 把 SketchUp 几何体导出成 OBJ（米、Y 轴向上），供导演台当“深度遮挡体”使用。
  # 只写面片，不写材质、不写贴图——导演台里这一层只写深度、不写颜色。
  class OccluderExporter
    attr_reader :face_count, :vertex_count, :skipped

    def initialize(max_faces: 400_000, min_area: 0.0004)
      @max_faces = max_faces.to_i
      # 面积太小的小碎面（椅子上的小五金、贴面的双层面、装饰细条）挡不住人，
      # 却能把面数预算吃光——过滤掉它们，省下来的预算才能让课桌、柜子这些大件完整。
      @min_area = min_area.to_f
      @face_count = 0
      @vertex_count = 0
      @skipped = 0
      @lines = []
      @counters = { v: 0 }
      @limit_hit = false
    end

    def limit_hit?
      @limit_hit
    end

    # source_entities: 选中的 Selection，或 model.entities
    def build(source_entities, entities_provider)
      @lines << "# SU occluder export (meters, Y-up)"
      @lines << "o SU_OCCLUDER"
      walk(source_entities, IDENTITY_TRANSFORM, entities_provider)
      @lines.join("\n")
    end

    IDENTITY_TRANSFORM = Geom::Transformation.new

    private

    def walk(entities, transform, provider)
      return if @limit_hit
      entities.each do |entity|
        break if @limit_hit
        next unless entity.respond_to?(:valid?) && entity.valid?
        next if entity.respond_to?(:hidden?) && entity.hidden?
        if entity.respond_to?(:layer) && entity.layer && !entity.layer.visible?
          next
        end

        case entity
        when Sketchup::Group
          inner = entity.entities
          walk(inner, transform * entity.transformation, provider)
        when Sketchup::ComponentInstance
          inner = entity.definition.entities
          walk(inner, transform * entity.transformation, provider)
        when Sketchup::Face
          add_face(entity, transform)
        end
      end
    end

    def add_face(face, transform)
      return if face.respond_to?(:material) && face.material && face.material.alpha.to_f <= 0.01

      if @min_area > 0
        area_m2 = face.area.to_f * Coords::INCH * Coords::INCH
        return if area_m2 < @min_area
      end

      mesh = face.mesh(0)
      return if mesh.nil?

      polygons = mesh.polygons
      return if polygons.nil? || polygons.empty?

      # 只写"三角形真正用到的"顶点，并按用到的顺序重新编号。
      # 以前是先把外环顶点全写出去、再拿 mesh 原始索引去引 —— 带洞的面（窗、门、柜门）
      # 索引会越过本面写出去的顶点数，直接串到下一个面的顶点上，于是就成了跨面的大三角、
      # 破面、课桌不像课桌。
      local_index = {}
      points = []
      polygons.each do |polygon|
        polygon.each do |point_index|
          next if local_index.key?(point_index)
          point = mesh.point_at(point_index).transform(transform)
          points << point
          local_index[point_index] = points.length # 1-based，OBJ 的索引就这么写
        end
      end
      return if points.length < 3

      if @face_count + polygons.length > @max_faces
        @limit_hit = true
        return
      end

      base = @counters[:v]
      points.each do |pt|
        @lines << format('v %.5f %.5f %.5f', pt.x * Coords::INCH, pt.z * Coords::INCH, -pt.y * Coords::INCH)
      end
      @counters[:v] += points.length
      @vertex_count += points.length

      polygons.each do |polygon|
        idx = polygon.map { |point_index| base + local_index[point_index] }
        next if idx.length < 3
        @lines << "f #{idx.join(' ')}"
        @face_count += 1
      end
    rescue StandardError
      @skipped += 1
    end
  end

  module OccluderIO
    module_function

    # 返回 { path:, face_count:, bytes:, hash: } 或抛异常
    def export(model, out_dir, source: 'selection', max_faces: 400_000, min_area: 0.0004)
      exporter = OccluderExporter.new(max_faces: max_faces, min_area: min_area)
      target = if source == 'selection'
                 selected = model.selection
                 if selected.nil? || selected.empty?
                   raise '没有选中任何对象；请先选中要作为遮挡体的墙/楼板等，或切换到“整个可见模型”。'
                 end
                 selected
               else
                 model.entities
               end

      obj = exporter.build(target, model.entities)
      path = File.join(out_dir, 'occluders.obj')
      File.open(path, 'w:UTF-8') { |f| f.write(obj) }
      {
        path: path,
        face_count: exporter.face_count,
        bytes: File.size(path),
        hash: Digest::SHA1.file(path).hexdigest[0, 10],
        limit_hit: exporter.limit_hit?
      }
    end
  end
end
