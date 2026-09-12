import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_bridge.dart';

/// 公告弹窗：读取仓库根目录 gg.txt
/// - 文件不存在(404) / 内容为空 -> 不弹
/// - 内容有变化（按 SHA-256 去重）-> 弹一次
/// 拉取走 ghfast 加速前缀（raw.githubusercontent 国内常不通）
class AnnouncementService {
  AnnouncementService._();
  static final AnnouncementService instance = AnnouncementService._();

  /// 返回 true 表示弹过公告（供调用方决定后续弹窗顺序）
  Future<bool> checkAndShow(BuildContext context) async {
    try {
      final text = await _fetch();
      if (text == null) return false; // 不存在 / 网络失败：静默
      final body = _clean(text);
      if (body.isEmpty) return false; // 空文件：不弹
      final hash = sha256.convert(utf8.encode(body)).toString();
      final sp = await SharedPreferences.getInstance();
      if (sp.getString('tm_seen_ann') == hash) return false; // 这条已看过
      if (!context.mounted) return false;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('公告'),
          content: SingleChildScrollView(
            child: SelectableText(
              body,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      // 弹窗关闭后才标记：中途强杀下次仍会再弹
      await sp.setString('tm_seen_ann', hash);
      return true;
    } catch (_) {
      return false; // 任何异常都不打扰使用
    }
  }

  /// 拉取 gg.txt。返回 null = 不存在/失败；返回 '' = 空内容
  Future<String?> _fetch() async {
    final raw = NativeCore.instance.announcementUrl;
    final url = raw.startsWith('http')
        ? '${NativeCore.instance.updateAccelPrefix}$raw'
        : raw;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'tempmail-app');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null; // 404 等：视为无公告
      }
      return await resp.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }

  /// 去掉 BOM、行尾 \\r、首尾空行与多余空白
  String _clean(String s) {
    var t = s.replaceFirst('\ufeff', '').replaceAll('\r', '');
    // 去掉全空行组成的段落分隔造成的首尾空白
    t = t
        .split('\n')
        .map((l) => l.trimRight())
        .join('\n')
        .trim();
    return t;
  }
}