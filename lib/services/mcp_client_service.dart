import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../core/config/app_config.dart';
import '../models/mcp_models.dart';
import '../models/mcp_server_model.dart';

/// 單台 MCP Server 的檢查結果；error 為 null 代表成功
typedef McpServerCheck = ({McpServerModel server, String? error});

/// MCP 客戶端：同時管理多台「已啟用」的 MCP Server
/// - 工具清單 = 所有已啟用 Server 的工具合併
/// - 呼叫工具時自動送到提供該工具的 Server
/// - 全部關閉時不發任何請求
class McpClientService {
  final Dio       _dio;
  final AppConfig _config;
  int _reqId = 0;

  /// 對外工具名稱 → (Server, 原始工具名稱)
  final Map<String, ({McpServerModel server, String originalName})>
      _toolRoutes = {};

  McpClientService(this._dio, this._config);

  List<McpServerModel> get _enabled => _config.enabledMcpServers;

  bool get hasEnabledServers => _enabled.isNotEmpty;

  /// 已啟用 Server 的組合；改變時代表需要重新載入工具
  String get enabledSignature =>
      _enabled.map((m) => '${m.id}|${m.url}').join(',');

  /// 給 log 顯示用
  String get serverUrl => hasEnabledServers
      ? _enabled.map((m) => '${m.name}(${m.url})').join(', ')
      : '（未啟用任何 MCP Server）';

  void reset() {
    _reqId = 0;
    _toolRoutes.clear();
  }

  // ══════════════════════════════════════════════════════
  // 對外 API（多台）
  // ══════════════════════════════════════════════════════

  /// 初始化所有已啟用的 Server。
  /// 全部失敗才丟例外；部分失敗只記 log（可用 checkAllAsync 看細節）。
  Future<void> initializeAsync() async {
    final servers = _enabled;
    if (servers.isEmpty) return;

    final results = await Future.wait(servers.map((m) async {
      try {
        await _initializeServer(m);
        return (server: m, error: null as String?);
      } catch (e) {
        return (server: m, error: describeError(e));
      }
    }));

    final failed = results.where((r) => r.error != null).toList();
    if (failed.length == servers.length) {
      throw Exception(
          failed.map((r) => '${r.server.name}：${r.error}').join('\n'));
    }
    for (final r in failed) {
      debugPrint('⚠️ MCP ${r.server.name} 初始化失敗：${r.error}');
    }
  }

  /// 合併所有已啟用 Server 的工具；名稱重複時後面的加上編號
  Future<List<McpTool>> listToolsAsync() async {
    _toolRoutes.clear();
    final servers = _enabled;

    final perServer = await Future.wait(servers.map((m) async {
      try {
        return (server: m, tools: await _listTools(m));
      } catch (e) {
        debugPrint('⚠️ MCP ${m.name} 取得工具失敗：${describeError(e)}');
        return (server: m, tools: <McpTool>[]);
      }
    }));

    final merged = <McpTool>[];
    for (final entry in perServer) {
      for (final t in entry.tools) {
        var exposed = t.name;
        var n = 2;
        while (_toolRoutes.containsKey(exposed)) {
          exposed = '${t.name}_$n';
          n++;
        }
        _toolRoutes[exposed] =
            (server: entry.server, originalName: t.name);
        merged.add(McpTool(
          name:        exposed,
          description: servers.length > 1
              ? '[${entry.server.name}] ${t.description ?? ''}'.trim()
              : t.description,
          inputSchema: t.inputSchema,
        ));
      }
    }
    return merged;
  }

  Future<ToolResult?> callToolAsync(
      String toolName, Map<String, dynamic> args) async {
    var route = _toolRoutes[toolName];
    if (route == null) {
      // 工具清單還沒載入過 → 重新載入一次再找
      await listToolsAsync();
      route = _toolRoutes[toolName];
    }
    if (route == null) {
      throw Exception('找不到工具「$toolName」，可能所屬的 MCP Server 已關閉');
    }
    final result = await _sendAsync(route.server, 'tools/call',
        {'name': route.originalName, 'arguments': args});
    return result != null
        ? ToolResult.fromJson(result as Map<String, dynamic>)
        : null;
  }

  /// 依序向已啟用的 Server 取 prompt，第一個成功的為準；都沒有就回傳 null
  Future<Map<String, dynamic>?> getPromptAsync(
      String name, Map<String, String> args) async {
    for (final m in _enabled) {
      try {
        final result = await _sendAsync(
            m, 'prompts/get', {'name': name, 'arguments': args});
        if (result != null) return result as Map<String, dynamic>;
      } catch (_) {}
    }
    return null;
  }

  /// 任一台已啟用的 Server 有回應就算成功；沒有啟用任何 Server 直接回 false
  Future<bool> pingAsync() async {
    final servers = _enabled;
    if (servers.isEmpty) return false;
    final results = await Future.wait(servers.map(_pingServer));
    return results.any((ok) => ok);
  }

  /// 逐台檢查已啟用的 Server（啟動畫面 / 設定頁用）
  Future<List<McpServerCheck>> checkAllAsync() =>
      Future.wait(_enabled.map((m) async =>
          (server: m, error: await testServerAsync(m))));

  /// 測試單台 Server（不論是否啟用）；成功回傳 null，失敗回傳原因
  Future<String?> testServerAsync(McpServerModel m) async {
    try {
      await _sendAsync(m, 'ping', {});
      return null;
    } catch (e) {
      return describeError(e);
    }
  }

  static String describeError(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code != null) {
        final detail = _responseMessage(e.response?.data);
        return detail.isEmpty ? 'HTTP $code' : 'HTTP $code：$detail';
      }
      return switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout => '連線逾時',
        DioExceptionType.connectionError =>
          kIsWeb ? '連不上（或被瀏覽器 CORS 擋住）' : '連不上伺服器',
        _ => e.message ?? e.type.name,
      };
    }
    return e.toString().replaceAll('Exception: ', '');
  }

  static String _responseMessage(dynamic data) {
    dynamic decoded = data;
    if (data is String) {
      final text = data.trim();
      if (text.isEmpty) return '';
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        return text.length > 300 ? text.substring(0, 300) : text;
      }
    }
    if (decoded is Map) {
      final err = decoded['error'];
      final msg = decoded['message'] ??
          (err is Map ? err['message'] : err);
      if (msg != null) {
        final text = '$msg'.trim();
        if (text.isNotEmpty) {
          return text.length > 300 ? text.substring(0, 300) : text;
        }
      }
    }
    return '';
  }

  // ══════════════════════════════════════════════════════
  // 單台 Server 的 JSON-RPC
  // ══════════════════════════════════════════════════════

  Future<void> _initializeServer(McpServerModel m) async {
    await _sendAsync(m, 'initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': {},
      'clientInfo': {'name': 'CurtainMCP-Flutter', 'version': '1.0.0'},
    });
    await _sendNotification(m, 'notifications/initialized');
  }

  Future<List<McpTool>> _listTools(McpServerModel m) async {
    final result = await _sendAsync(m, 'tools/list', {});
    final tools = result['tools'] as List? ?? [];
    return tools
        .map((e) => McpTool.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> _pingServer(McpServerModel m) async {
    try {
      await _sendAsync(m, 'ping', {});
      return true;
    } catch (_) {
      return false;
    }
  }

  // 解析 SSE 格式，取出 data: 那行的 JSON
  Map<String, dynamic>? _parseSse(dynamic responseData) {
    final raw = responseData is String
        ? responseData
        : jsonEncode(responseData);

    // 如果直接就是 JSON（非 SSE），直接解析
    if (raw.trimLeft().startsWith('{')) {
      return jsonDecode(raw) as Map<String, dynamic>;
    }

    // 解析 SSE 格式：找 "data:" 開頭的行
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('data:')) {
        final jsonStr = trimmed.substring(5).trim();
        if (jsonStr.isNotEmpty) {
          return jsonDecode(jsonStr) as Map<String, dynamic>;
        }
      }
    }
    return null;
  }

  // 每台 Server 固定一個 session：登入身分、權限、草稿才能在多次呼叫之間延續
  // （沒帶的話伺服器每次都當成新的 session）
  final Map<String, String> _sessionIds = {};
  String _sessionFor(McpServerModel m) => _sessionIds.putIfAbsent(m.id, () {
        final r = Random.secure();
        return List.generate(
            16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      });

  Options _optionsFor(McpServerModel m) => Options(
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream',
          'Mcp-Session-Id': _sessionFor(m),
        },
        // 強制 Dio 不要自動解析，保留原始字串
        responseType: ResponseType.plain,
      );

  /// 工號登入／切換管理者：直接呼叫 MCP 的 /auth 端點，密碼不經過 AI。
  /// 成功回傳伺服器訊息，失敗丟例外（訊息是伺服器給的原因）
  Future<String> authAsync(String path, Map<String, String> body) async {
    if (_enabled.isEmpty) throw Exception('沒有啟用的 MCP Server');
    final m   = _enabled.first;
    final u   = Uri.parse(m.url);
    final res = await _dio.post(
      '${u.scheme}://${u.authority}$path',
      data: jsonEncode(body),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'Mcp-Session-Id': _sessionFor(m),
        },
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    Map<String, dynamic>? data;
    try {
      data = jsonDecode('${res.data}') as Map<String, dynamic>;
    } catch (_) {}
    final msg = '${data?['message'] ?? ''}'.trim();
    if (data?['ok'] != true) {
      throw Exception(msg.isEmpty ? '伺服器回應 ${res.statusCode}' : msg);
    }
    return msg;
  }

  /// MCP Server 的一般 HTTP 端點（不是 JSON-RPC），例如 GET /drafts/{案號}。
  /// 失敗（沒有啟用的 Server、連不上、非 2xx）丟例外。
  Future<dynamic> httpJson(String method, String path, {Object? body}) async {
    if (_enabled.isEmpty) throw Exception('沒有啟用的 MCP Server');
    final u = Uri.parse(_enabled.first.url);
    final res = await _dio.request(
      '${u.scheme}://${u.authority}$path',
      data: body == null ? null : jsonEncode(body),
      options: Options(
        method: method,
        headers: {
          if (body != null) 'Content-Type': 'application/json',
          'Mcp-Session-Id': _sessionFor(_enabled.first),
        },
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 300) {
      String msg = '伺服器回應 $code';
      try {
        final d = jsonDecode('${res.data}');
        if (d is Map && d['message'] != null) msg = '${d['message']}';
      } catch (_) {}
      throw Exception(msg);
    }
    final text = '${res.data}';
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<dynamic> _sendAsync(
      McpServerModel m, String method, Map<String, dynamic> params) async {
    final id = _reqId++;
    final payload = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });

    debugPrint('📡 MCP [${m.name}] [$method] → ${m.url}');
    debugPrint('   payload: $payload');

    try {
      final response = await _dio.post(m.url, data: payload, options: _optionsFor(m));

      debugPrint('✅ MCP [${m.name}] [$method] status=${response.statusCode}');
      debugPrint('   response: ${response.data}');

      final body = _parseSse(response.data);
      if (body == null) throw Exception('MCP: 無法解析回應');
      if (body['error'] != null) throw Exception('MCP Error: ${body['error']}');
      return body['result'];
    } on DioException catch (e) {
      debugPrint('❌ MCP DioException [${m.name}] [$method]');
      debugPrint('   type    : ${e.type}');
      debugPrint('   message : ${e.message}');
      debugPrint('   status  : ${e.response?.statusCode}');
      debugPrint('   body    : ${e.response?.data}');
      throw Exception(describeError(e));
    } catch (e) {
      debugPrint('❌ MCP Error [${m.name}] [$method]: $e');
      rethrow;
    }
  }

  Future<void> _sendNotification(McpServerModel m, String method) async {
    try {
      debugPrint('📣 MCP Notification [${m.name}] → $method');
      await _dio.post(
        m.url,
        data: jsonEncode({'jsonrpc': '2.0', 'method': method}),
        options: _optionsFor(m),
      );
    } catch (e) {
      debugPrint('⚠️ Notification failed [${m.name}] [$method]: $e');
    }
  }
}
