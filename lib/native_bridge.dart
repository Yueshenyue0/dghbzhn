import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// SO 原生桥：端点构造 + 域名池 + 签名校验 + token 解密
class NativeCore {
  NativeCore._();
  static NativeCore? _instance;
  static NativeCore get instance => _instance ??= NativeCore._();

  static const _channel = MethodChannel('sig_guard');

  /// 取 APK 签名字节（Kotlin 桥）
  static Future<Uint8List?> _getSignatureBytes() async {
    try {
      final v = await _channel.invokeMethod('getSignature');
      if (v is Uint8List) return v;
    } catch (_) {}
    return null;
  }

  DynamicLibrary? _lib;
  DynamicLibrary? get _dylib {
    if (_lib != null) return _lib;
    try {
      _lib = DynamicLibrary.process();
      _lib!.lookup<NativeFunction<Void Function()>>('domain_pool');
      return _lib;
    } catch (_) {}
    try {
      _lib = DynamicLibrary.open('libverify.so');
      _lib!.lookup<NativeFunction<Void Function()>>('domain_pool');
      return _lib;
    } catch (_) {}
    return null;
  }

  // C 函数签名
  late final _apiUrl = _dylib!
      .lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('api_url');
  late final _domains = _dylib!
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'domain_pool');
  late final _unmask = _dylib!
      .lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>)>('unmask_token');
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

  /// 从 SO 里的域名池取一个域名
  List<String> domainPool() {
    try {
      final raw = _ps(_domains());
      return raw.split(',').where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return ['eri.kdns.fr'];
    }
  }

  /// 解混淆 token（SO 内嵌 XOR 表）
  String unmaskToken(String masked) {
    try {
      return _ps(_unmask(masked.toNativeUtf8()));
    } catch (_) {
      return masked;
    }
  }

  /// SO 内嵌 token（无需用户配置）
  String? embeddedToken() {
    try {
      final t = _ps(_embeddedToken());
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  /// 强签名校验 + 密钥派生 token 解密
  /// 1. MethodChannel 取签名 DER 字节
  /// 2. Dart 算 SHA-256 摘要
  /// 3. SO 比对摘要（指纹 XOR 藏于 SO）并派生密钥
  /// 4. 密钥解密 SO 内嵌 token
  /// 签名不匹配 -> 派生密钥错 -> token 乱码 -> API 401
  String? verifiedToken() {
    // 同步路径拿不到 MethodChannel（需异步），此方法仅在已缓存时有效
    return _cachedVerifiedToken;
  }

  String? _cachedVerifiedToken;

  Future<String?> computeVerifiedToken() async {
    if (_cachedVerifiedToken != null) return _cachedVerifiedToken;
    final sig = await _getSignatureBytes();
    if (sig == null || sig.isEmpty) return null;
    final digest = _sha256(sig);
    final lib = _dylib;
    if (lib == null) return null;
    try {
      final fn = lib.lookupFunction<
          Pointer<Utf8> Function(Pointer<Uint8>),
          Pointer<Utf8> Function(Pointer<Uint8>)>('verified_token');
      final buf = calloc<Uint8>(32);
      buf.asTypedList(32).setAll(0, digest);
      final p = fn(buf);
      calloc.free(buf);
      final token = p.toDartString();
      if (token.startsWith('tm_live_')) {
        _cachedVerifiedToken = token;
        return token;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Uint8List _sha256(List<int> data) {
    final h = _Sha256Impl();
    return h.hash(data);
  }

  /// 原生核心版本（null = SO 未加载，fallback 模式）
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

  /// 更新检查 API（SO 分段构造）
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

  /// 更新页兜底链接
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

  /// 下载加速前缀
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

  /// 随机 local part（SO 里生成）
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

/// 纯 Dart SHA-256（与 mail_api._Sha256 同逻辑）
class _Sha256Impl {
  static const _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  Uint8List hash(List<int> data) {
    var h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
             0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    final bitLen = data.length * 8;
    final padded = [...data, 0x80];
    while (padded.length % 64 != 56) {
      padded.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      padded.add((bitLen >> (i * 8)) & 0xff);
    }
    for (var block = 0; block < padded.length; block += 64) {
      final w = List<int>.filled(64, 0);
      for (var t = 0; t < 16; t++) {
        w[t] = (padded[block + t * 4] << 24) |
               (padded[block + t * 4 + 1] << 16) |
               (padded[block + t * 4 + 2] << 8) |
               padded[block + t * 4 + 3];
      }
      for (var t = 16; t < 64; t++) {
        final s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
        final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
      }
      var a = h[0], b = h[1], c = h[2], d = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];
      for (var t = 0; t < 64; t++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final temp1 = (hh + s1 + ch + _k[t] + w[t]) & 0xffffffff;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xffffffff;
        hh = g; g = f; f = e;
        e = (d + temp1) & 0xffffffff;
        d = c; c = b; b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }
      h[0] = (h[0] + a) & 0xffffffff;
      h[1] = (h[1] + b) & 0xffffffff;
      h[2] = (h[2] + c) & 0xffffffff;
      h[3] = (h[3] + d) & 0xffffffff;
      h[4] = (h[4] + e) & 0xffffffff;
      h[5] = (h[5] + f) & 0xffffffff;
      h[6] = (h[6] + g) & 0xffffffff;
      h[7] = (h[7] + hh) & 0xffffffff;
    }
    final out = <int>[];
    for (final x in h) {
      out.addAll([(x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff]);
    }
    return Uint8List.fromList(out);
  }

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;
}
