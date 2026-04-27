platform :ios, '15.0'
workspace 'EchoCard.xcworkspace'

target 'CallMate' do
  # 本仓内 podspec 仅 :http 拉本 repo 的公开 Release 里的 xcframework
  pod 'CallMateBLEKit', :podspec => 'ThirdParty/CallMateBLEKit/CallMateBLEKit.podspec'
  pod 'libopus'
end

post_install do |installer|
  deployment_target = '15.0'

  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = deployment_target
    end
  end

  # libopus: silk/debug.c compiles to an empty TU when SILK_TIC_TOC=0 and SILK_DEBUG=0
  # (defaults in silk/debug.h on Apple platforms), producing debug.o with no symbols and
  # linker noise ("'debug.o' has no symbols"). The file provides only optional profiling
  # / debug storage — safe to omit from the pod target.
  installer.pods_project.targets.each do |target|
    next unless target.name == 'libopus'

    target.source_build_phase.files.each do |build_file|
      path = build_file.file_ref&.path
      next unless path&.end_with?('debug.c') && path.include?('silk')

      build_file.remove_from_project
    end
  end
end
