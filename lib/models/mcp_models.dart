class McpTool {
  final String name;
  final String? description;
  final Map<String, dynamic>? inputSchema;

  McpTool({required this.name, this.description, this.inputSchema});

  factory McpTool.fromJson(Map<String, dynamic> json) => McpTool(
    name: json['name'] as String,
    description: json['description'] as String?,
    inputSchema: json['inputSchema'] as Map<String, dynamic>?,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    if (description != null) 'description': description,
    if (inputSchema != null) 'inputSchema': inputSchema,
  };
}

class ToolResult {
  final List<ToolContent>? content;
  final bool? isError;

  ToolResult({this.content, this.isError});

  factory ToolResult.fromJson(Map<String, dynamic> json) => ToolResult(
    isError: json['isError'] as bool?,
    content: (json['content'] as List?)
        ?.map((e) => ToolContent.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    if (isError != null) 'isError': isError,
    if (content != null)
      'content': content!.map((e) => e.toJson()).toList(),
  };
}

class ToolContent {
  final String type;
  final String? text;

  /// MCP 標準的 annotations.audience：["user"] / ["assistant"] / 兩者皆有。
  /// 空的代表沒有標註（給模型看，由模型決定怎麼回覆）。
  final List<String> audience;

  ToolContent({required this.type, this.text, this.audience = const []});

  /// 這段內容要直接顯示給使用者看
  bool get isForUser => audience.contains('user');

  factory ToolContent.fromJson(Map<String, dynamic> json) => ToolContent(
    type: json['type'] as String? ?? 'text',
    text: json['text'] as String?,
    audience: ((json['annotations'] as Map?)?['audience'] as List?)
            ?.whereType<String>()
            .toList() ??
        const [],
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    if (text != null) 'text': text,
  };
}
