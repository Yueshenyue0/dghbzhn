import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'native_bridge.dart';

/// mail.cx API 客户端
/// - 端点由 SO 构造
/// - token 解密密钥由 SO 派生（签名哈希参与，重签 -> 乱码 -> 401）
/// - TLS 只信任 GTS Root R4（防抓包，且证书轮换不断网）
class MailApi {
  MailApi._();
  static final MailApi instance = MailApi._();

  HttpClient? _client;

  /// 只信任 GTS Root R4 的 HttpClient
  ///
  /// 为什么用信任锚而不是 pin 指纹：
  ///   Leaf 证书 90 天轮换，pin 指纹会导致轮换后 App 直接断网；
  ///   只信任 GTS 根证书既能拒绝抓包代理的自签 CA，
  ///   又能在叶子/中间证书轮换后继续正常工作。
  Future<HttpClient> _getClient() async {
    if (_client != null) return _client!;
    try {
      final ctx = SecurityContext(withTrustedRoots: false);
      for (final p in const ['assets/gtsr4_self.pem', 'assets/gtsr4_cross.pem']) {
        try {
          final pem = await rootBundle.loadString(p);
          if (pem.contains('BEGIN CERTIFICATE')) {
            ctx.setTrustedCertificatesBytes(utf8.encode(pem));
          }
        } catch (_) {
          // 单个证书加载失败不影响另一个
        }
      }
      _client = HttpClient(context: ctx)
        ..connectionTimeout = const Duration(seconds: 15);
    } catch (_) {
      // 兜底：信任库不可用时退回系统信任，避免完全不可用
      _client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
    }
    return _client!;
  }

  // ====== token 混淆（密钥由 SO 派生）======
  static List<int>? _cachedKey;

  /// 从 SO 拿派生密钥（Kotlin 启动时已把真实签名哈希传给 SO）
  static List<int> _tokenKey() {
    if (_cachedKey != null) return _cachedKey!;
    try {
      final lib = DynamicLibrary.open('libverify.so');
      final fn = lib.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('derive_token_key_seed');
      final seed = fn().toDartString();
      _cachedKey ??= seed.codeUnits.take(8).toList();
    } catch (_) {
      _cachedKey ??= [0x5A, 0x3C, 0x7E, 0x91, 0x24, 0xB8, 0x6D, 0xF0];
    }
    return _cachedKey!;
  }

  static String _mask(String s) {
    final key = _tokenKey();
    final bytes = utf8.encode(s);
    final out = List<int>.generate(
        bytes.length, (i) => bytes[i] ^ key[i % key.length]);
    return base64.encode(out);
  }

  static String _unmask(String b64) {
    try {
      final key = _tokenKey();
      final bytes = base64.decode(b64);
      final out = List<int>.generate(
          bytes.length, (i) => bytes[i] ^ key[i % key.length]);
      return utf8.decode(out);
    } catch (_) {
      return b64;
    }
  }

  String apiUrl(String path, {String query = ''}) =>
      NativeCore.instance.apiUrl(path, query);

  String get domainPool => NativeCore.instance.domainPool().join(',');

  Future<String?> loadToken() async {
    // 强链路：签名校验 -> 派生密钥 -> 解密 SO 内嵌 token
    final verified = await NativeCore.instance.computeVerifiedToken();
    if (verified != null && verified.isNotEmpty) return verified;
    // 降级：SO 不可用时尝试用户自存的 token
    try {
      final sp = await SharedPreferences.getInstance();
      final masked = sp.getString('tm_token_masked');
      if (masked == null || masked.isEmpty) return null;
      return _unmask(masked);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveToken(String token) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('tm_token_masked', _mask(token));
  }

  Future<void> clearToken() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('tm_token_masked');
    await sp.remove('tm_current_addr');
  }

  Future<String?> loadAddress() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString('tm_current_addr');
  }

  Future<void> saveAddress(String addr) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('tm_current_addr', addr);
  }

  Future<Map<String, dynamic>> _req(String method, String url,
      {String? token,
      Object? body,
      Duration timeout = const Duration(seconds: 30)}) async {
    try {
      final client = await _getClient();
      final req = await client.openUrl(method, Uri.parse(url));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token != null && token.isNotEmpty) {
        req.headers.set('x-api-token', token);
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join();
      Map<String, dynamic> data;
      try {
        final decoded = jsonDecode(text);
        data = decoded is Map<String, dynamic> ? decoded : {'data': decoded};
      } catch (_) {
        data = {'_raw': text};
      }
      data['_status'] = resp.statusCode;
      return data;
    } catch (e) {
      final msg = e.toString();
      // TLS 校验失败（可能是抓包代理或信任库异常）单独标记
      if (msg.contains('CERTIFICATE') || msg.contains('certificate')) {
        return {'_status': -1, 'error': 'tls_rejected'};
      }
      return {'_status': 0, 'error': msg};
    }
  }

  /// 等收件箱新邮件（long-poll，服务端最多 25s）
  Future<Map<String, dynamic>> waitInbox(String addr,
      {String? since, int count = 1, String? token}) {
    final q = StringBuffer();
    if (since != null && since.isNotEmpty) {
      q.write('?since=${Uri.encodeComponent(since)}');
    }
    if (count != 1) {
      q.write(q.isEmpty ? '?' : '&');
      q.write('count=$count');
    }
    return _req('GET', apiUrl('/inbox/$addr', query: q.toString()),
        token: token, timeout: const Duration(seconds: 40));
  }

  /// 域名级监听
  Future<Map<String, dynamic>> waitDomain(String domain,
      {String? since, int count = 1, String? token}) {
    final q = StringBuffer();
    if (since != null && since.isNotEmpty) {
      q.write('?since=${Uri.encodeComponent(since)}');
    }
    if (count != 1) {
      q.write(q.isEmpty ? '?' : '&');
      q.write('count=$count');
    }
    return _req('GET', apiUrl('/domain/$domain', query: q.toString()),
        token: token, timeout: const Duration(seconds: 40));
  }

  /// 全部自有地址
  Future<Map<String, dynamic>> waitMe(
      {String? since, int count = 1, String? token}) {
    final q = StringBuffer();
    if (since != null && since.isNotEmpty) {
      q.write('?since=${Uri.encodeComponent(since)}');
    }
    if (count != 1) {
      q.write(q.isEmpty ? '?' : '&');
      q.write('count=$count');
    }
    return _req('GET', apiUrl('/me', query: q.toString()),
        token: token, timeout: const Duration(seconds: 40));
  }

  Future<Map<String, dynamic>> emailDetail(String id, {String? token}) =>
      _req('GET', apiUrl('/email/$id'), token: token);

  Future<Map<String, dynamic>> deleteEmail(String id, {String? token}) =>
      _req('DELETE', apiUrl('/email/$id'), token: token);

  Future<Map<String, dynamic>> clearInbox(String addr, {String? token}) =>
      _req('DELETE', apiUrl('/inbox/$addr'), token: token);

  Future<Map<String, dynamic>> serverConfig() => _req('GET', apiUrl('/config'));

  Future<Map<String, dynamic>> listDomains({String? token}) =>
      _req('GET', apiUrl('/domains'), token: token);

  /// 下载附件
  Future<List<int>?> downloadAttachment(String emailId, int index,
      {String? token}) async {
    try {
      final client = await _getClient();
      final req = await client.openUrl(
          'GET', Uri.parse(apiUrl('/email/$emailId/attachments/$index')));
      if (token != null && token.isNotEmpty) {
        req.headers.set('x-api-token', token);
      }
      final resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) return null;
      final builder = BytesBuilder();
      await for (final chunk in resp) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    }
  }
}