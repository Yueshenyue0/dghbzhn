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
package com.eri.tempmail

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    companion object {
        private val EXPECTED = setOf("__EXPECTED_SHA__")
        private const val INSTALL_CHANNEL = "com.eri.tempmail/install"
        private const val SIG_CHANNEL = "sig_guard"
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
                        result.success(if (path != null) installApk(path) else false)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SIG_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getSignature") {
                    result.success(currentSignatureBytes())
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun currentSignatureHex(): String {
        return try {
            val pm = applicationContext.packageManager
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                info.signatures
            }
            if (signatures == null || signatures.isEmpty()) "" else {
                val md = MessageDigest.getInstance("SHA-256")
                val digest = md.digest(signatures[0].toByteArray())
                digest.joinToString("") { "%02x".format(it) }
            }
        } catch (t: Throwable) { "" }
    }

    private fun currentSignatureBytes(): ByteArray? {
        return try {
            val pm = applicationContext.packageManager
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                info.signatures
            }
            if (signatures == null || signatures.isEmpty()) null
            else signatures[0].toByteArray()
        } catch (t: Throwable) { null }
    }

    private fun installApk(path: String): Boolean {
        return try {
            val file = java.io.File(path)
            if (!file.exists()) return false
            val uri = androidx.core.content.FileProvider.getUriForFile(
                applicationContext, packageName + ".fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(uri, "application/vnd.android.package-archive")
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (t: Throwable) { false }
    }

    // JNI 桥（SO 提供）
    private external fun nativeSetSignatureHash(hex64: String)

    private fun verifySignature(): Boolean {
        return try {
            val pm = applicationContext.packageManager
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                info.signatures
            }
            if (signatures == null || signatures.isEmpty()) return false
            for (sig in signatures) {
                val md = MessageDigest.getInstance("SHA-256")
                val digest = md.digest(sig.toByteArray())
                val hex = digest.joinToString("") { "%02x".format(it) }
                if (hex.uppercase() in EXPECTED) return true
            }
            false
        } catch (t: Throwable) { false }
    }
}
'''
    code = code.replace('__EXPECTED_SHA__', EXPECTED_HEX)
    open(path, 'w', encoding='utf-8').write(code)
    print('MainActivity signature guard + install channel injected')


if __name__ == '__main__':
    main()