import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'cabinet_web_controller.dart';
import 'native_transport.dart';
// Web 版用 iframe 容器；其他平台是不會被呼叫到的空實作
import 'web_frame_stub.dart' if (dart.library.js_interop) 'web_frame_web.dart';

/// 內嵌系統櫃網頁的浮動視窗。放在 MaterialApp.builder 的 Stack 最上層，
/// 所以切換頁面時網頁不會被關掉。
///
/// - docked（預設）：只佔聊天的文字對話區，上面有「放大」「縮小」「關閉」
/// - full：全螢幕，上面有「縮小（回到文字對話區）」「關閉」
/// - mini：右下角小視窗，點一下回到文字對話區
/// 幾種模式用同一棵 widget 子樹，只改位置和大小，WebView 不會重新載入。
class CabinetOverlay extends StatelessWidget {
  const CabinetOverlay({super.key, required this.controller});

  final CabinetWebController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.mode == CabinetPanelMode.hidden ||
            controller.targetUri == null) {
          return const SizedBox.shrink();
        }
        return _Panel(controller: controller);
      },
    );
  }
}

/// 背景報價頁：把 controller 的網頁掛在畫面上、不能點，使用者看不到。
/// 專門用來算預設值和報價（見 CabinetWebController.background）。
/// 網頁需要實際掛在畫面上才會正常執行，所以不是 Offstage；
/// 也不能靠 Opacity 藏（Android 原生網頁元件不吃透明度），
/// 而是放在 Stack 最底層，被上面不透明的頁面蓋住（見 app.dart）。
class CabinetBackgroundHost extends StatelessWidget {
  const CabinetBackgroundHost({super.key, required this.controller});

  final CabinetWebController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.targetUri == null || !controller.isOpen) {
          return const SizedBox.shrink();
        }
        return Positioned(
          left: 0,
          bottom: 0,
          width: 360,
          height: 640,
          child: IgnorePointer(
            child: KeyedSubtree(
              key: controller.webKey,
              child: _Web(controller: controller),
            ),
          ),
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.controller});
  final CabinetWebController controller;

  static const _miniWidth = 176.0;
  static const _miniHeight = 250.0;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final mode = c.effectiveMode;
    final full = mode == CabinetPanelMode.full;
    final docked = mode == CabinetPanelMode.docked;
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final dock = c.dockRect;

    return Positioned(
      left: full ? 0 : docked ? dock!.left : null,
      top: full ? 0 : docked ? dock!.top : null,
      right: full ? 0 : docked ? null : 12,
      bottom: full ? 0 : docked ? null : 96 + media.padding.bottom,
      width: full ? null : docked ? dock!.width : _miniWidth,
      height: full ? null : docked ? dock!.height : _miniHeight,
      child: Material(
        elevation: full ? 0 : docked ? 3 : 10,
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(full ? 0 : docked ? 18 : 14),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.only(top: full ? media.padding.top : 0),
          child: Column(
            children: [
              _Header(controller: c, mode: mode),
              Expanded(
                child: Stack(
                  children: [
                    KeyedSubtree(
                      key: c.webKey,
                      child: _Web(controller: c),
                    ),
                    if (c.loading)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Color(0x66FFFFFF),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                    if ((c.loading || !c.pageReady) &&
                        mode != CabinetPanelMode.mini &&
                        c.trace.isNotEmpty)
                      Positioned(
                        left: 8,
                        right: 8,
                        top: 8,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xCC000000),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              c.trace.join('\n'),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  height: 1.3),
                            ),
                          ),
                        ),
                      ),
                    if (c.error != null && mode != CabinetPanelMode.mini)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 8,
                        child: Material(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              c.error!,
                              style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer,
                                  fontSize: 12),
                            ),
                          ),
                        ),
                      ),
                    // 小視窗：蓋一層透明的，點一下回到文字對話區（避免在小視窗裡誤觸網頁）
                    if (mode == CabinetPanelMode.mini)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: c.restore,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.mode});
  final CabinetWebController controller;
  final CabinetPanelMode mode;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final full = mode == CabinetPanelMode.full;
    final mini = mode == CabinetPanelMode.mini;
    final price = c.price;
    final summary = c.pickMode
        ? '選擇櫃體'
        : c.editMode
            ? '修改訂單'
            : [
            if (c.isEditingCase) '案件 ${c.caseNo}' else '新案件',
            '${c.cabinetCount} 件',
            if (price != null) '\$${price.round()}',
          ].join(' · ');
    final fg = theme.colorScheme.onPrimaryContainer;

    // 注意：這裡在 Navigator 之外（沒有 Overlay），IconButton 不能用 tooltip，
    // 所以每個按鈕都附上文字，不靠圖示猜意思。
    Widget action(IconData icon, String label, VoidCallback onTap) =>
        TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: fg,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
          ),
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label, style: const TextStyle(fontSize: 13)),
        );

    return Container(
      height: mini ? 30 : (full ? 48 : 42),
      padding: EdgeInsets.only(left: mini ? 8 : 12, right: mini ? 2 : 4),
      color: theme.colorScheme.primaryContainer,
      child: Row(
        children: [
          Expanded(
            child: Text(
              full && !c.lightPage ? '系統櫃配置　$summary' : summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: mini ? 11 : 15,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
          if (mode == CabinetPanelMode.docked) ...[
            action(Icons.open_in_full_rounded, '放大', c.expand),
            // 挑選畫面要操作，不縮成小視窗
            if (!c.lightPage)
              action(Icons.close_fullscreen_rounded, '縮小', c.minimize),
          ],
          if (full) action(Icons.close_fullscreen_rounded, '縮小', c.dock),
          IconButton(
            visualDensity: mini ? VisualDensity.compact : null,
            icon: Icon(Icons.close_rounded, size: mini ? 16 : 22, color: fg),
            onPressed: c.close,
          ),
        ],
      ),
    );
  }
}

class _Web extends StatelessWidget {
  const _Web({required this.controller});
  final CabinetWebController controller;

  /// 開發時網頁常跑在區網或本機的自簽憑證上；只對這類位址放行，
  /// 正式網站的憑證有問題時照常擋下。
  static bool _isPrivateHost(String host) {
    if (host == 'localhost' || host.endsWith('.localhost')) return true;
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(host);
    if (m == null) return false;
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    return a == 127 ||
        a == 10 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31);
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (kIsWeb) {
      return buildCabinetFrame(
        uri: c.targetUri!,
        interactive: c.effectiveMode != CabinetPanelMode.mini,
        onTransport: c.attachTransport,
        onLoaded: () => c.onPageLoaded(),
        onEvent: c.onBridgeEvent,
      );
    }
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(c.targetUri.toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        useHybridComposition: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        isInspectable: kDebugMode,
        supportZoom: false,
      ),
      onWebViewCreated: (ctrl) {
        c.attachTransport(NativeTransport(ctrl));
        // 網頁事件（window.cabinetBridge 發出）
        ctrl.addJavaScriptHandler(
          handlerName: 'cabinetEvent',
          callback: (args) {
            if (args.isNotEmpty && args.first is Map) {
              c.onBridgeEvent(Map<String, dynamic>.from(args.first as Map));
            }
            return null;
          },
        );
      },
      onLoadStart: (ctrl, url) => c.mark('開始請求 ${url?.host ?? ''}${url?.path ?? ''}'),
      onProgressChanged: (ctrl, p) {
        if (p == 50 || p == 100) c.mark('載入進度 $p%');
        if (p == 100) {
          // 進度到 100% 卻一直沒有 onLoadStop：4 秒後仍在轉圈就當作載入完成
          Future.delayed(const Duration(seconds: 4), () {
            if (c.loading && c.targetUri != null) {
              c.mark('沒收到 onLoadStop，改用進度 100% 判定載入完成');
              c.onPageLoaded();
            }
          });
        }
      },
      onLoadStop: (ctrl, url) => c.onPageLoaded(),
      onReceivedError: (ctrl, request, error) {
        if (request.isForMainFrame ?? false) {
          // 「已取消」(iOS -999 / ERR_ABORTED)：導覽被新的導覽取代或頁面自己轉址，
          // 不是真的載入失敗，後面通常還會正常載入完成，不要當成錯誤彈出。
          final d = error.description.toLowerCase();
          if (error.type == WebResourceErrorType.CANCELLED ||
              d.contains('cancel') ||
              error.description.contains('取消')) {
            // 取消後頁面沒有再載入的話會永遠空白轉圈，所以自動重載，最多 3 次
            if (c.cancelRetries < 3 && c.targetUri != null) {
              c.cancelRetries++;
              c.mark('導覽被取消，自動重載第 ${c.cancelRetries} 次');
              final uri = c.targetUri!;
              Future.delayed(const Duration(milliseconds: 400), () {
                ctrl.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString())));
              });
            } else {
              c.onLoadError('網頁載入被取消，已重試 ${c.cancelRetries} 次仍失敗');
            }
            return;
          }
          c.onLoadError('無法載入網頁：${error.description}');
        }
      },
      onReceivedServerTrustAuthRequest: (ctrl, challenge) async {
        final host = challenge.protectionSpace.host;
        // 內網位址（開發機自簽憑證）放行；其他網站回傳 null，交給系統做正常的憑證驗證。
        // 注意：iOS 上每次連線都會進到這裡（憑證正常也會），不能直接回 CANCEL，
        // 否則正式站會被取消（畫面上看到「已取消」）。
        if (_isPrivateHost(host)) {
          return ServerTrustAuthResponse(
              action: ServerTrustAuthResponseAction.PROCEED);
        }
        return null;
      },
      // 網頁的 alert／confirm 不彈系統對話框（嵌入模式下網頁自己會攔，這裡是保險）
      onJsAlert: (ctrl, req) async => JsAlertResponse(
        handledByClient: true,
        action: JsAlertResponseAction.CONFIRM,
      ),
      onJsConfirm: (ctrl, req) async => JsConfirmResponse(
        handledByClient: true,
        action: JsConfirmResponseAction.CANCEL,
      ),
      onConsoleMessage: (ctrl, msg) {
        if (kDebugMode) debugPrint('[web] ${msg.message}');
      },
    );
  }
}
