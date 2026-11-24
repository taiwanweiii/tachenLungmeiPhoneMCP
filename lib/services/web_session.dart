import 'package:shared_preferences/shared_preferences.dart';

/// 系統櫃網頁（內嵌 WebView 用）的位址與登入狀態。
///
/// - 網頁位址存在 SharedPreferences。
/// - 工號／密碼只放記憶體，App 關掉就沒了，不寫入磁碟。
///   （設定頁登入 MCP 成功後會順便記下來，WebView 用同一組帳密登入網頁。）
class WebSession {
  static const _kBaseUrl = 'web_base_url';
  static const defaultBaseUrl = 'https://p3dweb.lungmeifurniture.com';

  late SharedPreferences _prefs;
  String _baseUrl = defaultBaseUrl;
  String? _userId;
  String? _password;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _baseUrl = _normalize(_prefs.getString(_kBaseUrl) ?? defaultBaseUrl);
  }

  String get baseUrl => _baseUrl;
  String? get userId => _userId;
  bool get hasCredentials =>
      (_userId ?? '').isNotEmpty && (_password ?? '').isNotEmpty;

  /// 只給登入網頁用；不要印出或傳給其他地方
  ({String userId, String password})? get credentials =>
      hasCredentials ? (userId: _userId!, password: _password!) : null;

  Future<void> setBaseUrl(String url) async {
    _baseUrl = _normalize(url);
    await _prefs.setString(_kBaseUrl, _baseUrl);
  }

  void rememberLogin(String userId, String password) {
    _userId = userId;
    _password = password;
  }

  void forgetLogin() {
    _userId = null;
    _password = null;
  }

  /// 系統櫃配置頁。帶 caseNo 時是編輯既有案件，否則是新案件。
  /// 一定要帶 embed=1，網頁才會啟用橋接。
  Uri cabinetConfigUri({String? caseNo, String roomId = 'A', String closetId = '1'}) {
    final q = <String, String>{'embed': '1'};
    if (caseNo != null && caseNo.isNotEmpty) {
      q['caseNo'] = caseNo;
      q['roomId'] = roomId;
      q['closetId'] = closetId;
    }
    return Uri.parse('$_baseUrl/app/store/cabinet-config')
        .replace(queryParameters: q);
  }

  /// 挑選產品頁（只有產品目錄，選完把結果回傳給 App）
  /// 獨立的公開頁（不需登入），資料來自匿名唯讀的 /api/McpCatalog
  Uri pickerUri() => Uri.parse('$_baseUrl/public/mcp-catalog')
      .replace(queryParameters: {'embed': '1', 'mode': 'pick'});

  /// 修改待確認訂單的網頁編輯頁（公開頁，不需登入；訂單由 App 載入後用橋接交進去）
  Uri orderEditUri() => Uri.parse('$_baseUrl/public/mcp-order-edit')
      .replace(queryParameters: {'embed': '1', 'mode': 'edit'});

  static String _normalize(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}
