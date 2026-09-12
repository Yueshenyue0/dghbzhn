import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'native_bridge.dart';

/// mail.cx API 客户端（纯 Dart，无 pinning，无签名校验）
class MailApi {
  MailApi._();
  static final MailApi instance = MailApi._();

  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  String apiUrl(String path, {String query = ''}) =>
      NativeCore.instance.apiUrl(path, query);

  String get domainPool => NativeCore.instance.domainPool().join(',');

  Future<String?> loadToken() async {
    // 优先从 SO 内嵌读取（已解密明文）
    final so = NativeCore.instance.embeddedToken();
    if (so != null && so.startsWith('tm_live_')) return so;
    // 降级：读用户手动存的
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString('tm_token');
    } catch (_) {
      return null;
    }
  }

  Future<void> saveToken(String token) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('tm_token', token);
  }

  Future<void> clearToken() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('tm_token');
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
      {String? token, Object? body, Duration timeout = const Duration(seconds: 30)}) async {
    try {
      final req = await _client.openUrl(method, Uri.parse(url));
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
      return {'_status': 0, 'error': e.toString()};
    }
  }

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
    final url = apiUrl('/inbox/$addr', query: q.toString());
    return _req('GET', url, token: token, timeout: const Duration(seconds: 40));
  }

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

  Future<Map<String, dynamic>> waitMe({String? since, int count = 1, String? token}) {
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
}