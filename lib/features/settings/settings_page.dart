import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:curtain_mcp_flutter/core/config/app_config.dart';
import 'package:curtain_mcp_flutter/models/endpoint_model.dart';
import 'package:curtain_mcp_flutter/models/mcp_server_model.dart';
import 'package:curtain_mcp_flutter/services/connectivity_service.dart';
import 'package:curtain_mcp_flutter/services/skill_store.dart';
//import 'package:curtain_mcp_flutter/pages/skill_management_page.dart';
import 'package:curtain_mcp_flutter/features/skills/skill_select_page.dart';
import 'package:curtain_mcp_flutter/providers/skill_store_provider.dart';
import 'package:curtain_mcp_flutter/services/mcp_client_service.dart';
import 'package:curtain_mcp_flutter/services/chat_orchestrator.dart';
import 'package:curtain_mcp_flutter/services/ollama_service.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';
import 'package:curtain_mcp_flutter/features/cabinet/web_url_field.dart';
import 'package:curtain_mcp_flutter/features/chat/simple_style.dart';




// ① 改成 ConsumerStatefulWidget
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

// ② 改成 ConsumerState
class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final AppConfig           _config;
  late final ConnectivityService _connectivity;

  // 帳號與權限：登入結果訊息
  String? _authMessage;
  bool    _authOk = false;

  /// 工號登入／切換成管理者：直接送到 MCP Server，密碼不經過 AI
  Future<void> _showAuthDialog({required bool admin}) async {
    final idCtrl = TextEditingController();
    final pwCtrl = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(admin ? '切換成管理者' : '工號登入'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!admin) ...[
            TextField(
              controller: idCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '工號'),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: pwCtrl,
            obscureText: true,
            autofocus: admin,
            decoration: InputDecoration(labelText: admin ? '管理者密碼' : '密碼'),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 淺色主題把 FilledButton 設成滿版寬，這裡指定一般寬度
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(admin ? '切換' : '登入'),
          ),
        ],
      ),
    );
    final userId   = idCtrl.text.trim();
    final password = pwCtrl.text;
    if (submitted != true) return;
    if (password.isEmpty || (!admin && userId.isEmpty)) {
      setState(() {
        _authOk      = false;
        _authMessage = admin ? '請輸入管理者密碼' : '請輸入工號和密碼';
      });
      return;
    }
    try {
      final mcp = GetIt.instance<McpClientService>();
      final msg = admin
          ? await mcp.authAsync('/auth/admin', {'role': 'admin', 'password': password})
          : await mcp.authAsync('/auth/login', {'userId': userId, 'password': password});
      // 內嵌的系統櫃網頁用同一組工號密碼登入；只放記憶體，不寫入磁碟
      if (!admin) {
        GetIt.instance<WebSession>().rememberLogin(userId, password);
      }
      if (!mounted) return;
      setState(() {
        _authOk      = true;
        _authMessage = msg.replaceAll('**', '');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authOk      = false;
        _authMessage = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  // ── 重新連線（Ollama + MCP）────────────────────────────
  bool _isReconnecting = false;

  Future<void> _reconnectAll() async {
    if (_isReconnecting) return;
    setState(() => _isReconnecting = true);

    String msg;
    bool   ok = false;

    try {
      // ① 測試 Ollama
      final ollamaOk = await _connectivity.checkAndReturn();

      // ② 強制重新連線 MCP + 重載工具
      final chat   = GetIt.instance<ChatOrchestrator>();
      final result = await chat.reconnect();

      ok = ollamaOk && result.mcpOk;
      final mcpOff = !GetIt.instance<McpClientService>().hasEnabledServers;

      if (mcpOff) {
        ok  = ollamaOk;
        msg = ollamaOk
            ? '✅ AI 模型連線正常（未啟用 MCP Server，純對話模式）'
            : '❌ AI 模型無法連線（未啟用 MCP Server）';
      } else if (ollamaOk && result.mcpOk) {
        msg = '✅ 連線成功！已載入 ${result.toolCount} 個工具';
      } else if (!ollamaOk && result.mcpOk) {
        msg = '⚠️ MCP 已連線（${result.toolCount} 個工具），但 AI 模型無回應';
      } else if (ollamaOk && !result.mcpOk) {
        msg = '⚠️ AI 模型正常，但 MCP Server 無法連線';
      } else {
        msg = '❌ AI 模型與 MCP 均無法連線，請檢查設定';
      }
    } catch (e) {
      msg = '❌ 連線失敗：$e';
    } finally {
      setState(() => _isReconnecting = false);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  @override
  void initState() {
    super.initState();
    _config       = GetIt.instance<AppConfig>();
    _connectivity = GetIt.instance<ConnectivityService>();
    _config.addListener(_onConfigChanged);
  }

  void _onConfigChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _config.removeListener(_onConfigChanged);
    super.dispose();
  }

  // ── Ollama 端點 ───────────────────────────────────────
  Future<void> _showEndpointDialog({EndpointModel? editing}) async {
    final result = await showDialog<EndpointModel>(
      context: context,
      builder: (_) => _EndpointDialog(editing: editing),
    );
    if (result == null) return;
    if (editing == null) {
      await _config.addEndpoint(result);
    } else {
      await _config.updateEndpoint(result);
    }
  }

  Future<void> _deleteEndpoint(EndpointModel ep) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('刪除端點'),
        content: Text('確定要刪除「${ep.name}」嗎？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('刪除')),
        ],
      ),
    );
    if (ok == true) await _config.deleteEndpoint(ep.id);
  }

  Future<void> _testConnection(EndpointModel ep) async {
    final prev = _config.activeEndpoint;
    await _config.setActiveEndpoint(ep);
    final error = await GetIt.instance<OllamaService>().diagnoseAsync();
    final ok    = error == null;
    if (prev.id != ep.id) await _config.setActiveEndpoint(prev);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          ok ? Icons.check_circle_outline_rounded
              : Icons.error_outline_rounded,
          color: ok ? Colors.green : Theme.of(ctx).colorScheme.error,
          size: 36,
        ),
        title: Text(ok ? '${ep.name} 連線正常' : '${ep.name} 無法連線'),
        content: ok
            ? null
            : SizedBox(width: 360, child: Text(error)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('確定'),
          ),
        ],
      ),
    );
  }

  // ── MCP Server 清單 ───────────────────────────────────
  Future<void> _showMcpDialog({McpServerModel? editing}) async {
    final result = await showDialog<McpServerModel>(
      context: context,
      builder: (_) => _McpServerDialog(editing: editing),
    );
    if (result == null) return;
    if (editing == null) {
      await _config.addMcpServer(result);
    } else {
      await _config.updateMcpServer(result);
    }
  }

  Future<void> _deleteMcpServer(McpServerModel m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除 MCP Server'),
        content: Text('確定要刪除「${m.name}」嗎？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('刪除')),
        ],
      ),
    );
    if (ok == true) await _config.deleteMcpServer(m.id);
  }

  Future<void> _testMcpServer(McpServerModel m) async {
    final error = await GetIt.instance<McpClientService>().testServerAsync(m);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          error == null ? Icons.check_circle_outline_rounded
              : Icons.error_outline_rounded,
          color: error == null ? Colors.green : Theme.of(ctx).colorScheme.error,
          size: 36,
        ),
        title: Text(error == null ? '${m.name} 連線正常' : '${m.name} 無法連線'),
        content: SizedBox(
          width: 360,
          child: Text(error == null ? m.url : '$error\n${m.url}'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('確定'),
          ),
        ],
      ),
    );
  }

  // ── MCP / STT 編輯 Dialog ─────────────────────────────
  Future<void> _showServiceDialog({required bool isMcp}) async {
    final result = await showDialog<({String host, int port, String path})>(
      context: context,
      builder: (_) => _ServiceDialog(
        title:    isMcp ? 'MCP Server 設定' : 'STT Backend 設定',
        initHost: isMcp ? _config.mcpHost : _config.sttHost,
        initPort: isMcp ? _config.mcpPort : _config.sttPort,
        initPath: isMcp ? _config.mcpPath : _config.sttPath,
      ),
    );
    if (result == null) return;
    if (isMcp) {
      await _config.setMcp(
          host: result.host, port: result.port, path: result.path);
    } else {
      await _config.setStt(
          host: result.host, port: result.port, path: result.path);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(isMcp ? 'MCP 設定已儲存' : 'STT 設定已儲存'),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  void _goToSkillManagement() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SkillSelectPage()),
     // MaterialPageRoute(builder: (_) => const SkillManagementPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final endpoints = _config.endpoints;
    final activeId  = _config.activeEndpoint.id;
    final mcpServers = _config.mcpServers;

    // ③ 用 ref.watch 取得 SkillStore
    final skillStore = ref.watch(skillStoreProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [

          // ── 畫面風格（整個 App）────────────────────────
          _SectionCard(
            icon: Icons.palette_outlined,
            title: '畫面風格',
            children: [
              Text('整個 App 一起換顏色；簡易模式另外換成新的麥克風版面。「傳統」是原本的樣子。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              AnimatedBuilder(
                animation: Listenable.merge([AppStyle.style, AppStyle.mode]),
                builder: (_, __) => StylePicker(
                  style: AppStyle.style.value,
                  mode: AppStyle.mode.value,
                  onStyle: AppStyle.setStyle,
                  onMode: AppStyle.setMode,
                ),
              ),
            ],
          ).animate().fadeIn(delay: 50.ms).slideY(begin: 0.1),

          const SizedBox(height: 20),

          // ── ① Ollama 端點管理 ────────────────────────
          _SectionCard(
            icon: Icons.dns_outlined,
            title: 'AI 模型端點管理',
            trailing: IconButton(
              icon: const Icon(Icons.add_circle_outline_rounded),
              tooltip: '新增端點',
              onPressed: () => _showEndpointDialog(),
            ),
            children: [
              if (endpoints.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('尚無端點，請點右上角新增'),
                  ),
                )
              else
                ...endpoints.asMap().entries.map((entry) {
                  final i  = entry.key;
                  final ep = entry.value;
                  final isActive = ep.id == activeId;
                  return _EndpointTile(
                    ep:       ep,
                    isActive: isActive,
                    onSelect: () => _config.setActiveEndpoint(ep),
                    onEdit:   () => _showEndpointDialog(editing: ep),
                    onDelete: endpoints.length > 1
                        ? () => _deleteEndpoint(ep)
                        : null,
                    onTest:   () => _testConnection(ep),
                  ).animate().fadeIn(delay: (50 * i).ms);
                }),
            ],
          ).animate().fadeIn(delay: 100.ms).slideY(begin: 0.1),

          const SizedBox(height: 20),

          // ── ② MCP Server 設定 ────────────────────────
          _SectionCard(
            icon: Icons.hub_outlined,
            title: 'MCP Server 管理',
            trailing: IconButton(
              icon: const Icon(Icons.add_circle_outline_rounded),
              tooltip: '新增 MCP Server',
              onPressed: () => _showMcpDialog(),
            ),
            children: [
              if (mcpServers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text('尚無 MCP Server，目前為純對話模式'),
                  ),
                )
              else ...[
                ...mcpServers.map((m) => _McpServerTile(
                      server:   m,
                      onToggle: (v) => _config.setMcpServerEnabled(m.id, v),
                      onTest:   () => _testMcpServer(m),
                      onEdit:   () => _showMcpDialog(editing: m),
                      onDelete: () => _deleteMcpServer(m),
                    )),
                if (_config.enabledMcpServers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '全部關閉中：AI 只做純對話，不會連線 MCP',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isReconnecting ? null : _reconnectAll,
                  icon: _isReconnecting
                      ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.sync_rounded, size: 18),
                  label: Text(_isReconnecting ? '連線中...' : '重新連線'),
                ),
              ),
            ],
          ).animate().fadeIn(delay: 150.ms).slideY(begin: 0.1),

          const SizedBox(height: 20),

          // ── 帳號與權限（工號密碼直接送 MCP，不經過 AI）──
          _SectionCard(
            icon: Icons.badge_outlined,
            title: '帳號與權限',
            children: [
              Text('工號和密碼直接送到 MCP Server，不會經過 AI，也不會留在聊天紀錄。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => _showAuthDialog(admin: false),
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('工號登入'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => _showAuthDialog(admin: true),
                  icon: const Icon(Icons.admin_panel_settings_outlined, size: 18),
                  label: const Text('切換成管理者'),
                ),
              ]),
              if (_authMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _authMessage!,
                    style: TextStyle(
                        color: _authOk
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 20),

          // ── 系統櫃網頁（內嵌配置畫面）──
          const _SectionCard(
            icon: Icons.view_in_ar_rounded,
            title: '系統櫃網頁',
            children: [WebUrlField()],
          ),

          const SizedBox(height: 20),

          // ── ③ STT Backend 設定 ───────────────────────
          _SectionCard(
            icon: Icons.mic_external_on_outlined,
            title: 'STT Backend（語音辨識）',
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '編輯 STT 設定',
              onPressed: () => _showServiceDialog(isMcp: false),
            ),
            children: [
              // 語音辨識目前用手機／瀏覽器內建引擎，這組網址沒有被使用
              Text('目前語音辨識使用手機或瀏覽器內建的引擎，這裡的網址暫時沒有用到，不需要設定。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: 12),
              _ServiceInfoRow(
                label: 'URL',
                value: _config.sttBackendUrl,
                icon:  Icons.link_rounded,
              ),
              const SizedBox(height: 8),
              _ServiceInfoRow(
                label: 'IP',
                value: _config.sttHost,
                icon:  Icons.computer_outlined,
              ),
              const SizedBox(height: 8),
              _ServiceInfoRow(
                label: 'Port',
                value: _config.sttPort.toString(),
                icon:  Icons.electrical_services_outlined,
              ),
              const SizedBox(height: 8),
              _ServiceInfoRow(
                label: 'Path',
                value: _config.sttPath,
                icon:  Icons.route_outlined,
              ),
            ],
          ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.1),

          const SizedBox(height: 20),

          // ── ④ Skill 管理 ─────────────────────────────
          _SectionCard(
            icon: Icons.auto_awesome_outlined,
            title: 'Skill 管理',
            trailing: IconButton(
              icon: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
              tooltip: '管理 Skill',
              onPressed: _goToSkillManagement,
            ),
            children: [
              _ServiceInfoRow(
                label: '目前',
                value: '${skillStore.activeSkill.icon} ${skillStore.activeSkill.name}',
                icon:  Icons.auto_awesome_outlined,
              ),
              const SizedBox(height: 8),
              _ServiceInfoRow(
                label: '共',
                value: '${skillStore.skills.length} 個 Skill（含內建）',
                icon:  Icons.list_alt_rounded,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _goToSkillManagement,
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('管理 / 新增 Skill'),
                ),
              ),
            ],
          ).animate().fadeIn(delay: 225.ms).slideY(begin: 0.1),

          const SizedBox(height: 20),

          // ── ⑤ 語音操作說明 ───────────────────────────
          _SectionCard(
            icon: Icons.mic_outlined,
            title: '語音操作說明',
            children: [
              _TipRow(icon: Icons.touch_app_rounded,
                  color: theme.colorScheme.primary,
                  text: '長按麥克風按鈕開始說話'),
              const SizedBox(height: 10),
              _TipRow(icon: Icons.pan_tool_alt_outlined,
                  color: Colors.orange,
                  text: '放開按鈕，語音自動送出'),
              const SizedBox(height: 10),
              _TipRow(icon: Icons.keyboard_rounded,
                  color: Colors.green,
                  text: '也可以直接打字輸入'),
              const SizedBox(height: 10),
              _TipRow(icon: Icons.volume_up_rounded,
                  color: Colors.purple,
                  text: 'AI 回覆會自動朗讀'),
            ],
          ).animate().fadeIn(delay: 250.ms).slideY(begin: 0.1),

          const SizedBox(height: 20),

          // ── ⑥ 關於 ──────────────────────────────────
          _SectionCard(
            icon: Icons.info_outline_rounded,
            title: '關於',
            children: [
              _InfoRow(label: '版本', value: 'v1.0.0'),
              const SizedBox(height: 8),
              _InfoRow(label: '技術', value: 'Flutter + Ollama + MCP'),
            ],
          ).animate().fadeIn(delay: 300.ms).slideY(begin: 0.1),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════
// MCP / STT 編輯 Dialog
// ════════════════════════════════════════════════════════
class _ServiceDialog extends StatefulWidget {
  final String title;
  final String initHost;
  final int    initPort;
  final String initPath;

  const _ServiceDialog({
    required this.title,
    required this.initHost,
    required this.initPort,
    required this.initPath,
  });

  @override
  State<_ServiceDialog> createState() => _ServiceDialogState();
}

class _ServiceDialogState extends State<_ServiceDialog> {
  final _formKey  = GlobalKey<FormState>();
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _pathCtrl;

  @override
  void initState() {
    super.initState();
    _hostCtrl = TextEditingController(text: widget.initHost);
    _portCtrl = TextEditingController(text: widget.initPort.toString());
    _pathCtrl = TextEditingController(text: widget.initPath);
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, (
    host: _hostCtrl.text.trim(),
    port: int.tryParse(_portCtrl.text.trim()) ?? widget.initPort,
    path: _pathCtrl.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _hostCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'IP / 主機',
                hintText: '192.168.1.100',
                prefixIcon: Icon(Icons.computer_outlined),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
              v == null || v.trim().isEmpty ? '請輸入 IP' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _portCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '連接埠',
                hintText: '5000',
                prefixIcon: Icon(Icons.electrical_services_outlined),
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n < 1 || n > 65535) {
                  return '請輸入有效 Port（1–65535）';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pathCtrl,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Path',
                hintText: '/mcp',
                prefixIcon: Icon(Icons.route_outlined),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
              v == null || v.trim().isEmpty ? '請輸入 Path' : null,
            ),
            const SizedBox(height: 16),
            // 預覽 URL
            ValueListenableBuilder(
              valueListenable: _hostCtrl,
              builder: (_, __, ___) => Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  Icon(Icons.link_rounded,
                      size: 14,
                      color: Theme.of(context).colorScheme.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'http://${_hostCtrl.text}:${_portCtrl.text}${_pathCtrl.text}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.save_outlined),
          label: const Text('儲存'),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════
// Ollama 端點 Tile
// ════════════════════════════════════════════════════════
class _EndpointTile extends StatelessWidget {
  final EndpointModel ep;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;
  final VoidCallback onTest;

  const _EndpointTile({
    required this.ep,
    required this.isActive,
    required this.onSelect,
    required this.onEdit,
    this.onDelete,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: isActive ? 2 : 1,
        ),
        color: isActive
            ? theme.colorScheme.primaryContainer.withOpacity(0.3)
            : null,
      ),
      child: ListTile(
        contentPadding:
        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            isActive
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: isActive
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurface,
            size: 20,
          ),
        ),
        title: Row(children: [
          // 名稱要能縮（Flexible + 省略號），不然手機窄螢幕上和「使用中」標籤加起來會超出寬度
          Flexible(
            child: Text(ep.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          if (isActive) ...[
            const SizedBox(width: 8),
            Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('使用中',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onPrimary)),
            ),
          ],
        ]),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text('${ep.provider.label}・${ep.baseUrl}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            Text('模型：${ep.model}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            if (ep.isOpenAi)
              Text(ep.samplingSummary,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.wifi_find_rounded, size: 20),
              tooltip: '測試連線',
              onPressed: onTest,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: '編輯',
              onPressed: onEdit,
            ),
            if (onDelete != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.delete_outline_rounded,
                    size: 20, color: theme.colorScheme.error),
                tooltip: '刪除',
                onPressed: onDelete,
              ),
          ],
        ),
        onTap: isActive ? null : onSelect,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════
// Ollama 端點 Dialog
// ════════════════════════════════════════════════════════
class _EndpointDialog extends StatefulWidget {
  final EndpointModel? editing;
  const _EndpointDialog({this.editing});
  @override
  State<_EndpointDialog> createState() => _EndpointDialogState();
}

class _EndpointDialogState extends State<_EndpointDialog> {
  final _formKey    = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _urlCtrl;     // OpenAI 相容：完整 Base URL
  late final TextEditingController _apiKeyCtrl;  // OpenAI 相容：API Key
  late final TextEditingController _maxTokensCtrl;
  late LlmProvider _provider;
  bool _showApiKey = false;
  late double _temperature;
  late bool _sendTemperature;
  late double _topP;
  late bool _sendTopP;
  late OpenAiProfile _profile;
  String? _reasoningEffort;
  String? _verbosity;
  bool? _enableThinking;

  bool get _isOpenAi => _provider == LlmProvider.openai;

  @override
  void initState() {
    super.initState();
    final ep    = widget.editing;
    _provider   = ep?.provider ?? LlmProvider.ollama;
    _nameCtrl   = TextEditingController(text: ep?.name  ?? '');
    _hostCtrl   = TextEditingController(text: ep?.host  ?? '192.168.1.');
    _portCtrl   = TextEditingController(
        text: ep?.port.toString() ?? '11434');
    _modelCtrl  = TextEditingController(
        text: ep?.model ?? AppConfig.ollamaModel);
    _urlCtrl    = TextEditingController(
        text: ep != null && ep.isOpenAi
            ? ep.baseUrl
            : 'https://api.openai.com/v1');
    _apiKeyCtrl = TextEditingController(text: ep?.apiKey ?? '');
    _temperature     = ep?.temperature ?? 0.1;
    _sendTemperature = ep?.sendTemperature ?? true;
    _topP            = ep?.topP ?? 1;
    _sendTopP        = ep?.topP != null;
    _maxTokensCtrl   = TextEditingController(
        text: ep?.maxTokens?.toString() ?? '');
    _profile         = ep?.profile ?? OpenAiProfile.generic;
    _reasoningEffort = ep?.reasoningEffort;
    _verbosity       = ep?.verbosity;
    _enableThinking  = ep?.enableThinking;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _modelCtrl.dispose();
    _urlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _maxTokensCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final id = widget.editing?.id ??
        DateTime.now().millisecondsSinceEpoch.toString();

    final EndpointModel ep;
    if (_isOpenAi) {
      final parsed = EndpointModel.parseBaseUrl(_urlCtrl.text)!;
      ep = EndpointModel(
        id:       id,
        name:     _nameCtrl.text.trim(),
        host:     parsed.host,
        port:     parsed.port,
        path:     parsed.path,
        useHttps: parsed.useHttps,
        model:    _modelCtrl.text.trim(),
        provider: LlmProvider.openai,
        apiKey:   _apiKeyCtrl.text.trim(),
        temperature:     _temperature,
        sendTemperature: _sendTemperature,
        topP:            _sendTopP ? _topP : null,
        maxTokens:       int.tryParse(_maxTokensCtrl.text.trim()),
        profile:         _profile,
        reasoningEffort: _reasoningEffort,
        verbosity:       _verbosity,
        enableThinking:  _enableThinking,
      );
    } else {
      ep = EndpointModel(
        id:    id,
        name:  _nameCtrl.text.trim(),
        host:  _hostCtrl.text.trim(),
        port:  int.tryParse(_portCtrl.text.trim()) ?? 11434,
        model: _modelCtrl.text.trim(),
      );
    }
    Navigator.pop(context, ep);
  }

  List<Widget> _samplingFields() {
    final theme = Theme.of(context);
    final gpt = _profile == OpenAiProfile.gpt;
    String fmt(double n) =>
        n.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return [
      const SizedBox(height: 20),
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<OpenAiProfile>(
          segments: OpenAiProfile.values
              .map((p) => ButtonSegment(value: p, label: Text(p.label)))
              .toList(),
          selected: {_profile},
          onSelectionChanged: (s) => setState(() => _profile = s.first),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          gpt
              ? '送給 OpenAI GPT。上限用 max_completion_tokens，思考力度和詳略只有這邊會送。'
              : '送給 NVIDIA、LM Studio、vLLM。上限用 max_tokens，思考開關只有這邊會送。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('送出溫度 ${fmt(_temperature)}'),
        subtitle: const Text('0 最固定，2 最隨機。查訂單建議 0～0.3'),
        value: _sendTemperature,
        onChanged: (v) => setState(() => _sendTemperature = v),
      ),
      Slider(
        min: 0,
        max: 2,
        divisions: 20,
        label: fmt(_temperature),
        value: _temperature,
        onChanged: _sendTemperature
            ? (v) => setState(() => _temperature = v)
            : null,
      ),
      if (!gpt) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('送出 top_p ${fmt(_topP)}'),
          subtitle: const Text('候選字的寬度。有送溫度時保持關閉'),
          value: _sendTopP,
          onChanged: (v) => setState(() => _sendTopP = v),
        ),
        Slider(
          min: 0,
          max: 1,
          divisions: 20,
          label: fmt(_topP),
          value: _topP,
          onChanged: _sendTopP ? (v) => setState(() => _topP = v) : null,
        ),
      ],
      const SizedBox(height: 8),
      TextFormField(
        controller: _maxTokensCtrl,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: '輸出上限（留空＝不送）',
          hintText: '1024',
          helperText: gpt
              ? '寫進 max_completion_tokens，思考 token 也算在內'
              : '寫進 max_tokens，思考和回答共用',
          prefixIcon: const Icon(Icons.short_text_rounded),
          border: const OutlineInputBorder(),
        ),
        validator: (v) {
          final t = v?.trim() ?? '';
          if (t.isEmpty) return null;
          final n = int.tryParse(t);
          if (n == null || n < 1 || n > 65536) return '請輸入 1–65536，或留空';
          return null;
        },
      ),
      if (gpt) ...[
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: const ValueKey('reasoning'),
          initialValue: _reasoningEffort ?? '',
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '思考力度',
            helperText: 'GPT-6 Luna 有工具時只能是 none，程式會自動改成 none',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('不送出')),
            ...EndpointModel.reasoningEfforts.map(
              (e) => DropdownMenuItem(value: e, child: Text(e)),
            ),
          ],
          onChanged: (v) => setState(
              () => _reasoningEffort = (v == null || v.isEmpty) ? null : v),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: const ValueKey('verbosity'),
          initialValue: _verbosity ?? '',
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '回答詳略',
            helperText: '語音回覆可選 low',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('不送出')),
            ...EndpointModel.verbosities.map(
              (e) => DropdownMenuItem(value: e, child: Text(e)),
            ),
          ],
          onChanged: (v) =>
              setState(() => _verbosity = (v == null || v.isEmpty) ? null : v),
        ),
      ] else ...[
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: const ValueKey('thinking'),
          initialValue: switch (_enableThinking) {
            null => '',
            true => 'on',
            false => 'off',
          },
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '思考模式',
            helperText: 'NVIDIA Bolt 的 enable_thinking',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: '', child: Text('不送出（伺服器預設）')),
            DropdownMenuItem(value: 'on', child: Text('開啟')),
            DropdownMenuItem(value: 'off', child: Text('關閉')),
          ],
          onChanged: (v) => setState(() => _enableThinking = switch (v) {
                'on' => true,
                'off' => false,
                _ => null,
              }),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.editing != null;
    return AlertDialog(
      title: Text(isEdit ? '編輯端點' : '新增端點'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // ── 協定選擇 ──────────────────────────────
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<LlmProvider>(
                segments: LlmProvider.values
                    .map((p) => ButtonSegment(value: p, label: Text(p.label)))
                    .toList(),
                selected: {_provider},
                onSelectionChanged: (s) =>
                    setState(() => _provider = s.first),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '名稱',
                hintText: '例：辦公室、家裡',
                prefixIcon: Icon(Icons.label_outline_rounded),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
              v == null || v.trim().isEmpty ? '請輸入名稱' : null,
            ),
            const SizedBox(height: 16),
            if (_isOpenAi) ...[
              TextFormField(
                controller: _urlCtrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'https://api.openai.com/v1',
                  helperText: '例：http://IP:1234/v1',
                  prefixIcon: Icon(Icons.link_rounded),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final p = EndpointModel.parseBaseUrl(v ?? '');
                  if (p == null) return '請輸入完整網址（含 http:// 或 https://）';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _apiKeyCtrl,
                autocorrect: false,
                obscureText: !_showApiKey,
                decoration: InputDecoration(
                  labelText: 'API Key（可留空）',
                  hintText: 'sk-...',
                  prefixIcon: const Icon(Icons.key_outlined),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_showApiKey
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    onPressed: () =>
                        setState(() => _showApiKey = !_showApiKey),
                  ),
                ),
              ),
            ] else ...[
              TextFormField(
                controller: _hostCtrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'IP / 主機',
                  hintText: '192.168.1.100',
                  prefixIcon: Icon(Icons.computer_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                v == null || v.trim().isEmpty ? '請輸入 IP' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _portCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '連接埠',
                  hintText: '11434',
                  prefixIcon: Icon(Icons.electrical_services_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  if (n == null || n < 1 || n > 65535) {
                    return '請輸入有效 Port（1–65535）';
                  }
                  return null;
                },
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _modelCtrl,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'AI 模型',
                hintText: _isOpenAi ? 'gpt-4o-mini' : 'qwen2.5:7b',
                prefixIcon: Icon(Icons.psychology_outlined),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
              v == null || v.trim().isEmpty ? '請輸入模型名稱' : null,
            ),
            if (_isOpenAi) ..._samplingFields(),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(isEdit ? Icons.save_outlined : Icons.add_rounded),
          label: Text(isEdit ? '儲存' : '新增'),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════
// MCP Server Tile（含開關）
// ════════════════════════════════════════════════════════
class _McpServerTile extends StatelessWidget {
  final McpServerModel server;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _McpServerTile({
    required this.server,
    required this.onToggle,
    required this.onTest,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on    = server.enabled;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: on ? 1 : 0.55,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: on ? 2 : 1,
          ),
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 4),
          title: Text(server.name,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          subtitle: Text(server.url,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.wifi_find_rounded, size: 20),
                tooltip: '測試連線',
                onPressed: onTest,
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: '編輯',
                onPressed: onEdit,
              ),
              IconButton(
                icon: Icon(Icons.delete_outline_rounded,
                    size: 20, color: theme.colorScheme.error),
                tooltip: '刪除',
                onPressed: onDelete,
              ),
              Switch(value: on, onChanged: onToggle),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════
// MCP Server Dialog
// ════════════════════════════════════════════════════════
class _McpServerDialog extends StatefulWidget {
  final McpServerModel? editing;
  const _McpServerDialog({this.editing});
  @override
  State<_McpServerDialog> createState() => _McpServerDialogState();
}

class _McpServerDialogState extends State<_McpServerDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;

  @override
  void initState() {
    super.initState();
    final m   = widget.editing;
    _keyCtrl  = TextEditingController(text: m?.apiKey ?? '');
    _nameCtrl = TextEditingController(text: m?.name ?? '');
    _urlCtrl  = TextEditingController(
        text: m?.url ?? 'http://192.168.1.:5000/mcp');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final base = widget.editing;
    final m = McpServerModel(
      id:      base?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name:    _nameCtrl.text.trim(),
      url:     _urlCtrl.text.trim(),
      enabled: base?.enabled ?? true,
      apiKey:  _keyCtrl.text.trim(),
    );
    Navigator.pop(context, m);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.editing != null;
    return AlertDialog(
      title: Text(isEdit ? '編輯 MCP Server' : '新增 MCP Server'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '名稱',
                hintText: '例：訂單系統、庫存系統',
                prefixIcon: Icon(Icons.label_outline_rounded),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? '請輸入名稱' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'MCP URL',
                hintText: 'http://127.0.0.1:1987/mcp',
                prefixIcon: Icon(Icons.link_rounded),
                border: OutlineInputBorder(),
              ),
              validator: (v) => McpServerModel.isValidUrl(v ?? '')
                  ? null
                  : '請輸入完整網址（含 http:// 或 https://）',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _keyCtrl,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Proxy Key（選填）',
                hintText: '經網站 /mcp-proxy 連線時填',
                prefixIcon: Icon(Icons.key_rounded),
                border: OutlineInputBorder(),
              ),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(isEdit ? Icons.save_outlined : Icons.add_rounded),
          label: Text(isEdit ? '儲存' : '新增'),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════
// 共用小元件
// ════════════════════════════════════════════════════════
class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  final List<Widget> children;

  const _SectionCard({
    required this.icon,
    required this.title,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              if (trailing != null) trailing!,
            ]),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ServiceInfoRow extends StatelessWidget {
  final String label, value;
  final IconData icon;
  const _ServiceInfoRow({
    required this.label,
    required this.value,
    required this.icon,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Icon(icon, size: 16, color: theme.colorScheme.outline),
      const SizedBox(width: 8),
      Text('$label：',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline)),
      Expanded(
        child: Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
            fontFamily: label == 'URL' ? 'monospace' : null,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]);
  }
}

class _TipRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _TipRow(
      {required this.icon, required this.color, required this.text});
  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, size: 22, color: color),
    const SizedBox(width: 12),
    Expanded(
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(height: 1.4))),
  ]);
}

class _InfoRow extends StatelessWidget {
  final String label, value;
  const _InfoRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Text('$label：',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.outline)),
      Text(value,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w500)),
    ]);
  }
}
