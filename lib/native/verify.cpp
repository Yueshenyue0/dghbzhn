// libverify.so — 校验 libapp.so 完整性（SHA-256）
// 编译时用 -DEXPECTED_LIBAPP_SHA256="xxx" 注入期望 hash
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string>

#ifndef EXPECTED_LIBAPP_SHA256
#define EXPECTED_LIBAPP_SHA256 "__EXPECTED_SHA__"
#endif

namespace {

// ============ SHA-256 (纯 C++ 实现，零依赖) ============
typedef struct {
  uint8_t data[64];
  uint32_t datalen;
  uint64_t bitlen;
  uint32_t state[8];
} sha256_ctx;

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static const uint32_t K[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

static void sha256_transform(sha256_ctx* ctx, const uint8_t block[64]) {
  uint32_t W[64], a, b, c, d, e, f, g, h, t1, t2;
  int i;
  for (i = 0; i < 16; i++)
    W[i] = ((uint32_t)block[i*4] << 24) | ((uint32_t)block[i*4+1] << 16) |
           ((uint32_t)block[i*4+2] << 8) | block[i*4+3];
  for (i = 16; i < 64; i++) {
    uint32_t s0 = ROTR(W[i-15], 7) ^ ROTR(W[i-15], 18) ^ (W[i-15] >> 3);
    uint32_t s1 = ROTR(W[i-2], 17) ^ ROTR(W[i-2], 19) ^ (W[i-2] >> 10);
    W[i] = W[i-16] + s0 + W[i-7] + s1;
  }
  a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2]; d = ctx->state[3];
  e = ctx->state[4]; f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];
  for (i = 0; i < 64; i++) {
    uint32_t S1 = ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25);
    uint32_t ch = (e & f) ^ ((~e) & g);
    t1 = h + S1 + ch + K[i] + W[i];
    uint32_t S0 = ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22);
    uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    t2 = S0 + maj;
    h = g; g = f; f = e; e = d + t1;
    d = c; c = b; b = a; a = t1 + t2;
  }
  ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
  ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}

static void sha256_init(sha256_ctx* ctx) {
  ctx->datalen = 0; ctx->bitlen = 0;
  ctx->state[0] = 0x6a09e667; ctx->state[1] = 0xbb67ae85;
  ctx->state[2] = 0x3c6ef372; ctx->state[3] = 0xa54ff53a;
  ctx->state[4] = 0x510e527f; ctx->state[5] = 0x9b05688c;
  ctx->state[6] = 0x1f83d9ab; ctx->state[7] = 0x5be0cd19;
}

static void sha256_update(sha256_ctx* ctx, const uint8_t* data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    ctx->data[ctx->datalen++] = data[i];
    ctx->bitlen += 8;
    if (ctx->datalen == 64) { sha256_transform(ctx, ctx->data); ctx->datalen = 0; }
  }
}

static void sha256_final(sha256_ctx* ctx, uint8_t hash[32]) {
  size_t i = ctx->datalen;
  if (ctx->datalen < 56) {
    ctx->data[i++] = 0x80;
    while (i < 56) ctx->data[i++] = 0x00;
  } else {
    ctx->data[i++] = 0x80;
    while (i < 64) ctx->data[i++] = 0x00;
    sha256_transform(ctx, ctx->data);
    memset(ctx->data, 0, 56);
  }
  uint64_t bitlen = ctx->bitlen;
  for (i = 0; i < 8; i++) { ctx->data[63 - i] = (uint8_t)(bitlen & 0xff); bitlen >>= 8; }
  sha256_transform(ctx, ctx->data);
  for (i = 0; i < 8; i++) {
    hash[i*4] = (uint8_t)(ctx->state[i] >> 24);
    hash[i*4+1] = (uint8_t)(ctx->state[i] >> 16);
    hash[i*4+2] = (uint8_t)(ctx->state[i] >> 8);
    hash[i*4+3] = (uint8_t)(ctx->state[i] & 0xff);
  }
}

static std::string sha256_file(const char* path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return "";
  struct stat st;
  if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); return ""; }
  void* map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
  if (map == MAP_FAILED) { close(fd); return ""; }
  sha256_ctx ctx;
  sha256_init(&ctx);
  sha256_update(&ctx, (const uint8_t*)map, (size_t)st.st_size);
  uint8_t hash[32];
  sha256_final(&ctx, hash);
  munmap(map, (size_t)st.st_size);
  close(fd);
  char hex[65];
  for (int i = 0; i < 32; i++) snprintf(hex + i*2, 3, "%02x", hash[i]);
  return std::string(hex, 64);
}

// 通过 dladdr 定位自身路径，得到同目录下的 libapp.so
static bool get_native_dir(std::string* out) {
  Dl_info info;
  if (dladdr((void*)&get_native_dir, &info) == 0 || info.dli_fname == NULL) return false;
  std::string path = info.dli_fname;
  size_t slash = path.rfind('/');
  if (slash == std::string::npos) return false;
  *out = path.substr(0, slash + 1);
  return true;
}

}  // namespace

// 返回值：0=未篡改  1=被篡改  -1=校验出错（未注入/so缺失/读失败）
extern "C" __attribute__((visibility("default"))) int verify_apk_integrity() {
  std::string dir;
  if (!get_native_dir(&dir)) return -1;

  const std::string expected = EXPECTED_LIBAPP_SHA256;
  if (expected == "__EXPECTED_SHA__") return -1;  // 未注入

  std::string app_hash = sha256_file((dir + "libapp.so").c_str());
  if (app_hash.empty()) return -1;

  if (app_hash != expected) return 1;  // 被篡改

  // libflutter.so 必须存在
  if (sha256_file((dir + "libflutter.so").c_str()).empty()) return 1;
  return 0;
}

// 调试：输出当前 libapp.so 的 SHA-256
extern "C" __attribute__((visibility("default"))) void verify_get_libapp_sha256(
    char* buf, int buflen) {
  if (buf == NULL || buflen <= 0) return;
  buf[0] = '\0';
  std::string dir;
  if (!get_native_dir(&dir)) return;
  std::string h = sha256_file((dir + "libapp.so").c_str());
  if (h.empty()) return;
  snprintf(buf, buflen, "%s", h.c_str());
}
// ==================== TempMail 原生核心 ====================
// API 端点构造 / 域名池 / token 解混淆，全部藏在 SO 里，静态字符串不出现在 Dart 快照中

extern "C" __attribute__((visibility("default"))) const char* api_url(
    const char* path, const char* query) {
  static std::string out;
  out = "https://api.";
  out += "mail";
  out += ".";
  out += "cx/v1";
  if (path && path[0]) {
    if (path[0] != '/') out += '/';
    out += path;
  }
  if (query && query[0]) {
    out += query;
  }
  return out.c_str();
}

extern "C" __attribute__((visibility("default"))) const char* domain_pool() {
  // 系统域名 + 用户自定义域名（eri.kdns.fr 已 verified）
  return "eri.kdns.fr";
}

extern "C" __attribute__((visibility("default"))) const char* unmask_token(
    const char* masked) {
  static std::string out;
  out.clear();
  if (!masked) return "";
  // XOR 解混淆：key 与 Dart 侧存储的 mask 过程互逆
  static const unsigned char KEY[] = {0x5A, 0x3C, 0x7E, 0x91, 0x24, 0xB8, 0x6D, 0xF0};
  const size_t klen = sizeof(KEY);
  size_t n = strlen(masked);
  for (size_t i = 0; i < n; i++) {
    out += (char)(masked[i] ^ KEY[i % klen]);
  }
  return out.c_str();
}

// 内嵌 token（XOR 混淆，密钥仅存于此 SO）
extern "C" __attribute__((visibility("default"))) const char* embedded_token() {
  // 返回双重加密的 token 密文（Dart 侧用签名派生密钥二次解密）
  static const unsigned char ENC[] = {
  0x2E, 0x51, 0x21, 0xFD, 0x4D, 0xCE, 0x08, 0xAF, 0x63, 0x5F, 0x4C, 0xA7,
  0x47, 0xDA, 0x5E, 0xC6, 0x3C, 0x0C, 0x46, 0xA9, 0x10, 0x8B, 0x0C, 0x95,
  0x6E, 0x09, 0x1A, 0xF4, 0x1D, 0xD9, 0x58, 0x96, 0x3B, 0x0B, 0x4F, 0xA2,
  0x12, 0x88, 0x08, 0x93, 0x3C, 0x0B, 0x1C, 0xA8, 0x17, 0x8C, 0x0B, 0xC3,
  0x38, 0x5F, 0x4C, 0xA8, 0x40, 0x8F, 0x0F, 0x95, 0x69, 0x5D, 0x4E, 0xF7,
  0x10, 0xDE, 0x54, 0xC6, 0x3B, 0x08, 0x1D, 0xF3, 0x1D, 0x8F, 0x59, 0x94
  };
  static const unsigned char KEY[] = {0x5A, 0x3C, 0x7E, 0x91, 0x24, 0xB8, 0x6D, 0xF0};
  static char out[sizeof(ENC) + 1];
  for (size_t i = 0; i < sizeof(ENC); i++) {
    out[i] = (char)(ENC[i] ^ KEY[i % sizeof(KEY)]);
  }
  out[sizeof(ENC)] = '\0';
  return out;
}

// 原生核心版本标记（用于运行时确认 SO 已加载）
extern "C" __attribute__((visibility("default"))) const char* native_version() {
  return "2";
}

// 更新检查相关端点（与 API 一样藏进 SO）
extern "C" __attribute__((visibility("default"))) const char* update_api_url() {
  static std::string out;
  out = "https://api.";
  out += "github";
  out += ".com/";
  out += "repos/";
  out += "Yueshen";
  out += "yue0/";
  out += "temp";
  out += "mail/";
  out += "releases/tags/";
  out += "Can";
  out += "ary";
  return out.c_str();
}

extern "C" __attribute__((visibility("default"))) const char* update_page_url() {
  static std::string out;
  out = "https://";
  out += "git";
  out += "hub.com/Yueshen";
  out += "yue0/temp";
  out += "mail/releases/tag/";
  out += "Can";
  out += "ary";
  return out.c_str();
}

extern "C" __attribute__((visibility("default"))) const char* update_accel_prefix() {
  static std::string out;
  out = "https://";
  out += "ghf";
  out += "ast.top/";
  return out.c_str();
}

// ==================== 强签名校验（SO 层） ====================
// 设计：签名哈希参与 token 解密密钥派生。
// 重签名 -> 派生密钥错 -> token 乱码 -> API 401。hook 校验函数无用。


// 官方签名证书 SHA-256（XOR 混淆存储，密钥 SIGXOR）
static const unsigned char SIGXOR = 0x5C;
static const unsigned char SIG_ENC[32] = {
  0x94, 0x9C, 0xB8, 0x5D, 0x9C, 0xA6, 0x83, 0x9F, 0x99, 0x82, 0xC1, 0x75, 0x8A, 0x95, 0xAF, 0x07,
  0x40, 0x8A, 0x58, 0x28, 0xEC, 0xB5, 0xFA, 0x68, 0x28, 0xEE, 0xF5, 0x0D, 0x08, 0x3B, 0x20, 0xE9
};

// token 解密密钥（XOR 混淆存储）：真密钥 = TOKEN_KEY_ENC ^ 0xA9
static const unsigned char SIGKEY_XOR = 0xA9;
static const unsigned char TOKEN_KEY_ENC[8] = {
  0xF3, 0x95, 0xD7, 0x38, 0x8D, 0x11, 0xC4, 0x59
};
// 前向声明：SHA-256 已在此文件实现
// （sha256_file 用的是文件流，这里需要内存版）
static void sha256_mem(const unsigned char* data, size_t len, unsigned char out[32]) {
  // 简化：使用与 sha256_file 相同的底层（此处独立实现摘要）
  // 为避免重复实现，这里复用已有 SHA-256 结构体
  sha256_ctx ctx;
  sha256_init(&ctx);
  sha256_update(&ctx, data, (uint32_t)len);
  sha256_final(&ctx, out);
}





// Dart 传入 sha256(签名DER) 的 32 字节摘要，SO 内比对并派生 token 密钥
// 返回 8 字节密钥（签名对 -> 真密钥；错 -> 假密钥）
extern "C" __attribute__((visibility("default"))) const char*
derive_token_key(const unsigned char* digest32) {
  if (!digest32) return 0;
  unsigned char expected[32];
  for (int i = 0; i < 32; i++) expected[i] = SIG_ENC[i] ^ SIGXOR;
  unsigned char diff = 0;
  for (int i = 0; i < 32; i++) diff |= digest32[i] ^ expected[i];
  static unsigned char key[9];
  for (int i = 0; i < 8; i++) key[i] = TOKEN_KEY_ENC[i] ^ SIGKEY_XOR;
  if (diff != 0) {
    for (int i = 0; i < 8; i++) key[i] ^= 0xA5;
  }
  key[8] = 0;
  return (const char*)key;
}

// ==================== 运行时签名校验（SO 层，无分支可 patch） ====================
// 读取本应用签名证书的 SHA-256；token 解密密钥由签名哈希派生。
// 签名不对 -> 解出的 token 是乱码 -> API 401，攻击者无法定位检测点。


// 在首次调用时缓存签名哈希（hex 字符串，64 字符）
static std::string g_sig_hash;
static bool g_sig_loaded = false;

extern "C"
__attribute__((visibility("default")))
void set_signature_hash(const char* hex64) {
  // 由 Kotlin 层传入真实签名哈希（Java 层读签名最方便）
  // 但注意：这个值本身会被 Dart/Kotlin 校验逻辑交叉验证
  g_sig_hash = hex64 ? hex64 : "";
  g_sig_loaded = true;
}

// SHA-256 扩展：对任意缓冲区计算（复用已有 sha256 实现）
extern "C"
__attribute__((visibility("default")))
const char* derive_token_key_seed() {
  // token 解密种子 = 预置盐 XOR 签名哈希
  // 只有真签名才能推出正确种子
  static std::string seed;
  static const char SALT[] = "TM-KEY-SALT-v1::9f27ac41e8";
  std::string base = g_sig_hash.empty() ? std::string(64, '0') : g_sig_hash;
  seed.resize(64);
  for (int i = 0; i < 64; i++) {
    seed[i] = base[i] ^ SALT[i % strlen(SALT)];
  }
  return seed.c_str();
}

// 校验签名哈希是否等于官方值（供 Dart 查询，返回 1=官方 0=非官方）
extern "C"
__attribute__((visibility("default")))
int is_official_signature() {
  static const char OFFICIAL[] = "C8C0E401C0FADFC3C5DE9D29D6C9F35B1CD60474B0E9A63474B2A95154677CB5";
  if (g_sig_hash.size() != 64) return 0;
  // 常量时间比较防时序攻击
  volatile int diff = 0;
  for (int i = 0; i < 64; i++) {
    diff |= (unsigned char)g_sig_hash[i] ^ (unsigned char)OFFICIAL[i];
  }
  return diff == 0 ? 1 : 0;
}

// ==================== JNI: Kotlin 传入真实签名哈希 ====================
// 签名哈希同时用于：1) is_official_signature 校验  2) token 密钥派生
#ifdef __ANDROID__
#include <jni.h>

extern "C"
__attribute__((visibility("default")))
void Java_com_eri_tempmail_MainActivity_nativeSetSignatureHash(
    JNIEnv* env, jobject, jstring hex64) {
  if (!hex64) return;
  const char* s = env->GetStringUTFChars(hex64, nullptr);
  if (s) {
    set_signature_hash(s);
    env->ReleaseStringUTFChars(hex64, s);
  }
}
#endif

// Dart 侧直接取派生密钥（用 Kotlin 已存入的签名哈希），无需再传参
extern "C"
__attribute__((visibility("default"))) const char*
derive_token_key_from_saved() {
  static unsigned char key[9];
  if (g_sig_hash.size() != 64) {
    // 签名未注入：返回假密钥
    for (int i = 0; i < 8; i++) key[i] = (unsigned char)(TOKEN_KEY_ENC[i] ^ SIGKEY_XOR ^ 0xA5);
    key[8] = 0;
    return (const char*)key;
  }
  unsigned char digest[32];
  for (int i = 0; i < 32; i++) {
    char b[3] = { g_sig_hash[i*2], g_sig_hash[i*2+1], 0 };
    digest[i] = (unsigned char)strtol(b, nullptr, 16);
  }
  unsigned char expected[32];
  for (int i = 0; i < 32; i++) expected[i] = SIG_ENC[i] ^ SIGXOR;
  unsigned char diff = 0;
  for (int i = 0; i < 32; i++) diff |= digest[i] ^ expected[i];
  for (int i = 0; i < 8; i++) key[i] = TOKEN_KEY_ENC[i] ^ SIGKEY_XOR;
  if (diff != 0) { for (int i = 0; i < 8; i++) key[i] ^= 0xA5; }
  key[8] = 0;
  return (const char*)key;
}

// ==================== verified_token: 签名绑定 token 的唯一出口 ====================
// 入参: sha256(签名DER) 32字节。SO 内比对混淆存储的官方指纹（SIG_ENC^SIGXOR）。
// 匹配 -> 返回真 token；不匹配 -> 返回空串。
extern "C"
__attribute__((visibility("default")))
const char* verified_token(const unsigned char* digest32) {
  if (!digest32) return "";
  unsigned char expected[32];
  for (int i = 0; i < 32; i++) expected[i] = SIG_ENC[i] ^ SIGXOR;
  unsigned char diff = 0;
  for (int i = 0; i < 32; i++) diff |= digest32[i] ^ expected[i];
  if (diff != 0) return "";
  return embedded_token();
}
