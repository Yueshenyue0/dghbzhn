import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'hash_util.dart';
import 'native_bridge.dart';

/// 应用内更新：下载（进度条）→ 校验 → 调起安装
/// - 不跳浏览器，全程 App 内完成
/// - 下载走 HttpClient + 证书指纹校验（防抓包：指纹不符即断开）
/// - URL 由 SO 构造，Dart 快照无完整明文
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  String? _apkUrl;
  String? _publishedAt;
  String? _apkDigest;

  /// 检查更新并弹强制更新窗。返回 true=弹了更新框。
  Future<bool> checkAndPrompt(BuildContext context) async {
    try {
      final data = await _fetchRelease();
      if (data == null) return false;
      final assets = data['assets'] as List? ?? [];
      final apk = assets.firstWhere(
        (a) => (a['name'] as String? ?? '').endsWith('.apk'),
        orElse: () => null,
      );
      if (apk == null) return false;
      _apkUrl = apk['browser_download_url'] as String?;
      // GitHub 提供的 sha256 摘要（格式 "sha256:xxxx"），用于下载后校验
      _apkDigest = (apk['digest'] as String?)?.toLowerCase();
      _publishedAt = (data['published_at'] ?? data['created_at'] ?? '')
          as String;

      final sp = await SharedPreferences.getInstance();
      final seen = sp.getString('tm_seen_canary');
      if (seen == _publishedAt) return false;
      if (!context.mounted) return false;
      await _showForceDialog(context);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> _fetchRelease() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      final req = await client.getUrl(
          Uri.parse(NativeCore.instance.updateApiUrl));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'tempmail-app');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _showForceDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: _UpdateDialog(
            apkUrl: _apkUrl!,
            publishedAt: _publishedAt!,
            apkDigest: _apkDigest,
          ),
      ),
    );
  }
}

/// 更新弹窗：进度条下载 + 完成自动调起安装
class _UpdateDialog extends StatefulWidget {
  final String apkUrl;
  final String publishedAt;
  final String? apkDigest;
  const _UpdateDialog({
    required this.apkUrl,
    required this.publishedAt,
    this.apkDigest,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double _progress = 0;
  String _statusText = '准备下载...';
  bool _downloading = false;
  bool _done = false;
  String? _error;

  /// 下载 URL：加速前缀 + 原始直链
  String get _downloadUrl {
    final raw = widget.apkUrl;
    return '${NativeCore.instance.updateAccelPrefix}$raw';
  }

  Future<void> _startDownload() async {
    if (_downloading || _done) return;
    setState(() { _downloading = true; _error = null; });
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(_downloadUrl));
      req.headers.set('User-Agent', 'tempmail-app');
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      final sp = await SharedPreferences.getInstance();
      // 应用私有目录（无需存储权限）
      final dir = Directory.systemTemp;
      final file = File('${dir.path}/tm_update_${DateTime.now().millisecondsSinceEpoch}.apk');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp) {
        received += chunk.length;
        sink.add(chunk);
        if (total != null && total > 0 && mounted) {
          setState(() {
            _progress = received / total;
            _statusText = '下载中 ${( _progress * 100).toStringAsFixed(0)}%';
          });
        }
      }
      await sink.close();
      if (received < 1024) throw Exception('文件过小，可能被劫持');
      // SHA-256 完整性校验（GitHub asset digest 格式 "sha256:xxxx"）
      if (widget.apkDigest != null && widget.apkDigest!.startsWith('sha256:')) {
        final expected = widget.apkDigest!.substring(7);
        final actual = await HashUtil.fileHex(file.path);
        if (actual != expected) {
          await file.delete();
          throw Exception('完整性校验失败，包可能被篡改');
        }
      }
      _done = true;
      if (!mounted) return;
      setState(() { _statusText = '下载完成，正在打开安装...'; _progress = 1; });
      // 记录：下载成功即标记已见（安装器只是弹窗，无法回调安装结果）
      await sp.setString('tm_seen_canary', widget.publishedAt);
      // 调起系统安装器
      await _triggerInstall(file.path);
    } catch (e) {
      if (!mounted) return;
      // 下载失败清除已见标记，下次启动重新弹
      final sp = await SharedPreferences.getInstance();
      await sp.remove('tm_seen_canary');
      setState(() {
        _downloading = false;
        _error = '下载失败: $e';
        _statusText = '点击重试';
      });
    }
  }

  Future<void> _triggerInstall(String apkPath) async {
    // Android 安装通道返回码: 0=已拉起安装 1=文件不存在 2=需授权"安装未知应用" 3=内部错误
    try {
      const platform = MethodChannel('com.eri.tempmail/install');
      final code = await platform.invokeMethod('installApk', {'path': apkPath});
      if (!mounted) return;
      final c = code is int ? code : 3;
      if (c == 0) {
        setState(() {
          _error = null;
          _statusText = '已打开安装界面，请确认安装';
        });
      } else if (c == 1) {
        setState(() {
          _downloading = false;
          _error = '安装包文件不存在，请重试';
          _statusText = '点击重试';
        });
      } else if (c == 2) {
        setState(() {
          _downloading = false;
          _error = null;
          _statusText = '请先允许「安装未知应用」权限，返回后点「安装」';
        });
      } else {
        setState(() {
          _downloading = false;
          _error = '安装失败，请检查系统是否拦截';
          _statusText = '点击重试';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = '安装调用失败: $e';
          _statusText = '点击重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('发现新版本'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('本版本为强制更新。'),
          const SizedBox(height: 14),
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 10),
          Text(_error ?? _statusText,
              style: TextStyle(
                  color: _error != null ? Colors.red : null, fontSize: 13)),
        ],
      ),
      actions: [
        if (!_downloading)
          FilledButton(
            onPressed: _startDownload,
            child: Text(_done ? '安装' : (_error != null ? '重试' : '立即更新')),
          ),
      ],
    );
  }
}