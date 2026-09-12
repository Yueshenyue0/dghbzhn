import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// SO 原生桥：端点构造 + 域名池 + token 解密
/// 纯 Dart，无签名校验，无 MethodChannel
class NativeCore {
  NativeCore._();
  static NativeCore? _instance;
  static NativeCore get instance => _instance ??= NativeCore._();

  DynamicLibrary? _lib;
  DynamicLibrary? get _dylib {
    if (_lib != null) return _lib;
    try {
      _lib = DynamicLibrary.open('libverify.so');
      _lib!.lookup<NativeFunction<Void Function()>>('domain_pool');
      return _lib;
    } catch (_) {
      return null;
    }
  }

  late final _apiUrl = _dylib!
      .lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('api_url');
  late final _domains = _dylib!
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'domain_pool');
  late final _embeddedToken = _dylib!
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'embedded_token');

  String _ps(Pointer<Utf8> p) => p.toDartString();

  String apiUrl(String path, String query) {
    try {
      return _ps(_apiUrl(path.toNativeUtf8(), query.toNativeUtf8()));
    } catch (_) {
      return 'https://api.mail.cx/v1$path$query';
    }
  }

  List<String> domainPool() {
    try {
      final raw = _ps(_domains());
      return raw.split(',').where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return ['eri.kdns.fr'];
    }
  }

  /// SO 内嵌的明文 token（SO 内部已完成 XOR 解密，直接返回）
  String? embeddedToken() {
    try {
      final t = _ps(_embeddedToken());
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  String? nativeVersion() {
    try {
      final lib = _dylib;
      if (lib == null) return null;
      final fn = lib.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('native_version');
      return _ps(fn());
    } catch (_) {
      return null;
    }
  }

  String get updateApiUrl {
    try {
      final lib = _dylib;
      if (lib == null) throw StateError('no lib');
      final fn = lib.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('update_api_url');
      return _ps(fn());
    } catch (_) {
      return ['https://api.', 'github.', 'com/repos/Yueshen', 'yue0/tempmail/releases/tags/Can', 'ary'].join();
    }
  }

  String get updatePageUrl {
    try {
      final lib = _dylib;
      if (lib == null) throw StateError('no lib');
      final fn = lib.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('update_page_url');
      return _ps(fn());
    } catch (_) {
      return ['https://git', 'hub.com/Yueshen', 'yue0/tempmail/releases/tag/Can', 'ary'].join();
    }
  }

  String get updateAccelPrefix {
    try {
      final lib = _dylib;
      if (lib == null) throw StateError('no lib');
      final fn = lib.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('update_accel_prefix');
      return _ps(fn());
    } catch (_) {
      return ['https://ghf', 'ast.top/'].join();
    }
  }

  String randLocal() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    var x = rnd;
    for (var i = 0; i < 10; i++) {
      x = (x * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF;
      buf.write(chars[(x >> 33) % chars.length]);
    }
    return buf.toString();
  }
}