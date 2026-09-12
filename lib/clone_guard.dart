import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 虚拟化 / 分身 / 多开容器检测（纯 Dart，无第三方依赖）
///
/// 背景：VirtualApp 类双开框架会被 advance_root_detection 归入
/// analysisEnvironment / untrustedSource 的低危级别，而这些级别为了消除
/// VPN / 开发者模式 / 侧载误报已被放行，所以需要这里用「分身必然暴露」的
/// 硬特征补上。
///
/// 判据（只针对寄生式双开框架，不含系统多用户）：
/// 1. /proc/self/cmdline 进程名 != 自身包名 -> 被宿主进程拉起
/// 2. /proc/self/maps 映射了别的包的 /data 目录 -> 宿主代码/资源注入本进程
/// 3. 缓存目录路径不含自身包名 -> dataDir 被重定向到宿主目录下
class CloneGuard {
  CloneGuard._();

  static const String _pkg = 'com.eri.tempmail';
  static bool _checked = false;
  static List<String> _hits = const [];

  /// 命中的原因列表（供弹窗显示）
  static List<String> get hits => _hits;

  /// true = 干净环境；false = 处于分身/虚拟化容器内
  static Future<bool> check() async {
    if (_checked) return _hits.isEmpty;
    _checked = true;
    final reasons = <String>[];

    // ---- 1) 进程身份：cmdline 必须是自身包名（允许 包名:子进程）----
    try {
      final raw = await File('/proc/self/cmdline').readAsString();
      final proc = raw.split('\u0000').first.trim();
      if (proc.isNotEmpty && proc != _pkg && !proc.startsWith('$_pkg:')) {
        reasons.add('进程由宿主 $proc 拉起');
      }
    } catch (_) {/* 读不到不判定，避免误报 */}

    // ---- 2) 内存映射：别的包的私有数据目录 ----
    try {
      final intruder = await _scanForeignDataDir();
      if (intruder != null) reasons.add(intruder);
    } catch (_) {}

    // ---- 3) 数据目录路径是否还在自己包名下 ----
    try {
      final tmp = Directory.systemTemp.path;
      if (!tmp.contains(_pkg)) {
        reasons.add('数据目录被重定向到 $tmp');
      }
    } catch (_) {}

    _hits = reasons;
    debugPrint(reasons.isEmpty
        ? '[CLONE] clean'
        : '[CLONE] detected: ${reasons.join(' | ')}');
    return reasons.isEmpty;
  }

  /// 扫描 /proc/self/maps：真机上本进程只会映射自己包名下的私有目录，
  /// 出现任何第三方（非系统/厂商白名单）包名段 = 分身宿主注入。
  /// 注意 VirtualApp 类框架重定向后的路径形如
  /// /data/data/<宿主包>/virtual/0/com.eri.tempmail/...，仍会暴露宿主包名段，
  /// 所以这里对整条路径提取包名段，而不是只看第一个段。
  static Future<String?> _scanForeignDataDir() async {
    final f = File('/proc/self/maps');
    if (!await f.exists()) return null;
    final lines = f
        .openRead()
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final i = line.indexOf('/data/data/');
      final j = line.indexOf('/data/user');
      final start = i >= 0 ? i : j;
      if (start < 0) continue;
      // 路径是 maps 最后一列，取到行尾（可能带 " (deleted)" 后缀）
      final path = line.substring(start).split(' ')[0];
      for (final seg in path.split('/')) {
        if (!looksLikePackage(seg)) continue;
        if (seg == _pkg) continue;
        if (_isSystemPackage(seg)) continue;
        return '宿主包注入本进程: $seg';
      }
    }
    return null;
  }

  /// 粗略判断字符串是否为 Java 包名（多段点分、字母数字下划线、不以扩展名结尾）
  static bool looksLikePackage(String s) {
    if (s.length < 5 || !s.contains('.')) return false;
    if (RegExp(r'\.(apk|dex|oat|so|jar|lib|art|vdex)$').hasMatch(s)) return false;
    return RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$').hasMatch(s);
  }

  /// 系统/厂商包白名单
  static bool _isSystemPackage(String p) {
    const prefix = [
      'android.',
      'com.android.',
      'dalvik.',
      'org.apache.',
      'com.google.android.',
      'com.miui.',
      'com.huawei.',
      'com.samsung.',
      'com.oplus.',
      'oneplus.',
    ];
    return prefix.any(p.startsWith);
  }
}