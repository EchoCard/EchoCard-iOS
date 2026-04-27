# CallMateBLEKit (预编译)

`Podfile` 通过同目录的 `CallMateBLEKit.podspec` 用 **HTTP** 拉取 `CallMateBLEKit.xcframework`。**不包含**、也**不引用**任何 BLE 源码仓。

在首次 `pod install` 前，需要在本应用仓库的 **GitHub Releases** 中创建 tag **`callmate-ble-0.1.0`**，并上传与 podspec 中 `sha256` 一致的

`CallMateBLEKit.xcframework.zip`（与内部构建产物同一会签名的 zip 即可；勿改 `sha256` 除非重新打包后重新算）。

若 zip 的下载地址或校验和变更，请同时修改 `CallMateBLEKit.podspec` 的 `s.source` 和 `:sha256`。
