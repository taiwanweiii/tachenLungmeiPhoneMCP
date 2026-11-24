import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:get_it/get_it.dart';
import '../../services/ollama_service.dart';
import '../../services/mcp_client_service.dart';
import '../../services/chat_orchestrator.dart';
import '../../voice/voice_orchestrator.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});
  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  final List<_CheckItem> _checks = [];
  bool _hasError   = false;
  bool _isDone     = false; // 所有檢查跑完了

  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  Future<void> _runChecks() async {
    setState(() {
      _checks.clear();
      _hasError = false;
      _isDone   = false;
    });
    final sl = GetIt.instance;

    // ── 必要服務（失敗顯示警告，但不擋路）────────────────
    await _addCheck(
      '🔗 連線 AI 模型服務',
      isCritical: false,
          () async {
        final error = await sl<OllamaService>().diagnoseAsync();
        if (error != null) throw Exception(error);
      },
    );

    await _addCheck(
      '🔗 連線 MCP Server',
      isCritical: false,
          () async {
        final mcp = sl<McpClientService>();
        if (!mcp.hasEnabledServers) return; // 全部關閉 → 純對話，不連線
        final failed = (await mcp.checkAllAsync())
            .where((r) => r.error != null)
            .toList();
        if (failed.isNotEmpty) {
          throw Exception(
              failed.map((r) => '${r.server.name}：${r.error}').join('\n'));
        }
      },
    );

    await _addCheck(
      '🤖 初始化 AI 助理',
      isCritical: false,
          () async {
        await sl<ChatOrchestrator>().initializeAsync();
      },
    );

    // ── 語音（失敗完全不影響，ChatPage 有備援）───────────
    await _addCheck(
      '🎤 初始化語音模組',
      isCritical: false,
          () async {
        await sl<VoiceOrchestrator>().initialize();
      },
    );

    setState(() => _isDone = true);

    // 沒有任何錯誤 → 自動跳轉
    if (!_hasError && mounted) {
      await Future.delayed(const Duration(milliseconds: 800));
      _goToChat();
    }
    // 有錯誤 → 停在此頁，讓使用者選擇
  }

  void _goToChat() {
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/chat');
  }

  Future<void> _addCheck(
      String label,
      Future<void> Function() task, {
        bool isCritical = true,
      }) async {
    setState(() => _checks.add(
      _CheckItem(label: label, status: _Status.loading),
    ));
    try {
      await task();
      setState(() => _checks.last.status = _Status.success);
    } catch (e) {
      setState(() {
        _checks.last.status = _Status.error;
        _checks.last.error  =
            e.toString().replaceAll('Exception: ', '');
        if (isCritical) _hasError = true;
        // isCritical = false 時只標記 warning，不擋路
        if (!isCritical) _hasError = true; // 仍顯示按鈕讓使用者決定
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(           // ← 防止 overflow
          padding: const EdgeInsets.symmetric(
              horizontal: 36, vertical: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 24),

              // ── Logo ────────────────────────────────
              Container(
                width: 100, height: 100,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Icon(Icons.blinds_rounded,
                    size: 60, color: theme.colorScheme.primary),
              ).animate().scale(
                  duration: 600.ms, curve: Curves.elasticOut),

              const SizedBox(height: 24),
              Text('隆美系統櫃助理',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ).animate().fadeIn(delay: 300.ms),
              Text('CurtainMCP v1.0',
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline),
              ).animate().fadeIn(delay: 400.ms),

              const SizedBox(height: 56),

              // ── 檢查項目 ─────────────────────────────
              ..._checks.asMap().entries.map((e) =>
                  _CheckTile(item: e.value)
                      .animate()
                      .slideX(
                      begin: -0.3,
                      duration: 400.ms,
                      delay: (e.key * 100).ms)
                      .fadeIn(delay: (e.key * 100).ms),
              ),

              // ── 按鈕區（檢查跑完才顯示）──────────────
              if (_isDone && _hasError) ...[
                const SizedBox(height: 40),

                // 主要行動：略過直接進入
                FilledButton.icon(
                  onPressed: _goToChat,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('略過，直接進入'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                  ),
                ).animate().fadeIn(delay: 200.ms),

                const SizedBox(height: 12),

                // 次要行動：重新連線
                OutlinedButton.icon(
                  onPressed: _runChecks,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新連線'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                  ),
                ).animate().fadeIn(delay: 300.ms),

                const SizedBox(height: 12),

                // 第三選項：前往設定
                TextButton(
                  onPressed: () => Navigator.pushReplacementNamed(
                      context, '/settings'),
                  child: const Text('前往設定修改網址'),
                ).animate().fadeIn(delay: 400.ms),

                const SizedBox(height: 12),

                // 提示說明
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 16,
                          color: theme.colorScheme.onSecondaryContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '連線失敗時仍可使用文字輸入功能，\n語音功能待連線恢復後自動啟用。',
                          style: TextStyle(
                            fontSize: 12,
                            color:
                            theme.colorScheme.onSecondaryContainer,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ).animate().fadeIn(delay: 500.ms),
              ],

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ── CheckTile ─────────────────────────────────────────────
class _CheckTile extends StatelessWidget {
  final _CheckItem item;
  const _CheckTile({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 28, height: 28,
          child: switch (item.status) {
            _Status.loading => CircularProgressIndicator(
                strokeWidth: 2.5,
                color: theme.colorScheme.primary),
            _Status.success => Icon(Icons.check_circle_rounded,
                color: Colors.green.shade600, size: 28),
            _Status.error => Icon(Icons.error_rounded,
                color: theme.colorScheme.error, size: 28),
          },
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.label,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w500)),
                if (item.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      item.error!,
                      style: TextStyle(
                          color: theme.colorScheme.error,
                          fontSize: 12,
                          height: 1.4),
                    ),
                  ),
              ]),
        ),
      ]),
    );
  }
}

enum _Status { loading, success, error }

class _CheckItem {
  String label;
  _Status status;
  String? error;
  _CheckItem(
      {required this.label, required this.status, this.error});
}
