//
//  CallMate-Bridging-Header.h
//  CallMate
//
//  桥接头文件 - 当启用真实 Opus 编解码时需要
//

#ifndef CallMate_Bridging_Header_h
#define CallMate_Bridging_Header_h

// 如果要使用真正的 Opus 编解码，请：
// 1) 添加 libopus 库（CocoaPods/SPM/手动）
// 2) 在 Target Build Settings 设置 SWIFT_OBJC_BRIDGING_HEADER 指向该文件
// 3) 在 Target Build Settings 设置 SWIFT_ACTIVE_COMPILATION_CONDITIONS 包含 USE_REAL_OPUS

#include <opus.h>
#include "ThirdParty/libsbc/include/sbc.h"

static inline int opus_encoder_ctl_set_bitrate(OpusEncoder *st, opus_int32 bitrate) {
    return opus_encoder_ctl(st, OPUS_SET_BITRATE(bitrate));
}

#endif /* CallMate_Bridging_Header_h */
