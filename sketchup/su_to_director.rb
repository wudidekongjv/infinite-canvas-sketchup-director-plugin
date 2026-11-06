# encoding: UTF-8
# SU ⇄ 3D 导演台 同步插件（SketchUp 2023+）
# 作用：把 SketchUp 的机位轨道、遮挡几何体暴露给本地运行的 3D 导演台，
#       并把导演台渲染出的“角色可见层 / 合成帧”收回本地，最终合成视频。

require 'sketchup.rb'
require 'extensions.rb'

module SuToDirector
  PLUGIN_ROOT = File.dirname(__FILE__)
  PATH        = File.join(PLUGIN_ROOT, 'su_to_director.rb')

  unless file_loaded?(PATH)
    ex = SketchupExtension.new('SU ⇄ 3D 导演台', File.join(PLUGIN_ROOT, 'su_to_director', 'main.rb'))
    ex.version     = '0.1.0'
    ex.creator     = 'SuToDirector'
    ex.description = 'SketchUp 机位轨道 + 遮挡几何体 → 3D 导演台角色层 → 合成成片'
    Sketchup.register_extension(ex, true)
    file_loaded(PATH)
  end
end
