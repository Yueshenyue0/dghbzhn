import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'mail_api.dart';
import 'device_security.dart';
import 'pages/generator_page.dart';
import 'pages/inbox_page.dart';
import 'update_service.dart';

void main() {
  runApp(const TempMailApp());
}

class TempMailApp extends StatelessWidget {
  const TempMailApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TempMail',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1565C0), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  String? _token;
  String? _addr;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // 设备安全检测（最优先）
    final safe = await DeviceSecurity.check();
    if (!safe && mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('环境异常'),
            content: const Text('检测到 Root / Hook / Frida / 模拟器环境，为保护数据安全，应用将退出。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('退出'),
              ),
            ],
          ),
        ),
      );
      return; // 不继续初始化
    }

    final token = await MailApi.instance.loadToken();
    final addr = await MailApi.instance.loadAddress();
    if (!mounted) return;
    setState(() {
      _token = token;
      _addr = addr;
    });
    // 强制更新检查优先于捐赠弹窗
    final updating = await UpdateService.instance.checkAndPrompt(context);
    if (updating || !mounted) return;
    _maybeDonateDialog();
  }

  /// 第 3 次及以后每次启动弹捐赠提示
  Future<void> _maybeDonateDialog() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final launches = sp.getInt('tm_launch_count') ?? 0;
      await sp.setInt('tm_launch_count', launches + 1);
      if (launches + 1 < 3) return;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('希望可以给作者捐赠'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('开发不易，如果这个工具帮到了你，可以考虑请作者喝一杯'),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  'assets/donate_qr.png',
                  width: 200,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('下次再说'),
            ),
          ],
        ),
      );
    } catch (_) {}
  }

  void _setAddress(String addr) {
    setState(() => _addr = addr);
    MailApi.instance.saveAddress(addr);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_addr ?? 'TempMail'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '关于',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutPage()),
              );
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          GeneratorPage(
            addr: _addr,
            token: _token,
            onAddressCreated: _setAddress,
          ),
          InboxPage(
            addr: _addr,
            token: _token,
            goGenerate: () => setState(() => _tab = 0),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.alternate_email), label: '生成邮箱'),
          NavigationDestination(icon: Icon(Icons.inbox), label: '收件箱'),
        ],
      ),
    );
  }
}