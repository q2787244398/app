platform :ios, '16.0'

target 'vbox' do
  use_frameworks!

  # VLC 兼容播放内核，用于 MKV / HEVC / 10bit / HDR / 多音轨等系统播放器不稳定的资源
  # 默认使用 3.7.3 稳定版；CI 可通过 MOBILE_VLC_KIT_URL 覆盖下载地址
  # （videolan.org 官方源在部分 CI 网络不可达，默认走 GitHub 镜像 Release
  #   https://github.com/hf805864818/MobileVLCKit，包内含 podspec + 根目录 xcframework，
  #   也支持指向任意镜像/仓库内离线 tar）
  vlc_kit_url = ENV['MOBILE_VLC_KIT_URL']
  if vlc_kit_url && !vlc_kit_url.empty?
    pod 'MobileVLCKit', :http => vlc_kit_url
  else
    pod 'MobileVLCKit', :http => 'https://github.com/hf805864818/MobileVLCKit/releases/download/3.7.3/MobileVLCKit-3.7.3.tar.xz'
  end

  # MDK 播放内核（wang-bin 开源），支持帧回调画中画
  # 用于复杂封装/特殊格式，作为兼容内核首选（PiP: 帧桥接）
  # swift-mdk 是 MDK 的 Swift 封装，提供 swift_mdk 模块
  pod 'swift-mdk'

  # SQLite ORM（数据库层）
  pod 'GRDB.swift'

  # HTML/XML 解析（搜索结果抓取）
  pod 'Kanna'

end
