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

  # 预编译 xcframework：CocoaPods 会误把 SWIFT_INCLUDE_PATHS 指到空目录
  # PODS_CONFIGURATION_BUILD_DIR/CallMateBLEKit，导致 CallMate 模块里类型「丢失」
  # （无 shared、协议不可见）。应指向解包后的 XCFramework 中间体。
  %w[debug release].each do |cfg|
    xcpath = File.join(installer.sandbox.root, 'Target Support Files', 'Pods-CallMate', "Pods-CallMate.#{cfg}.xcconfig")
    next unless File.file?(xcpath)
    t = File.read(xcpath)
    t = t.gsub(
      'SWIFT_INCLUDE_PATHS = $(inherited) "${PODS_CONFIGURATION_BUILD_DIR}/CallMateBLEKit"',
      'SWIFT_INCLUDE_PATHS = $(inherited) "${PODS_XCFRAMEWORKS_BUILD_DIR}/CallMateBLEKit"',
    )
    # 解包后模拟器是 CallMateBLEKit-sim.a，真机是 CallMateBLEKit-ios.a；CocoaPods 会误写为始终 -l CallMateBLEKit-ios
    t = t.gsub(
      /OTHER_LDFLAGS = [^\n]*\n(?:OTHER_LDFLAGS\[sdk=[^\n]*\n)*/,
      <<~'XC'      
        OTHER_LDFLAGS = $(inherited) -ObjC -l"libopus"
        OTHER_LDFLAGS[sdk=iphonesimulator*] = $(inherited) "${PODS_XCFRAMEWORKS_BUILD_DIR}/CallMateBLEKit/CallMateBLEKit-sim.a"
        OTHER_LDFLAGS[sdk=iphoneos*] = $(inherited) "${PODS_XCFRAMEWORKS_BUILD_DIR}/CallMateBLEKit/CallMateBLEKit-ios.a"
      XC
    )
    File.write(xcpath, t)
  end
end
