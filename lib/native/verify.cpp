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
  0x2E, 0x51, 0x21, 0xFD, 0x4D, 0xCE, 0x08, 0xAF, 0x6E, 0x05, 0x18, 0xF0,
  0x12, 0x8F, 0x55, 0x91, 0x63, 0x0F, 0x1B, 0xA0, 0x41, 0x8D, 0x5B, 0x95,
  0x63, 0x5E, 0x49, 0xF5, 0x41, 0x8A, 0x5B, 0xC2, 0x6B, 0x0B, 0x1C, 0xF0,
  0x1C, 0xD9, 0x59, 0x95, 0x6C, 0x09, 0x4D, 0xA7, 0x10, 0xDC, 0x0E, 0x91,
  0x62, 0x0E, 0x1A, 0xA4, 0x40, 0x8F, 0x54, 0xC2, 0x3E, 0x0D, 0x4E, 0xF0,
  0x41, 0xDB, 0x5C, 0x91, 0x3C, 0x5D, 0x4B, 0xF5, 0x15, 0xDC, 0x5F, 0xC1
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
  return "3";
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
  out += "dghb";
  out += "zhn/";
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
  out += "yue0/dghb";
  out += "zhn/releases/tag/";
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

// 公告端点：仓库根目录 gg.txt（raw 直链；不存在则 404 -> 不弹公告）
extern "C" __attribute__((visibility("default"))) const char* announcement_url() {
  static std::string out;
  out = "https://raw.";
  out += "githubuser";
  out += "content.com/";
  out += "Yueshen";
  out += "yue0/";
  out += "dghb";
  out += "zhn/";
  out += "main/";
  out += "gg.";
  out += "txt";
  return out.c_str();
}
