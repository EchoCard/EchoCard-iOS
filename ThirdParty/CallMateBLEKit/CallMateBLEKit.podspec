Pod::Spec.new do |s|
  s.name             = 'CallMateBLEKit'
  s.version          = '0.1.0'
  s.summary          = 'EchoCard BLE client library for iOS (prebuilt binary)'
  s.description      = 'Prebuilt CallMateBLEKit.xcframework — no source; download from this app repo’s public release.'
  s.homepage         = 'https://github.com/EchoCard/EchoCard-iOS'
  s.license          = { :type => 'Commercial' }
  s.author           = { 'EchoCard' => 'support@echocard.app' }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  # 公开：与本仓 GitHub Release `callmate-ble-0.1.0` 中的 zip 一致；与私有 BLE 源码仓无 Git 依赖
  s.source           = {
    :http => 'https://github.com/EchoCard/EchoCard-iOS/releases/download/callmate-ble-0.1.0/CallMateBLEKit.xcframework.zip',
    :sha256 => 'ea8bb59a994ea99642c588284f20e71518cdbc0c049a609c09e3aa065841c696'
  }
  s.vendored_frameworks = 'CallMateBLEKit.xcframework'
end
