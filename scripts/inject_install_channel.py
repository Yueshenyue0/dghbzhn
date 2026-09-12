#!/usr/bin/env python3
"""注入自定义 MainActivity.kt：仅提供应用内安装通道 installApk。

签名校验已按需求彻底移除，本文件不含任何 killProcess / PackageManager 逻辑。
幂等：已注入则跳过。
"""
import os

ACTIVITY_DIR = 'android/app/src/main/kotlin/com/eri/tempmail'


def main():
    os.makedirs(ACTIVITY_DIR, exist_ok=True)
    path = os.path.join(ACTIVITY_DIR, 'MainActivity.kt')
    if os.path.exists(path):
        src = open(path, encoding='utf-8').read()
        if 'INSTALL_CHANNEL' in src and 'killProcess' not in src:
            print('install channel already injected')
            return

    code = '''// INSTALL_CHANNEL: in-app APK installer (signature guard intentionally removed)
package com.eri.tempmail

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val INSTALL_CHANNEL = "com.eri.tempmail/install"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 应用内安装通道
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
    }

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

}
'''
    open(path, 'w', encoding='utf-8').write(code)
    print('MainActivity install channel injected (no signature guard)')


if __name__ == '__main__':
    main()