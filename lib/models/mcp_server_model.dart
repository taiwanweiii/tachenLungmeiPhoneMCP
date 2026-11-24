/// 一台 MCP Server 的設定
class McpServerModel {
  final String id;
  final String name;     // 顯示名稱，例如「訂單系統」
  final String url;      // 完整網址，例如 http://127.0.0.1:1987/mcp
  final bool   enabled;  // 開關：關閉時不連線、不 ping、不提供工具
  final String apiKey;   // 經網站代理（/mcp-proxy）時要帶的 X-Mcp-Proxy-Key，直連可留空

  const McpServerModel({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.apiKey = '',
  });

  McpServerModel copyWith({
    String? id,
    String? name,
    String? url,
    bool?   enabled,
    String? apiKey,
  }) =>
      McpServerModel(
        id:      id      ?? this.id,
        name:    name    ?? this.name,
        url:     url     ?? this.url,
        enabled: enabled ?? this.enabled,
        apiKey:  apiKey  ?? this.apiKey,
      );

  Map<String, dynamic> toJson() => {
        'id':      id,
        'name':    name,
        'url':     url,
        'enabled': enabled,
        'apiKey':  apiKey,
      };

  factory McpServerModel.fromJson(Map<String, dynamic> json) => McpServerModel(
        id:      json['id']   as String,
        name:    json['name'] as String,
        url:     json['url']  as String,
        enabled: json['enabled'] as bool? ?? true,
        apiKey:  json['apiKey'] as String? ?? '',
      );

  /// 檢查網址格式（需含 http:// 或 https://）
  static bool isValidUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  @override
  bool operator ==(Object other) =>
      other is McpServerModel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
