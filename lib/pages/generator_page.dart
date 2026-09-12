import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../mail_api.dart';
import '../native_bridge.dart';
import '../update_service.dart';

/// Tab1: 生成邮箱（随机/自定义）
class GeneratorPage extends StatefulWidget {
  final String? addr;
  final String? token;
  final ValueChanged<String> onAddressCreated;
  const GeneratorPage({
    super.key,
    required this.addr,
    required this.token,
    required this.onAddressCreated,
  });

  @override
  State<GeneratorPage> createState() => _GeneratorPageState();
}

class _GeneratorPageState extends State<GeneratorPage> {
  final _customCtrl = TextEditingController();
  String? _selectedDomain;

  @override
  void initState() {
    super.initState();
    final pool = NativeCore.instance.domainPool();
    _selectedDomain = pool.isNotEmpty ? pool.first : 'eri.kdns.fr';
  }

  void _genRandom() {
    final local = NativeCore.instance.randLocal();
    final addr = '$local@$_selectedDomain';
    widget.onAddressCreated(addr);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已生成: $addr')),
    );
  }

  void _useCustom() {
    final local = _customCtrl.text.trim().toLowerCase();
    if (local.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入邮箱前缀')),
      );
      return;
    }
    if (!RegExp(r'^[a-z0-9._-]{2,20}$').hasMatch(local)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('前缀规则: 2-20位小写字母/数字/._-')),
      );
      return;
    }
    final addr = '$local@$_selectedDomain';
    widget.onAddressCreated(addr);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换到: $addr')),
    );
  }

  void _copy() {
    if (widget.addr == null) return;
    Clipboard.setData(ClipboardData(text: widget.addr!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pool = NativeCore.instance.domainPool();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 当前邮箱卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前邮箱', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                SelectableText(
                  widget.addr ?? '（未生成）',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy),
                  label: const Text('复制地址'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 随机生成
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('随机邮箱', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('选域名后一键生成随机前缀，无需创建，邮件到达即缓冲',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final d in pool)
                      ChoiceChip(
                        label: Text(d),
                        selected: _selectedDomain == d,
                        onSelected: (_) => setState(() => _selectedDomain = d),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _genRandom,
                  child: const Text('生成随机邮箱'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 自定义
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('自定义邮箱', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('输入前缀，配合上方域名使用',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                TextField(
                  controller: _customCtrl,
                  decoration: InputDecoration(
                    hintText: '例如 eri01',
                    border: const OutlineInputBorder(),
                    suffixText: '@$_selectedDomain',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9._-]')),
                  ],
                  onSubmitted: (_) => _useCustom(),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: _useCustom,
                  child: const Text('使用该邮箱'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 关于页：作者 + 原生核心状态 + 检查更新 + 赞赏码
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  /// 手动检查更新：清掉已见标记强制走一遍检测流程，
  /// 分身/隔离空间里失败会直接弹出原因（不再静默）
  Future<void> _manualCheck(BuildContext context) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove('tm_seen_canary');
    } catch (_) {}
    if (!context.mounted) return;
    final prompted = await UpdateService.instance.checkAndPrompt(context, manual: true);
    if (!prompted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前已是最新版本')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final native = NativeCore.instance.nativeVersion();
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 16),
          Center(
            child: Text('作者: eri',
                style: Theme.of(context).textTheme.headlineSmall),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              native == null ? 'native core: 未加载（降级模式）' : 'native core: v$native',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton.icon(
              onPressed: () => _manualCheck(context),
              icon: const Icon(Icons.system_update_alt),
              label: const Text('检查更新'),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text('觉得有用可以请作者喝一杯',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/donate_qr.png',
                      width: 220,
                      fit: BoxFit.contain,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
