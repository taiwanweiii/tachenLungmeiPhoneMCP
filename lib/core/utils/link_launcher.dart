import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// 連結攔截器：回傳 true 表示已處理，openLink 就不再開外部瀏覽器。
/// 在 service_locator 設定。
bool Function(String url)? linkInterceptor;

/// 開啟外部連結（例如詢單頁）。
/// - Android / iOS：App 內瀏覽器（Chrome Custom Tabs / Safari View），看完關掉就回到聊天
/// - Web：開新分頁。注意：不是由使用者點擊觸發時，瀏覽器可能會擋下彈出視窗，
///   所以畫面上一定要另外保留一個可以手動點的按鈕。
/// 成功開啟回傳 true。
Future<bool> openLink(String url) async {
  // 有些連結 App 自己處理（例如系統櫃的「更新詢單」連結改在內嵌視窗開）
  if (linkInterceptor?.call(url) == true) return true;
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return false;
  }
  try {
    return await launchUrl(
      uri,
      mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.inAppBrowserView,
      webOnlyWindowName: '_blank',
    );
  } catch (e) {
    debugPrint('⚠️ 開啟連結失敗：$url → $e');
    return false;
  }
}

/// 從 Markdown 文字中取出 [標題](網址) 形式的連結
List<({String label, String url})> extractMarkdownLinks(String markdown) {
  final re = RegExp(r'\[([^\]]+)\]\((https?://[^)\s]+)\)');
  return re
      .allMatches(markdown)
      .map((m) => (label: m.group(1)!, url: m.group(2)!))
      .toList();
}
