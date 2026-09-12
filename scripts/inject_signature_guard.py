#!/usr/bin/env python3
"""注入自定义 MainActivity.kt：
1. 强签名校验（签名不对杀进程）
2. 签名哈希传给 SO（token 解密密钥派生，签名错 -> token 乱码）
3. installApk MethodChannel（应用内更新调起系统安装器）
幂等：已注入则跳过。
"""
import os

ACTIVITY_DIR = 'android/app/src/main/kotlin/com/eri/tempmail'
EXPECTED_SHA = 'B2:50:00:D1:0B:0C:1D:A5:C7:D7:28:C0:6C:99:22:BE:83:4C:D3:29:41:63:C3:20:55:2F:24:82:5A:9B:AB:51'
EXPECTED_HEX = EXPECTED_SHA.replace(':', '')


def main():
    os.makedirs(ACTIVITY_DIR, exist_ok=True)
    path = os.path.join(ACTIVITY_DIR, 'MainActivity.kt')
    if os.path.exists(path):
        src = open(path, encoding='utf-8').read()
        if 'SIGNATURE_CHECK' in src:
            print('signature guard already injected')
            return

    code = '''// SIGNATURE_CHECK: native-level signature guard + in-app install channel
// Built-in Kotlin: migrated to Kotlin DSL for Flutter 3.47 compatibility
package com.eri.tempmail

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    companion object {
        private val EXPECTED = setOf("__EXPECTED_SHA__")
        private const val INSTALL_CHANNEL = "com.eri.tempmail/install"
        private const val SIG_CHANNEL = "sig_guard"
        private const val TAG = "TempMail"
    }

    override fun onResume() {
        super.onResume()
        if (!verifySignature()) {
            android.os.Process.killProcess(android.os.Process.myPid())
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 1) 签名哈希传给 SO（token 解密密钥派生）
        try { System.loadLibrary("verify") } catch (_: Throwable) {}
        try { nativeSetSignatureHash(currentSignatureHex()) } catch (_: Throwable) {}

        // 2) 应用内安装通道 + 签名字节通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        result.success(if (path != null) installApk(path) else 1)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SIG_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSignature" -> result.success(currentSignatureBytes())
                    else -> result.notImplemented()
                }
            }
    }

    private fun currentSignatureHex(): String = try {
        val pm = packageManager
        val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                .signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures
        }
        sigs?.firstOrNull()?.let { sig ->
            MessageDigest.getInstance("SHA-256")
                .digest(sig.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }.orEmpty()
    } catch (_: Throwable) { "" }

    private fun currentSignatureBytes(): ByteArray? = try {
        val pm = packageManager
        val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                .signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures
        }
        sigs?.firstOrNull()?.toByteArray()
    } catch (_: Throwable) { null }

    /**
     * 应用内安装，返回码:
     *  0 = 已拉起安装器
     *  1 = 文件不存在
     *  2 = 需授权"安装未知应用"
     *  3 = 内部错误
     */
    private fun installApk(path: String): Int = try {
        val file = File(path)
        if (!file.exists() || file.length() <= 0L) return 1

        // Android 8+：检查"安装未知应用"权限
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            val i = Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
            i.data = android.net.Uri.parse("package:$packageName")
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            return 2
        }

        val authority = "$packageName.fileprovider"
        val uri = try {
            androidx.core.content.FileProvider.getUriForFile(
                applicationContext, authority, file
            )
        } catch (_: Throwable) {
            // 路径不在 FileProvider 配置内：复制到 cacheDir 再提供
            val dst = File(cacheDir, "update.apk")
            file.copyTo(dst, overwrite = true)
            androidx.core.content.FileProvider.getUriForFile(
                applicationContext, authority, dst
            )
        }
        Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }.let(::startActivity)
        0
    } catch (_: Throwable) { 3 }

    // JNI 桥（SO 提供）
    private external fun nativeSetSignatureHash(hex64: String)

    private fun verifySignature(): Boolean = try {
        val pm = packageManager
        val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                .signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures
        }
        sigs?.any { sig ->
            val hex = MessageDigest.getInstance("SHA-256")
                .digest(sig.toByteArray())
                .joinToString("") { "%02x".format(it) }
            hex.uppercase() in EXPECTED
        } == true
    } catch (_: Throwable) { false }
}
'''
    code = code.replace('__EXPECTED_SHA__', EXPECTED_HEX)
    open(path, 'w', encoding='utf-8').write(code)
    print('MainActivity signature guard + install channel injected')


if __name__ == '__main__':
    main()