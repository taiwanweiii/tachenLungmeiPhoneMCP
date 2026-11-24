/// 端點使用的 API 協定
enum LlmProvider {
  ollama,  // Ollama 原生 API（/api/chat）
  openai;  // OpenAI 相容 API（/chat/completions）：OpenAI、LM Studio、vLLM、Azure 等

  String get label => switch (this) {
        LlmProvider.ollama => 'Ollama',
        LlmProvider.openai => 'OpenAI 相容',
      };

  static LlmProvider fromName(String? name) => LlmProvider.values.firstWhere(
        (p) => p.name == name,
        orElse: () => LlmProvider.ollama,
      );
}

/// OpenAI 相容端點的參數組。請求網址相同，各家認得的欄位不同。
enum OpenAiProfile {
  generic, // NVIDIA、LM Studio、vLLM：max_tokens、enable_thinking
  gpt;     // OpenAI GPT：max_completion_tokens、reasoning_effort、verbosity

  String get label => switch (this) {
        OpenAiProfile.generic => '通用',
        OpenAiProfile.gpt => 'GPT',
      };

  static OpenAiProfile fromName(String? name) => OpenAiProfile.values.firstWhere(
        (p) => p.name == name,
        orElse: () => OpenAiProfile.generic,
      );
}

class EndpointModel {
  final String id;          // UUID
  final String name;        // 顯示名稱，例如「家裡 NAS」
  final String host;        // 192.168.1.100 / api.openai.com
  final int port;           // 11434 / 443
  final String model;       // llama3.2 / gpt-4o-mini 等
  final LlmProvider provider;
  final bool useHttps;
  final String path;        // OpenAI 相容通常是 /v1；Ollama 為空
  final String apiKey;      // OpenAI 相容的 Bearer token，可留空

  /// OpenAI 相容的生成參數。null 或 sendTemperature=false 代表不送，用伺服器預設。
  final double temperature;
  final bool sendTemperature;
  final double? topP;
  final int? maxTokens;
  final OpenAiProfile profile;
  final String? reasoningEffort;
  final String? verbosity;
  final bool? enableThinking;

  static const reasoningEfforts = [
    'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max',
  ];
  static const verbosities = ['low', 'medium', 'high'];

  const EndpointModel({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.model,
    this.provider = LlmProvider.ollama,
    this.useHttps = false,
    this.path = '',
    this.apiKey = '',
    this.temperature = 0.1,
    this.sendTemperature = true,
    this.topP,
    this.maxTokens,
    this.profile = OpenAiProfile.generic,
    this.reasoningEffort,
    this.verbosity,
    this.enableThinking,
  });

  bool get isOpenAi => provider == LlmProvider.openai;

  /// 端點列表上的一行摘要
  String get samplingSummary {
    final gpt = profile == OpenAiProfile.gpt;
    final parts = <String>[
      profile.label,
      sendTemperature
          ? '溫度 ${_fmt(temperature)}'
          : '溫度不送',
      if (!gpt && topP != null) 'top_p ${_fmt(topP!)}',
      if (maxTokens != null) '上限 $maxTokens',
      if (gpt && reasoningEffort != null) '思考 $reasoningEffort',
      if (gpt && verbosity != null) '詳略 $verbosity',
      if (!gpt && enableThinking == true) '思考開',
      if (!gpt && enableThinking == false) '思考關',
    ];
    return parts.join(' · ');
  }

  static String _fmt(double n) =>
      n.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  /// 這次請求會帶至少一個生成參數
  bool get sendsSampling => openAiSamplingBody().isNotEmpty;

  /// 併進 /chat/completions。只送這個模式認得的欄位。
  /// gpt-6-luna 在 /chat/completions 帶工具時，必須明確送 reasoning_effort=none。
  /// 不送的話伺服器仍用預設思考力度，一樣回 400。
  static bool modelNeedsReasoningNone(String model) {
    final normalized = model
        .toLowerCase()
        .replaceAll(RegExp(r'[\u2010-\u2015\u2212]'), '-')
        .replaceAll(RegExp(r'[\s_]+'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    final compact = normalized.replaceAll('-', '');
    return normalized.contains('gpt-6-luna') || compact.contains('gpt6luna');
  }

  Map<String, dynamic> openAiSamplingBody({
    bool includeTemperature = true,
    bool includeTopP = true,
    bool includeReasoning = true,
    bool forceReasoningNone = false,
  }) {
    final gpt = profile == OpenAiProfile.gpt;
    return {
      if (includeTemperature && sendTemperature) 'temperature': temperature,
      if (!gpt && includeTopP && topP != null) 'top_p': topP,
      if (maxTokens != null)
        (gpt ? 'max_completion_tokens' : 'max_tokens'): maxTokens,
      if (forceReasoningNone)
        'reasoning_effort': 'none'
      else if (gpt && includeReasoning && reasoningEffort != null)
        'reasoning_effort': reasoningEffort,
      if (gpt && verbosity != null) 'verbosity': verbosity,
      if (!gpt && enableThinking != null)
        'chat_template_kwargs': {'enable_thinking': enableThinking},
    };
  }

  /// 預設 port（http 80 / https 443）不顯示在網址中
  String get baseUrl {
    final scheme = useHttps ? 'https' : 'http';
    final isDefaultPort =
        (useHttps && port == 443) || (!useHttps && port == 80);
    final portPart = isDefaultPort ? '' : ':$port';
    return '$scheme://$host$portPart$path';
  }

  /// 從完整網址解析出 host / port / path / https，例如 https://api.openai.com/v1
  static ({String host, int port, String path, bool useHttps})? parseBaseUrl(
      String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return null;
    final https = uri.scheme == 'https';
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return (
      host: uri.host,
      port: uri.hasPort ? uri.port : (https ? 443 : 80),
      path: path,
      useHttps: https,
    );
  }

  EndpointModel copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? model,
    LlmProvider? provider,
    bool? useHttps,
    String? path,
    String? apiKey,
    double? temperature,
    bool? sendTemperature,
    double? topP,
    int? maxTokens,
    OpenAiProfile? profile,
    String? reasoningEffort,
    String? verbosity,
    bool? enableThinking,
  }) =>
      EndpointModel(
        id:       id       ?? this.id,
        name:     name     ?? this.name,
        host:     host     ?? this.host,
        port:     port     ?? this.port,
        model:    model    ?? this.model,
        provider: provider ?? this.provider,
        useHttps: useHttps ?? this.useHttps,
        path:     path     ?? this.path,
        apiKey:   apiKey   ?? this.apiKey,
        temperature:     temperature     ?? this.temperature,
        sendTemperature: sendTemperature ?? this.sendTemperature,
        topP:            topP            ?? this.topP,
        maxTokens:       maxTokens       ?? this.maxTokens,
        profile:         profile         ?? this.profile,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
        verbosity:       verbosity       ?? this.verbosity,
        enableThinking:  enableThinking  ?? this.enableThinking,
      );

  Map<String, dynamic> toJson() => {
        'id':       id,
        'name':     name,
        'host':     host,
        'port':     port,
        'model':    model,
        'provider': provider.name,
        'useHttps': useHttps,
        'path':     path,
        'apiKey':   apiKey,
        'temperature':     temperature,
        'sendTemperature': sendTemperature,
        if (topP != null) 'topP': topP,
        if (maxTokens != null) 'maxTokens': maxTokens,
        'profile': profile.name,
        if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        if (verbosity != null) 'verbosity': verbosity,
        if (enableThinking != null) 'enableThinking': enableThinking,
      };

  /// 舊資料沒有新欄位 → 預設為 Ollama，相容既有設定
  factory EndpointModel.fromJson(Map<String, dynamic> json) => EndpointModel(
        id:       json['id']    as String,
        name:     json['name']  as String,
        host:     json['host']  as String,
        port:     json['port']  as int,
        model:    json['model'] as String,
        provider: LlmProvider.fromName(json['provider'] as String?),
        useHttps: json['useHttps'] as bool?   ?? false,
        path:     json['path']     as String? ?? '',
        apiKey:   json['apiKey']   as String? ?? '',
        temperature: _clampNum(json['temperature'], 0, 2, 0.1),
        sendTemperature: json['sendTemperature'] as bool? ?? true,
        topP: _optionalUnit(json['topP']),
        maxTokens: _optionalTokens(json['maxTokens']),
        profile: _profileOf(json),
        reasoningEffort: _oneOf(json['reasoningEffort'], reasoningEfforts),
        verbosity: _oneOf(json['verbosity'], verbosities),
        enableThinking: json['enableThinking'] as bool?,
      );

  static double _clampNum(dynamic v, double min, double max, double fallback) {
    final n = v is num ? v.toDouble() : fallback;
    if (n.isNaN) return fallback;
    return n.clamp(min, max);
  }

  static double? _optionalUnit(dynamic v) {
    if (v is! num) return null;
    final n = v.toDouble();
    if (n.isNaN) return null;
    return n.clamp(0.0, 1.0);
  }

  static int? _optionalTokens(dynamic v) {
    final n = v is num ? v.toInt() : null;
    if (n == null || n < 1 || n > 65536) return null;
    return n;
  }

  static OpenAiProfile _profileOf(Map<String, dynamic> json) {
    final named = json['profile'] as String?;
    if (named == OpenAiProfile.gpt.name) return OpenAiProfile.gpt;
    if (named == OpenAiProfile.generic.name) return OpenAiProfile.generic;
    // 舊資料用上限欄位名稱區分
    final token = json['tokenField'] as String?;
    if (token == 'maxCompletionTokens' || token == 'max_completion_tokens') {
      return OpenAiProfile.gpt;
    }
    return OpenAiProfile.generic;
  }

  static String? _oneOf(dynamic v, List<String> allowed) {
    if (v is! String || !allowed.contains(v)) return null;
    return v;
  }

  static EndpointModel get defaultEndpoint => const EndpointModel(
        id:    'default',
        name:  '預設',
        host:  '192.168.1.100',
        port:  11434,
        model: 'llama3.2',
      );

  @override
  bool operator ==(Object other) =>
      other is EndpointModel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
