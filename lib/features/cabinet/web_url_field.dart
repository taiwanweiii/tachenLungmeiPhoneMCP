import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import '../../services/web_session.dart';

/// 設定頁用：系統櫃網頁位址（內嵌 WebView 會開這個網站）。
class WebUrlField extends StatefulWidget {
  const WebUrlField({super.key});

  @override
  State<WebUrlField> createState() => _WebUrlFieldState();
}

class _WebUrlFieldState extends State<WebUrlField> {
  late final TextEditingController _ctrl;
  final _session = GetIt.instance<WebSession>();
  String? _msg;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _session.baseUrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final u = _ctrl.text.trim();
    final uri = Uri.tryParse(u);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http') || uri.host.isEmpty) {
      setState(() => _msg = '請輸入完整網址，例如 https://p3dweb.lungmeifurniture.com');
      return;
    }
    await _session.setBaseUrl(u);
    if (!mounted) return;
    setState(() => _msg = '已儲存：${_session.baseUrl}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '內嵌的系統櫃配置畫面會開這個網站。測試時填開發機的位址（例如 https://192.168.1.50:30000）。'
          '登入沿用「帳號與權限」登入的工號密碼，只存在記憶體。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ctrl,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '網頁位址',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton.tonal(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: _save,
            child: const Text('儲存'),
          ),
          const SizedBox(width: 12),
          if (_msg != null)
            Expanded(child: Text(_msg!, style: theme.textTheme.bodySmall)),
        ]),
      ],
    );
  }
}
