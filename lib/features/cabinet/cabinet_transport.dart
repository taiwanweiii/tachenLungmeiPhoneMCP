/// 控制器與「裝著系統櫃網頁的容器」之間的介面。
/// - 手機／桌面：原生 WebView，直接執行 JS（見 cabinet_overlay.dart）
/// - Chrome（Flutter Web）：iframe + postMessage（見 web_frame_web.dart）
/// 兩種容器對控制器提供同一套能力，控制器的登入與橋接邏輯只寫一份。
abstract class CabinetTransport {
  /// 呼叫 window.cabinetBridge[method](...args)，回傳網頁給的 {ok, ...}
  Future<Map<String, dynamic>> call(String method, List<dynamic> args);

  /// window.cabinetBridge 是否已經掛上
  Future<bool> hasBridge();

  /// 網頁是否已登入
  Future<bool> hasSession();

  /// 用工號密碼登入網頁。回傳 {ok, message?}
  Future<Map<String, dynamic>> signIn(String userId, String password);

  /// 重新載入目標頁面
  Future<void> reload(Uri uri);
}
