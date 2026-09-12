import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 抓包/调试代理检测（不依赖证书 pinning，零误报优先）
///
/// 原理：Charles / Burp / Fiddler / mitmproxy / 抓包管家 这类工具
/// 一定会在本机 127.0.0.1 监听特征端口。VPN / 加速器 / 网络共享
/// 使用的是 tun 接口和 7890/1080 这类通用代理端口，不在检测名单里。
class ProxyGuard {
  ProxyGuard._();
  static bool _checked = false;
  static String _reason = '';

  /// 命中原因（弹窗显示，便于排查）
  static String get reason => _reason;

  /// 只拦"抓包工具"特征端口，刻意排除 clash/v2ray 等加速器端口
  static const Map<int, String> _proxyPorts = {
    8888: 'Charles',
    8899: 'Charles',
    8090: 'Charles',
    8080: 'mitmproxy / Burp 默认',
    8081: 'Burp Suite',
    8085: 'Fiddler Classic',
    8866: 'Fiddler Everywhere',
    9090: '代理调试工具',
    7777: '抓包管家 / HttpCanary',
    7778: '抓包管家 / HttpCanary',
  };

  /// 返回 true = 环境干净；false = 检测到抓包代理
  static Future<bool> check() async {
    if (_checked) return _reason.isEmpty;
    _checked = true;
    final hits = <String>[];
    for (final e in _proxyPorts.entries) {
      if (await _portListening(e.key)) {
        hits.add('端口 ${e.key}（${e.value}）');
      }
    }
    if (hits.isNotEmpty) {
      _reason = hits.join('、');
      debugPrint('[PROXY] detected: $_reason');
      return false;
    }
    debugPrint('[PROXY] clean');
    return true;
  }

  /// 本地回环连接探测：300ms 超时，连得上即有服务监听
  static Future<bool> _portListening(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 300),
      );
      await socket.close().catchError((_) {});
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}