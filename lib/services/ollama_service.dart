import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/endpoint_model.dart';
import '../models/ollama_models.dart';
import '../core/config/app_config.dart';

/// LLM 服務：依目前端點的協定，走 Ollama 原生 API 或 OpenAI 相容 API
class OllamaService {
  final Dio        _dio;
  final AppConfig  _config;

  OllamaService(this._dio, this._config);

  /// 動態取得目前端點（切換端點後自動更新）
  EndpointModel get _endpoint => _config.activeEndpoint;
  String get _baseUrl => _endpoint.baseUrl;
  String get _model   => _endpoint.model;
  bool   get _isOpenAi => _endpoint.isOpenAi;

  /// 顯示用：目前使用的協定與模型
  String get modelLabel => '${_endpoint.provider.label} · $_model';

  int _toolCallSeq = 0;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_isOpenAi && _endpoint.apiKey.isNotEmpty)
      'Authorization': 'Bearer ${_endpoint.apiKey}',
  };

  Future<bool> isAvailableAsync() async => await diagnoseAsync() == null;

  /// 測試連線；成功回傳 null，失敗回傳可讀的錯誤原因
  Future<String?> diagnoseAsync() async {
    final url = _isOpenAi ? '$_baseUrl/models' : '$_baseUrl/api/tags';
    try {
      final res = await _dio.get(
        url,
        options: Options(
          headers:        _headers,
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      if (res.statusCode != 200) return 'HTTP ${res.statusCode}（$url）';
      return _checkModelListed(res.data);
    } on DioException catch (e) {
      final reason = _describeError(e, url);
      debugPrint('❌ 模型端點連線失敗：$reason\n   ${e.message}');
      return reason;
    } catch (e) {
      debugPrint('❌ 模型端點連線失敗：$e');
      return '$e';
    }
  }

  /// 確認目前設定的模型名稱有在伺服器的模型清單裡
  /// （名稱打錯時 /models 仍會成功，要到發訊息才會 404）
  String? _checkModelListed(dynamic body) {
    try {
      final data = body is String ? jsonDecode(body) : body;
      final List names;
      if (_isOpenAi) {
        names = ((data['data'] as List?) ?? [])
            .map((e) => (e as Map)['id'])
            .toList();
      } else {
        names = ((data['models'] as List?) ?? [])
            .expand((e) => [(e as Map)['name'], e['model']])
            .toList();
      }
      if (names.isEmpty || names.contains(_model)) return null;
      // Ollama 未寫 tag 時預設為 :latest
      if (!_isOpenAi && names.contains('$_model:latest')) return null;
      return '連線正常，但找不到模型「$_model」。'
          '請確認名稱完全一致（大小寫、- 與空格）';
    } catch (_) {
      return null; // 清單格式不認得 → 不阻擋
    }
  }

  String _describeError(DioException e, String url) {
    final code = e.response?.statusCode;
    if (code != null) {
      final detail = _responseMessage(e.response?.data);
      if (detail.isNotEmpty) return 'HTTP $code：$detail';
      final hint = switch (code) {
        401 || 403 => 'API Key 錯誤或沒有權限',
        404        => '網址或模型名稱錯誤（Base URL 不要包含 /chat/completions）',
        429        => '請求太頻繁或額度用完',
        _          => '伺服器回應錯誤',
      };
      return 'HTTP $code：$hint（$url）';
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        '連線逾時，請確認網址與網路（$url）',
      DioExceptionType.badCertificate => 'SSL 憑證錯誤（$url）',
      // Web 上 CORS 被擋時，瀏覽器只會給 connectionError，拿不到細節
      DioExceptionType.connectionError => kIsWeb
          ? '連不上或被瀏覽器 CORS 擋住（$url）。'
            '外部 API 在 Chrome 上請用 --disable-web-security 啟動，或改用手機測試'
          : '連不上伺服器，請確認網址與網路（$url）',
      _ => '${e.type.name}：${e.message ?? ''}（$url）',
    };
  }

  String _httpError(DioException e) =>
      _describeError(e, '$_baseUrl/chat/completions');

  /// NVIDIA 放在 message；OpenAI 放在 error.message。Dio 自己的說明不含這段。
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
          (err is Map ? err['message'] : null) ??
          (err is String ? err : null);
      if (msg != null) {
        final text = '$msg'.trim();
        if (text.isNotEmpty) {
          return text.length > 300 ? text.substring(0, 300) : text;
        }
      }
    }
    return '';
  }

  /// 非串流：一次取得完整回應
  Future<OllamaMessage?> chatAsync({
    required List<OllamaMessage> messages,
    List<OllamaTool>? tools,
  }) async {
    final msg = _isOpenAi
        ? await _openAiChat(messages: messages, tools: tools)
        : await _ollamaChat(messages: messages, tools: tools);
    return msg == null ? null : _ensureToolCallIds(msg);
  }

  /// 串流：逐字回傳
  Stream<String> chatStreamAsync({
    required List<OllamaMessage> messages,
  }) =>
      _isOpenAi
          ? _openAiStream(messages: messages)
          : _ollamaStream(messages: messages);

  // ══════════════════════════════════════════════════════
  // Ollama 原生 API
  // ══════════════════════════════════════════════════════

  Future<OllamaMessage?> _ollamaChat({
    required List<OllamaMessage> messages,
    List<OllamaTool>? tools,
  }) async {
    final body = {
      'model': _model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'stream': false,
      if (tools != null && tools.isNotEmpty)
        'tools': tools.map((t) => t.toJson()).toList(),
      'options': {
        'temperature': 0.1,  // 降低隨機性，讓模型更傾向呼叫工具
      },
    };
    final res = await _dio.post(
      '$_baseUrl/api/chat',
      data: jsonEncode(body),
      options: Options(headers: _headers),
    );
    final data = res.data is String ? jsonDecode(res.data) : res.data;
    final msg  = data['message'];
    return msg != null
        ? OllamaMessage.fromJson(msg as Map<String, dynamic>)
        : null;
  }

  Stream<String> _ollamaStream({
    required List<OllamaMessage> messages,
  }) async* {
    final body = {
      'model': _model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'stream': true,
    };
    final res = await _dio.post(
      '$_baseUrl/api/chat',
      data: jsonEncode(body),
      options: Options(
        headers: _headers,
        responseType: ResponseType.stream,
      ),
    );
    final stream = res.data.stream as Stream<List<int>>;
    await for (final chunk in stream) {
      final line = utf8.decode(chunk).trim();
      if (line.isEmpty) continue;
      try {
        final json    = jsonDecode(line) as Map<String, dynamic>;
        final content = (json['message'] as Map?)?['content'] as String? ?? '';
        if (content.isNotEmpty) yield content;
      } catch (_) {}
    }
  }

  // ══════════════════════════════════════════════════════
  // OpenAI 相容 API（/chat/completions）
  // ══════════════════════════════════════════════════════

  Future<OllamaMessage?> _openAiChat({
    required List<OllamaMessage> messages,
    List<OllamaTool>? tools,
  }) async {
    final hasTools = tools != null && tools.isNotEmpty;
    // 不送這個欄位時，gpt-6-luna 仍會用預設思考，帶工具就 400。必須明確送 none。
    final forceNone =
        hasTools && EndpointModel.modelNeedsReasoningNone(_model);

    Map<String, dynamic> buildBody({
      required bool withTemperature,
      required bool withTopP,
      required bool withSampling,
      required bool withReasoning,
      required bool forceReasoningNone,
    }) =>
        {
          'model': _model,
          'messages': _toOpenAiMessages(messages),
          'stream': false,
          if (hasTools) 'tools': tools!.map((t) => t.toJson()).toList(),
          if (withSampling)
            ..._endpoint.openAiSamplingBody(
              includeTemperature: withTemperature,
              includeTopP: withTopP,
              includeReasoning: withReasoning,
              forceReasoningNone: forceReasoningNone,
            ),
        };

    final sendTemp = _endpoint.sendTemperature;
    final sendTopP = _endpoint.topP != null;

    Future<Response> post({
      required bool withTemperature,
      required bool withTopP,
      required bool withSampling,
      required bool withReasoning,
      required bool forceReasoningNone,
    }) {
      return _dio.post(
        '$_baseUrl/chat/completions',
        data: jsonEncode(buildBody(
          withTemperature: withTemperature,
          withTopP: withTopP,
          withSampling: withSampling,
          withReasoning: withReasoning,
          forceReasoningNone: forceReasoningNone,
        )),
        options: Options(headers: _headers),
      );
    }

    Response res;
    try {
      res = await post(
        withTemperature: sendTemp,
        withTopP: sendTopP,
        withSampling: true,
        withReasoning: !forceNone,
        forceReasoningNone: forceNone,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode != 400) throw Exception(_httpError(e));
      final detail = _responseMessage(e.response?.data).toLowerCase();
      final needNone = detail.contains('reasoning_effort');
      final dropTemp = detail.contains('temperature');
      final dropTopP = detail.contains('top_p') || detail.contains('top-p');
      if (!needNone && !dropTemp && !dropTopP && !_endpoint.sendsSampling) {
        throw Exception(_httpError(e));
      }
      try {
        res = await post(
          withTemperature: dropTemp ? false : sendTemp,
          withTopP: dropTopP ? false : sendTopP,
          withSampling: true,
          withReasoning: !needNone && !forceNone,
          forceReasoningNone: needNone || forceNone,
        );
      } on DioException catch (again) {
        throw Exception(_httpError(again));
      }
    }

    final data    = res.data is String ? jsonDecode(res.data) : res.data;
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) return null;
    final msg = (choices.first as Map)['message'];
    return msg != null
        ? OllamaMessage.fromJson(Map<String, dynamic>.from(msg as Map))
        : null;
  }

  Stream<String> _openAiStream({
    required List<OllamaMessage> messages,
  }) async* {
    final body = {
      'model': _model,
      'messages': _toOpenAiMessages(messages),
      'stream': true,
      ..._endpoint.openAiSamplingBody(),
    };
    final res = await _dio.post(
      '$_baseUrl/chat/completions',
      data: jsonEncode(body),
      options: Options(
        headers: _headers,
        responseType: ResponseType.stream,
      ),
    );
    final stream = (res.data.stream as Stream<List<int>>)
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    // SSE 格式：每行 "data: {...}"，結尾 "data: [DONE]"
    await for (final line in stream) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trim();
      if (payload == '[DONE]') break;
      try {
        final json    = jsonDecode(payload) as Map<String, dynamic>;
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final delta   = (choices.first as Map)['delta'] as Map?;
        final content = delta?['content'] as String? ?? '';
        if (content.isNotEmpty) yield content;
      } catch (_) {}
    }
  }

  /// 轉成 OpenAI 格式，並移除找不到對應 tool_call 的 tool 訊息
  /// （歷史修剪可能把 assistant 的 tool_calls 剪掉，OpenAI 會回 400）
  List<Map<String, dynamic>> _toOpenAiMessages(List<OllamaMessage> messages) {
    final knownIds = <String>{};
    final result   = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m.role == 'tool') {
        if (m.toolCallId == null || !knownIds.contains(m.toolCallId)) continue;
      }
      for (final tc in m.toolCalls ?? const <OllamaToolCall>[]) {
        if (tc.id != null) knownIds.add(tc.id!);
      }
      result.add(m.toOpenAiJson());
    }
    return result;
  }

  /// Ollama 回傳的 tool call 沒有 id → 補上，讓 tool 結果能對應回去
  OllamaMessage _ensureToolCallIds(OllamaMessage msg) {
    final calls = msg.toolCalls;
    if (calls == null || calls.every((c) => c.id != null && c.id!.isNotEmpty)) {
      return msg;
    }
    return OllamaMessage(
      role:       msg.role,
      content:    msg.content,
      name:       msg.name,
      toolCallId: msg.toolCallId,
      thinking:   msg.thinking,
      toolCalls:  calls
          .map((c) => (c.id != null && c.id!.isNotEmpty)
              ? c
              : c.withId('call_${++_toolCallSeq}'))
          .toList(),
    );
  }
}
