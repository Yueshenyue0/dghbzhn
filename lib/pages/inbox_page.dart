import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../mail_api.dart';

/// Tab2: 收件箱（5s 自动刷新 + 卡片列表）
class InboxPage extends StatefulWidget {
  final String? addr;
  final String? token;
  final VoidCallback? goGenerate;
  const InboxPage({
    super.key,
    required this.addr,
    required this.token,
    this.goGenerate,
  });

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  List<Map<String, dynamic>> _emails = [];
  bool _loading = false;
  String? _error;
  Timer? _timer;
  DateTime? _lastFetch;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final addr = widget.addr;
    if (addr == null || addr.isEmpty) return;
    if (_loading) return;
    _loading = true;
    final d = await MailApi.instance.waitInbox(addr, token: widget.token);
    _loading = false;
    if (!mounted) return;
    setState(() {
      if (d['_status'] == 200) {
        final list = d['emails'];
        _emails = list is List
            ? list.whereType<Map<String, dynamic>>().toList()
            : [];
        _error = null;
        _lastFetch = DateTime.now();
      } else if (d['_status'] == 0) {
        _error = '网络异常';
      } else if (d['_status'] == 204) {
        _error = null;
      } else if (d['_status'] == 401) {
        _error = '认证失败，请检查 token';
      } else {
        _error = '错误 ${d['_status']}: ${d['error'] ?? ''}';
      }
    });
  }

  Widget _buildEmailCard(Map<String, dynamic> em) {
    final subject = (em['subject'] as String?) ?? '(无主题)';
    final fromName = (em['from_name'] as String?) ?? '';
    final from = fromName.isNotEmpty
        ? fromName
        : ((em['from_email'] as String?) ?? '?');
    final preview = ((em['preview_text'] as String?) ?? '').trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        title: Text(subject,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('$from\n$preview',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        isThreeLine: true,
        onTap: () => _openDetail(em),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.addr == null || widget.addr!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox, size: 64, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('还没有邮箱'),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: widget.goGenerate,
              child: const Text('去生成'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: _emails.isEmpty
          ? ListView(
              children: [
                SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : Text(_error ?? '暂无邮件，5 秒后自动刷新'),
                ),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _emails.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  if (_lastFetch == null) return const SizedBox.shrink();
                  final t = _lastFetch!;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '更新于 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return _buildEmailCard(_emails[i - 1]);
              },
            ),
    );
  }

  void _openDetail(Map<String, dynamic> em) {
    final id = em['id']?.toString() ?? '';
    if (id.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmailDetailPage(emailId: id, token: widget.token),
      ),
    );
  }
}

/// 兼容不同字段名的取值
String? _field(Map<String, dynamic> d, List<String> names) {
  for (final n in names) {
    final v = d[n];
    if (v != null && v.toString().isNotEmpty) return v.toString();
  }
  return null;
}

/// 邮件详情页：WebView 渲染 HTML 正文
class EmailDetailPage extends StatefulWidget {
  final String emailId;
  final String? token;
  const EmailDetailPage(
      {super.key, required this.emailId, required this.token});

  @override
  State<EmailDetailPage> createState() => _EmailDetailPageState();
}

class _EmailDetailPageState extends State<EmailDetailPage> {
  Map<String, dynamic>? _detail;
  String? _error;
  WebViewController? _webCtrl;
  bool _useHtmlView = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d =
        await MailApi.instance.emailDetail(widget.emailId, token: widget.token);
    if (!mounted) return;
    setState(() {
      if (d['_status'] == 200) {
        _detail = d;
        _error = null;
        _initWeb(d);
      } else {
        _error = '加载失败: ${d['error'] ?? d['_status']}';
      }
    });
  }

  void _initWeb(Map<String, dynamic> d) {
    final html = _field(d, ['html_body', 'html']);
    final text = _field(d, ['text_body', 'text']);
    String body;
    if (html != null && html.trim().isNotEmpty) {
      body = html;
    } else if (text != null && text.trim().isNotEmpty) {
      body =
          '<pre style="white-space:pre-wrap;word-break:break-word;'
          'font-family:sans-serif;font-size:15px;color:#1a1a1a;margin:0;">'
          '${_escapeHtml(text)}</pre>';
    } else {
      return;
    }
    final page = _wrapDocument(body);
    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          final url = req.url;
          if (url.startsWith('http://') || url.startsWith('https://')) {
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadHtmlString(page, baseUrl: 'https://mail.cx');
    setState(() => _webCtrl = ctrl);
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _wrapDocument(String body) {
    return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html,body{margin:0;padding:0;background:#ffffff;}
  body{font-family:sans-serif;-webkit-text-size-adjust:100%;}
  img{max-width:100%!important;height:auto;}
  table{max-width:100%!important;}
  a{color:#1565C0;}
</style>
</head><body>$body</body></html>''';
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除邮件'),
        content: const Text('确定删除这封邮件？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final d = await MailApi.instance
        .deleteEmail(widget.emailId, token: widget.token);
    if (!mounted) return;
    if (d['_status'] == 200 || d['_status'] == 204) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: ${d['error'] ?? d['_status']}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    return Scaffold(
      appBar: AppBar(
        title: const Text('邮件详情'),
        actions: [
          if (d != null && _webCtrl != null)
            IconButton(
              icon: const Icon(Icons.text_fields),
              tooltip: '纯文本视图',
              onPressed: () => setState(() => _useHtmlView = !_useHtmlView),
            ),
          IconButton(
              icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_field(d, ['subject']) ?? '(无主题)',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          Text(
                              'From: ${_field(d, [
                                    'from',
                                    'from_name',
                                    'from_email'
                                  ]) ?? '?'}',
                              style: Theme.of(context).textTheme.bodySmall),
                          Text(
                              'To: ${_field(d, ['to', 'to_email']) ?? '?'}',
                              style: Theme.of(context).textTheme.bodySmall),
                          Text(
                              'Date: ${_field(d, [
                                    'date',
                                    'created_at'
                                  ]) ?? '?'}',
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _useHtmlView && _webCtrl != null
                          ? WebViewWidget(controller: _webCtrl!)
                          : _plainTextBody(d),
                    ),
                  ],
                ),
    );
  }

  Widget _plainTextBody(Map<String, dynamic> d) {
    final text = _field(d, ['text_body', 'text']);
    if (text != null && text.isNotEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(text),
      );
    }
    final html = _field(d, ['html_body', 'html']);
    if (html != null && html.isNotEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(_stripHtml(html)),
      );
    }
    return const Center(child: Text('(空正文)'));
  }

  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}