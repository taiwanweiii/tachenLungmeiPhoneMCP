import 'dart:convert';

class OllamaMessage {
  final String role;
  final String? content;
  final String? name;
  final List<OllamaToolCall>? toolCalls;

  /// role = 'tool' 時，對應的 tool call id（OpenAI 協定必填）
  final String? toolCallId;

  /// 模型的思考內容（僅供顯示，不會再送回模型）
  final String? thinking;

  OllamaMessage({
    required this.role,
    this.content,
    this.name,
    this.toolCalls,
    this.toolCallId,
    this.thinking,
  });

  factory OllamaMessage.fromJson(Map<String, dynamic> json) => OllamaMessage(
    role: json['role'] as String,
    content: json['content'] as String?,
    name: json['name'] as String?,
    toolCallId: json['tool_call_id'] as String?,
    // OpenAI 相容：reasoning_content / reasoning；Ollama：thinking
    thinking: _asText(json['reasoning_content']) ??
        _asText(json['reasoning']) ??
        _asText(json['thinking']),
    toolCalls: (json['tool_calls'] as List?)
        ?.map((e) => OllamaToolCall.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  static String? _asText(dynamic v) =>
      v is String && v.trim().isNotEmpty ? v : null;

  /// Ollama 原生格式
  Map<String, dynamic> toJson() => {
    'role': role,
    if (content != null) 'content': content,
    if (name != null) 'name': name,
    if (toolCalls != null)
      'tool_calls': toolCalls!.map((e) => e.toJson()).toList(),
  };

  /// OpenAI Chat Completions 格式
  Map<String, dynamic> toOpenAiJson() {
    if (role == 'tool') {
      return {
        'role': 'tool',
        'tool_call_id': toolCallId ?? '',
        'content': content ?? '',
      };
    }
    final hasToolCalls = toolCalls != null && toolCalls!.isNotEmpty;
    return {
      'role': role,
      // 有 tool_calls 的 assistant 訊息 content 可以是 null
      'content': (content == null || content!.isEmpty) && hasToolCalls
          ? null
          : (content ?? ''),
      if (hasToolCalls)
        'tool_calls': toolCalls!.map((e) => e.toOpenAiJson()).toList(),
    };
  }
}

class OllamaToolCall {
  final String? id;
  final OllamaFunction function;

  OllamaToolCall({this.id, required this.function});

  factory OllamaToolCall.fromJson(Map<String, dynamic> json) => OllamaToolCall(
    id: json['id'] as String?,
    function: OllamaFunction.fromJson(
        json['function'] as Map<String, dynamic>),
  );

  OllamaToolCall withId(String newId) =>
      OllamaToolCall(id: newId, function: function);

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'function': function.toJson(),
  };

  /// OpenAI 格式：arguments 必須是 JSON 字串
  Map<String, dynamic> toOpenAiJson() => {
    'id': id ?? '',
    'type': 'function',
    'function': {
      'name': function.name,
      'arguments': jsonEncode(function.arguments),
    },
  };
}

class OllamaFunction {
  final String name;
  final Map<String, dynamic> arguments;

  OllamaFunction({required this.name, required this.arguments});

  /// arguments 可能是 Map（Ollama）或 JSON 字串（OpenAI）
  factory OllamaFunction.fromJson(Map<String, dynamic> json) {
    return OllamaFunction(
      name: json['name'] as String,
      arguments: _parseArguments(json['arguments']),
    );
  }

  static Map<String, dynamic> _parseArguments(dynamic args) {
    if (args == null) return {};
    if (args is Map<String, dynamic>) return args;
    if (args is Map) return Map<String, dynamic>.from(args);
    if (args is String) {
      if (args.trim().isEmpty) return {};
      try {
        final decoded = jsonDecode(args);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'arguments': arguments,
  };
}

class OllamaTool {
  final String type;
  final OllamaToolDef function;

  OllamaTool({this.type = 'function', required this.function});

  Map<String, dynamic> toJson() => {
    'type': type,
    'function': function.toJson(),
  };
}

class OllamaToolDef {
  final String name;
  final String? description;
  final Map<String, dynamic>? parameters;

  OllamaToolDef({required this.name, this.description, this.parameters});

  Map<String, dynamic> toJson() => {
    'name': name,
    if (description != null) 'description': description,
    if (parameters != null) 'parameters': parameters,
  };
}
