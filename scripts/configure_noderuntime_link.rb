#!/usr/bin/env ruby
# frozen_string_literal: true

# configure_noderuntime_link.rb
# 将 nodejs-mobile (NodeMobile.framework) + Node 运行时资源注入 vbox.xcodeproj
# 仿照 configure_python_link.rb / configure_quarkproxy_link.rb 模式
#
# 用法: ruby scripts/configure_noderuntime_link.rb
#
# 注入内容:
#   1. NodeRunner.h/mm        → Libraries group + 编译源 (ObjC++ 桥接)
#   2. NodeRuntimeManager.swift → Services group + 编译源 (Swift 运行时管理)
#   3. NodeMobile.framework   → Frameworks + Embed Frameworks (CodeSignOnCopy)
#   4. FRAMEWORK_SEARCH_PATHS → $(SRCROOT)/vbox/Libraries/NodeMobile
#   5. Resources/noderuntime  → Copy Bundle Resources (folder reference，保留目录结构)
#
# 前置条件: vbox/Libraries/NodeMobile/NodeMobile.framework 已存在
#   (CI 中由 build-ipa.yml 的 "下载 NodeMobile" 步骤准备)

require 'xcodeproj'

puts '🟢 配置 NodeMobile.framework 链接...'

project_path = 'vbox.xcodeproj'
abort "❌ 未找到 #{project_path}" unless File.exist?(project_path)

project = Xcodeproj::Project.open(project_path)
app_target = project.targets.find { |t| t.name == 'vbox' }
abort '❌ 未找到 vbox target' unless app_target
puts "✅ 找到 target: #{app_target.name}"

# 递归查找 PBXGroup（短名匹配，避免 path 嵌套干扰）
def find_group_by_name(project, group_name)
  project.main_group.recursive_children.find do |c|
    c.respond_to?(:files) && (c.name == group_name || c.path == group_name)
  end
end

# 获取（或创建）NodeMobile group：优先 Libraries group 下，其次 main_group
def ensure_node_mobile_group(project)
  existing = find_group_by_name(project, 'NodeMobile')
  return existing if existing

  libraries_group = find_group_by_name(project, 'Libraries')
  if libraries_group
    grp = libraries_group.new_group('NodeMobile', 'NodeMobile')
    puts '✅ 创建 NodeMobile group (Libraries 下)'
  else
    grp = project.main_group.new_group('NodeMobile', 'NodeMobile')
    puts '✅ 创建 NodeMobile group (main group 下)'
  end
  grp
end

# 1) 编译源注入: NodeRunner.h/mm + NodeRuntimeManager.swift
source_phase = app_target.source_build_phase
node_group = ensure_node_mobile_group(project)
sources = {
  'NodeRunner.mm' => node_group,
  'NodeRunner.h' => node_group,
  'NodeRuntimeManager.swift' => find_group_by_name(project, 'Services'),
}
sources.each do |file_name, target_group|
  next if source_phase.files.any? { |f| f.file_ref&.path == file_name }
  abort "❌ 未找到 #{target_group} group" unless target_group

  file_ref = target_group.files.find { |f| f.path == file_name }
  unless file_ref
    file_ref = target_group.new_file(file_name)
    file_ref.path = file_name
    file_ref.source_tree = '<group>'
  end
  source_phase.add_file_reference(file_ref)
  puts "✅ 添加编译源: #{file_name} → #{target_group.path}"
end

# 2) NodeMobile.xcframework: 缺失则报错（CI 下载步骤负责准备）
framework_dir = 'vbox/Libraries/NodeMobile'
framework_path = File.join(framework_dir, 'NodeMobile.xcframework')
abort "❌ 未找到 #{framework_path}，请先运行 build-ipa.yml 的 NodeMobile 下载步骤" unless File.directory?(framework_path)
puts "✅ NodeMobile.xcframework: #{framework_path}"

# 3) PBXFileReference + Frameworks + Embed Frameworks
file_ref = project.files.find do |f|
  f.path == 'Libraries/NodeMobile/NodeMobile.xcframework' || f.path == 'NodeMobile.xcframework'
end
unless file_ref
  file_ref = project.main_group.new_file('Libraries/NodeMobile/NodeMobile.xcframework')
  file_ref.last_known_file_type = 'wrapper.xcframework'
  puts '✅ 添加 PBXFileReference: NodeMobile.xcframework'
end

frameworks_phase = app_target.frameworks_build_phase
unless frameworks_phase.files_references.include?(file_ref)
  frameworks_phase.add_file_reference(file_ref)
  puts '✅ 添加 NodeMobile.xcframework 到 Frameworks'
end

embed_phase = app_target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
if embed_phase
  unless embed_phase.files_references.include?(file_ref)
    build_file = embed_phase.add_file_reference(file_ref)
    build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
    puts '✅ 添加 NodeMobile.xcframework 到 Embed Frameworks'
  end
end

# 4) FRAMEWORK_SEARCH_PATHS
app_target.build_configurations.each do |config|
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] ||= []
  fw_paths = config.build_settings['FRAMEWORK_SEARCH_PATHS']
  fw_paths = [fw_paths] unless fw_paths.is_a?(Array)
  search = '$(SRCROOT)/vbox/Libraries/NodeMobile'
  fw_paths << search unless fw_paths.include?(search)
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = fw_paths
end
puts '✅ FRAMEWORK_SEARCH_PATHS += $(SRCROOT)/vbox/Libraries/NodeMobile'

# 5) noderuntime 资源 → Copy Bundle Resources (folder reference)
#    main.js / node-intl-polyfill.js / db.json / wexfnwconfig.json / bundles/kstore_index.js
#    打包后位于 App bundle 的 noderuntime/ 下，与 NodeRuntimeManager 读取路径一致
resources_phase = app_target.resources_build_phase
runtime_path = 'Resources/noderuntime'
runtime_file_ref = project.files.find { |f| f.path == runtime_path || f.path == 'vbox/Resources/noderuntime' }
unless runtime_file_ref
  runtime_file_ref = project.main_group.new_file(runtime_path)
  runtime_file_ref.last_known_file_type = 'folder'
  runtime_file_ref.path = runtime_path
  runtime_file_ref.source_tree = '<group>'
  runtime_file_ref.explicit_file_type = 'folder'
  puts '✅ 添加 noderuntime folder reference'
end
unless resources_phase.files_references.include?(runtime_file_ref)
  resources_phase.add_file_reference(runtime_file_ref)
  puts '✅ 添加 noderuntime 到 Copy Bundle Resources'
end

project.save
puts '🎉 NodeMobile.framework + noderuntime 资源集成完成！'
