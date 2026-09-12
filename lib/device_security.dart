import 'package:flutter/foundation.dart';
import 'package:advanced_root_detection/advanced_root_detection.dart';

/// 设备安全检测：Frida / Xposed / Root / Hook / Emulator
/// 检测到危险环境时弹警告并退出
class DeviceSecurity {
  DeviceSecurity._();
  static bool _checked = false;

  /// 启动时调用一次，返回 true = 安全，false = 检测到威胁
  static Future<bool> check() async {
    if (_checked) return true;
    _checked = true;
    try {
      final result = await AdvancedRootDetection.instance.detect();
      if (result.isRooted ||
          result.isHooked ||
          result.isFridaDetected ||
          result.isEmulator) {
        debugPrint('[SECURITY] threat detected: '
            'root=${result.isRooted} hook=${result.isHooked} '
            'frida=${result.isFridaDetected} emu=${result.isEmulator}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[SECURITY] check failed: $e');
      return true; // 检测出错时放行，避免误锁
    }
  }
}