# encoding: UTF-8
module SuToDirector
  DEFAULTS = {
    'port'            => 37_740,
    'fps'             => 24,
    'duration'        => 6.0,
    'width'           => 1920,
    'height'          => 1080,
    'aspect'          => 16.0 / 9.0,
    'fov_axis'        => 'auto',      # auto / vertical / horizontal
    'occluder_source' => 'selection', # selection / visible
    'max_faces'       => 400_000,
    'out_dir'         => ''           # 空则使用 <模型目录>/su_director_export
  }.freeze

  module Config
    module_function

    def path
      File.join(PLUGIN_ROOT, 'su_to_director', 'config.json')
    end

    def load
      data = {}
      if File.exist?(path)
        begin
          require 'json'
          data = JSON.parse(File.read(path, encoding: 'UTF-8')) || {}
        rescue StandardError
          data = {}
        end
      end
      DEFAULTS.merge(data)
    end

    def save(hash)
      require 'json'
      merged = DEFAULTS.merge(hash)
      File.open(path, 'w:UTF-8') { |f| f.write(JSON.pretty_generate(merged)) }
      merged
    end

    def get(key)
      load[key.to_s]
    end
  end
end
