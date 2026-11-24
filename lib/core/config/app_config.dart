import 'dart:convert';                          // ← 新增這行
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/endpoint_model.dart';
import '../../models/mcp_server_model.dart';

/// 統一設定中心
/// 優先順序：SharedPreferences（使用者修改）> .env（預設值）
class AppConfig extends ChangeNotifier {

  // ── 常數 key ──────────────────────────────────────────
  static const String ollamaModel = 'qwen2.5:7b';

  static const _kEndpoints  = 'endpoints_v2';
  static const _kActiveId   = 'active_endpoint_id';
  static const _kMcpHost    = 'mcp_host';
  static const _kMcpPort    = 'mcp_port';
  static const _kMcpPath    = 'mcp_path';
  static const _kMcpServers = 'mcp_servers_v1';
  static const _kSttHost    = 'stt_host';
  static const _kSttPort    = 'stt_port';
  static const _kSttPath    = 'stt_path';

  // ── 內部狀態 ──────────────────────────────────────────
  late SharedPreferences _prefs;

  List<EndpointModel> _endpoints = [];
  String              _activeId  = '';

  // MCP
  String _mcpHost = '192.168.1.100';
  int    _mcpPort = 5000;
  String _mcpPath = '/mcp';
  List<McpServerModel> _mcpServers = [];

  // STT
  String _sttHost = '192.168.1.100';
  int    _sttPort = 5000;
  String _sttPath = '/api/stt';

  // ── 初始化 ────────────────────────────────────────────
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _loadMcpFromEnvIfNeeded();
    _loadSttFromEnvIfNeeded();
    await _loadEndpoints();
    await _loadMcpServers();
    // ↓↓↓ 加這幾行診斷 ↓↓↓
    debugPrint('=== AppConfig 初始化完成 ===');
    for (final m in _mcpServers) {
      debugPrint('MCP: ${m.name} ${m.url} ${m.enabled ? "ON" : "OFF"}');
    }
    debugPrint('STT URL: $sttBackendUrl');
    debugPrint('Ollama URL: $activeBaseUrl');
    debugPrint('SharedPrefs mcp_host: ${_prefs.getString(_kMcpHost)}');
    debugPrint('SharedPrefs mcp_port: ${_prefs.getInt(_kMcpPort)}');
  }

  void _loadMcpFromEnvIfNeeded() {
    final rawUrl = dotenv.maybeGet('MCP_BASE_URL') ?? 'http://127.0.0.1:1987/mcp';
    final parsed = _parseUrl(rawUrl);
    _mcpHost = _prefs.getString(_kMcpHost) ?? parsed.host;
    _mcpPort = _prefs.getInt(_kMcpPort)    ?? parsed.port;
    _mcpPath = _prefs.getString(_kMcpPath) ?? parsed.path;
  }

  void _loadSttFromEnvIfNeeded() {
    final rawUrl = dotenv.maybeGet('STT_BACKEND_URL') ?? 'http://192.168.1.100:5000/api/stt';
    final parsed = _parseUrl(rawUrl);
    _sttHost = _prefs.getString(_kSttHost) ?? parsed.host;
    _sttPort = _prefs.getInt(_kSttPort)    ?? parsed.port;
    _sttPath = _prefs.getString(_kSttPath) ?? parsed.path;
  }

  // ── Ollama 端點 Getters ───────────────────────────────
  List<EndpointModel> get endpoints  => List.unmodifiable(_endpoints);
  EndpointModel get activeEndpoint   => _endpoints.firstWhere(
        (e) => e.id == _activeId,
    orElse: () => _endpoints.first,
  );
  String get activeBaseUrl => activeEndpoint.baseUrl;
  String get activeModel   => activeEndpoint.model;

  // ── MCP Getters ───────────────────────────────────────
  String get mcpHost    => _mcpHost;
  int    get mcpPort    => _mcpPort;
  String get mcpPath    => _mcpPath;
  String get mcpBaseUrl => 'http://$_mcpHost:$_mcpPort$_mcpPath';

  // ── STT Getters ───────────────────────────────────────
  String get sttHost       => _sttHost;
  int    get sttPort       => _sttPort;
  String get sttPath       => _sttPath;
  String get sttBackendUrl => 'http://$_sttHost:$_sttPort$_sttPath';

  // ── Ollama 端點操作 ───────────────────────────────────
  Future<void> _loadEndpoints() async {
    final raw = _prefs.getStringList(_kEndpoints);
    if (raw != null && raw.isNotEmpty) {
      // ✅ 修正：每個 String → jsonDecode → Map → EndpointModel
      _endpoints = raw
          .map((s) => EndpointModel.fromJson(
        jsonDecode(s) as Map<String, dynamic>,
      ))
          .toList();
    } else {
      final url    = dotenv.maybeGet('OLLAMA_BASE_URL') ?? 'http://192.168.1.100:11434';
      final model  = dotenv.maybeGet('OLLAMA_MODEL')    ?? ollamaModel;
      // LLM_PROVIDER=ollama | openai；沒填時，網址含 /v1 視為 OpenAI 相容
      final providerEnv = dotenv.maybeGet('LLM_PROVIDER')?.trim().toLowerCase();
      final provider = providerEnv != null && providerEnv.isNotEmpty
          ? LlmProvider.fromName(providerEnv)
          : (Uri.tryParse(url)?.path.contains('/v1') ?? false)
              ? LlmProvider.openai
              : LlmProvider.ollama;

      final EndpointModel def;
      if (provider == LlmProvider.openai) {
        final p = EndpointModel.parseBaseUrl(url)!;
        def = EndpointModel(
          id:       'default',
          name:     '預設',
          host:     p.host,
          port:     p.port,
          path:     p.path,
          useHttps: p.useHttps,
          model:    model,
          provider: LlmProvider.openai,
          apiKey:   dotenv.maybeGet('LLM_API_KEY') ?? '',
        );
      } else {
        final parsed = _parseUrl(url);
        def = EndpointModel(
          id:    'default',
          name:  '預設',
          host:  parsed.host,
          port:  parsed.port,
          model: model,
        );
      }
      _endpoints = [def];
      await _saveEndpoints();
    }
    _activeId = _prefs.getString(_kActiveId) ?? _endpoints.first.id;
  }

  Future<void> _saveEndpoints() async {
    // ✅ 修正：每個 EndpointModel → toJson() → jsonEncode → String
    await _prefs.setStringList(
      _kEndpoints,
      _endpoints.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  Future<void> addEndpoint(EndpointModel ep) async {
    _endpoints.add(ep);
    await _saveEndpoints();
    notifyListeners();
  }

  Future<void> updateEndpoint(EndpointModel ep) async {
    final idx = _endpoints.indexWhere((e) => e.id == ep.id);
    if (idx != -1) _endpoints[idx] = ep;
    await _saveEndpoints();
    notifyListeners();
  }

  Future<void> deleteEndpoint(String id) async {
    _endpoints.removeWhere((e) => e.id == id);
    if (_activeId == id) {
      _activeId = _endpoints.first.id;
      await _prefs.setString(_kActiveId, _activeId);
    }
    await _saveEndpoints();
    notifyListeners();
  }

  Future<void> setActiveEndpoint(EndpointModel ep) async {
    _activeId = ep.id;
    await _prefs.setString(_kActiveId, ep.id);
    notifyListeners();
  }

  // ── MCP Server 清單（多台，各自有開關）──────────────
  List<McpServerModel> get mcpServers => List.unmodifiable(_mcpServers);
  List<McpServerModel> get enabledMcpServers =>
      _mcpServers.where((m) => m.enabled).toList();

  Future<void> _loadMcpServers() async {
    final raw = _prefs.getStringList(_kMcpServers);
    if (raw != null) {
      _mcpServers = raw
          .map((s) => McpServerModel.fromJson(
                jsonDecode(s) as Map<String, dynamic>,
              ))
          .toList();
      return;
    }
    // 第一次升級：把舊的單一 MCP 設定轉成清單第一筆
    // .env 的 MCP_BASE_URL 若是完整網址（含 https、網站代理路徑）就原樣使用，
    // 不然才用 host／port／path 拼成 http；MCP_PROXY_KEY 是走網站代理時的 X-Mcp-Proxy-Key
    final envUrl = (dotenv.maybeGet('MCP_BASE_URL') ?? '').trim();
    final useEnvUrl = _prefs.getString(_kMcpHost) == null &&
        McpServerModel.isValidUrl(envUrl);
    _mcpServers = [
      McpServerModel(
        id: 'default',
        name: '預設',
        url: useEnvUrl ? envUrl : mcpBaseUrl,
        apiKey: (dotenv.maybeGet('MCP_PROXY_KEY') ?? '').trim(),
      ),
    ];
    await _saveMcpServers();
  }

  Future<void> _saveMcpServers() async {
    await _prefs.setStringList(
      _kMcpServers,
      _mcpServers.map((m) => jsonEncode(m.toJson())).toList(),
    );
  }

  Future<void> addMcpServer(McpServerModel m) async {
    _mcpServers.add(m);
    await _saveMcpServers();
    notifyListeners();
  }

  Future<void> updateMcpServer(McpServerModel m) async {
    final idx = _mcpServers.indexWhere((e) => e.id == m.id);
    if (idx != -1) _mcpServers[idx] = m;
    await _saveMcpServers();
    notifyListeners();
  }

  Future<void> deleteMcpServer(String id) async {
    _mcpServers.removeWhere((e) => e.id == id);
    await _saveMcpServers();
    notifyListeners();
  }

  Future<void> setMcpServerEnabled(String id, bool enabled) async {
    final idx = _mcpServers.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    _mcpServers[idx] = _mcpServers[idx].copyWith(enabled: enabled);
    await _saveMcpServers();
    notifyListeners();
  }

  // ── MCP 設定操作（舊版單一設定，僅供升級轉換）─────────
  Future<void> setMcp({
    required String host,
    required int    port,
    required String path,
  }) async {
    _mcpHost = host;
    _mcpPort = port;
    _mcpPath = path;
    await _prefs.setString(_kMcpHost, host);
    await _prefs.setInt   (_kMcpPort, port);
    await _prefs.setString(_kMcpPath, path);
    notifyListeners();
  }

  // ── STT 設定操作 ──────────────────────────────────────
  Future<void> setStt({
    required String host,
    required int    port,
    required String path,
  }) async {
    _sttHost = host;
    _sttPort = port;
    _sttPath = path;
    await _prefs.setString(_kSttHost, host);
    await _prefs.setInt   (_kSttPort, port);
    await _prefs.setString(_kSttPath, path);
    notifyListeners();
  }

  // ── 工具：解析 URL ────────────────────────────────────
  static ({String host, int port, String path}) _parseUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return (
      host: uri.host.isEmpty ? '192.168.1.100' : uri.host,
      port: uri.hasPort      ? uri.port : 80,
      path: uri.path.isEmpty ? '/'      : uri.path,
      );
    } catch (_) {
      return (host: '192.168.1.100', port: 80, path: '/');
    }
  }
}