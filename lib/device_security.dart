import 'package:flutter/foundation.dart';
import 'package:advance_root_detection/advance_root_detection.dart';

/// 设备安全检测：只认 critical 级真威胁
/// - privilegedAccess  (root，文件/属性级证据，正常设备不会命中)
/// - runtimeManipulation (Frida / Xposed / Substrate hook 框架)
/// - integrityViolation  (重打包：签名或安装完整性被破坏)
///
/// 明确忽略的高误报项：
/// - analysisEnvironment  (模拟器 / VPN —— 加速器、代理都走 TRANSPORT_VPN)
/// - debuggerAttached     (开发者模式 / ADB —— 普通玩家常开)
/// - untrustedSource      (侧载安装 —— 本 App 就是 Canary 直接下载安装)
/// - 无障碍服务（输入法/手势辅助会被库归为 runtimeManipulation，
///   但库对 hook 框架的识别走的是独立特征，见 HookDetector；
///   为避免误伤，runtimeManipulation 需 severity == critical 才算）
class DeviceSecurity {
  DeviceSecurity._();
  static bool _checked = false;
  static String _debugInfo = '';

  /// 命中的真实威胁描述（弹窗里显示，便于你自己排查）
  static String get debugInfo => _debugInfo;

  /// 启动时调用一次。返回 true = 放行；false = 命中真威胁
  static Future<bool> check() async {
    if (_checked) return true;
    _checked = true;
    try {
      final shield = AdvanceRootDetection();
      // 显式关闭 VPN 检测与"开发者模式=威胁"，本 App 就是侧载安装
      const config = SecurityConfig(
        android: AndroidConfig(
          checkVpn: false,
          treatDeveloperModeAsThreat: false,
        ),
      );
      final report = await shield.performCheck(config);
      const blockedCats = {
        ThreatCategory.privilegedAccess,
        ThreatCategory.runtimeManipulation,
        ThreatCategory.integrityViolation,
      };
      final realThreats = report.detectedThreats
          .where((t) => t.severity == Severity.critical && blockedCats.contains(t.category))
          .toList();
      debugPrint('[SECURITY] all: ${report.detectedThreats.map((t) => '${t.category.name}/${t.severity.name}').join(', ')}');
      debugPrint('[SECURITY] blocked: ${realThreats.map((t) => t.category.name).join(', ')}');
      if (realThreats.isNotEmpty) {
        _debugInfo = realThreats.map((t) => t.description).take(3).join('\n');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[SECURITY] check failed: $e');
      return true; // 检测出错时放行，避免误锁
    }
  }
}
