import 'package:curtain_mcp_flutter/core/config/app_config.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_draft_flow.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_transport.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:curtain_mcp_flutter/services/mcp_client_service.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假的網頁容器：記錄 App 對網頁橋接的呼叫
class FakeTransport implements CabinetTransport {
  final calls = <(String, List<dynamic>)>[];
  bool session = true;
  final Map<String, Map<String, dynamic>> replies = {};

  @override
  Future<Map<String, dynamic>> call(String method, List<dynamic> args) async {
    calls.add((method, args));
    return replies[method] ?? {'ok': true};
  }

  @override
  Future<bool> hasBridge() async => true;
  @override
  Future<bool> hasSession() async => session;
  @override
  Future<Map<String, dynamic>> signIn(String u, String p) async => {'ok': true};
  @override
  Future<void> reload(Uri uri) async {}
}

/// 假的 MCP：記錄 HTTP 呼叫、回傳固定草稿
class FakeMcp extends McpClientService {
  FakeMcp() : super(Dio(), AppConfig());
  final requests = <(String, String, Object?)>[];
  dynamic draft;

  @override
  Future<dynamic> httpJson(String method, String path, {Object? body}) async {
    requests.add((method, path, body));
    if (method == 'GET') {
      if (draft == null) throw Exception('找不到案件的待套用草稿');
      return draft;
    }
    return {'removed': 1};
  }
}

Map<String, dynamic> cab(String id, String status, String pn) => {
      'localId': id,
      'productNo': pn,
      'status': status,
      'params': {'width': 600},
    };

void main() {
  late WebSession session;
  late CabinetWebController ctrl;
  late FakeMcp mcp;
  late FakeTransport tp;
  late CabinetDraftFlow flow;

  const link =
      'https://p3dweb.example.com/app/store-price/261100M/A/1?draft=261100M&space=s1&wall=w1';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    session = WebSession();
    await session.init();
    ctrl = CabinetWebController(session);
    mcp = FakeMcp();
    tp = FakeTransport()
      ..replies['whenReady'] = {'ok': true}
      ..replies['getState'] = {'ok': true, 'price': 1000, 'cabinets': []}
      ..replies['applyDraft'] = {'ok': true, 'added': []};
    mcp.draft = {
      'spaces': [
        {
          'localId': 's1',
          'walls': [
            {
              'localId': 'w1',
              'cabinets': [
                cab('c1', 'I', 'A01'),
                cab('c2', 'U', 'A02'), // 不是新增，不應套入
                cab('c3', 'I', 'A03'),
              ],
            },
            {
              'localId': 'w2',
              'cabinets': [cab('c9', 'I', 'ZZZ')], // 別面牆，不應套入
            },
          ],
        },
      ],
    };
    flow = CabinetDraftFlow(ctrl, mcp);
  });

  /// 模擬容器建好並載入完成
  Future<void> loadPage() async {
    ctrl.attachTransport(tp);
    await ctrl.onPageLoaded();
    await ctrl.waitUntilReady(timeout: const Duration(seconds: 5));
    // 讓 flow 後續的 applyDraft 跑完
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  test('不是 store-price 草稿連結：不攔截', () {
    expect(flow.handleLink('https://example.com/app/order/store/261100M?newFlow=true&draft=a&space=s1&wall=w1'), false);
    expect(flow.handleLink('https://example.com/app/store-price/261100M/A/1'), false);
    expect(flow.handleLink('not a url %%'), false);
    expect(ctrl.isOpen, false);
  });

  test('攔截連結：開啟該案件、只套入這面牆的新增柜子', () async {
    expect(flow.handleLink(link), true);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 視窗開在編輯既有案件的網址上，而且一定帶 embed=1
    expect(ctrl.isOpen, true);
    final q = ctrl.targetUri!.queryParameters;
    expect(q['embed'], '1');
    expect(q['caseNo'], '261100M');
    expect(q['roomId'], 'A');
    expect(q['closetId'], '1');
    expect(mcp.requests.first.$1, 'GET');
    expect(mcp.requests.first.$2, '/drafts/261100M');

    await loadPage();

    final apply = tp.calls.firstWhere((c) => c.$1 == 'applyDraft');
    final payload = apply.$2[0] as Map;
    final applied = (payload['cabinets'] as List).map((c) => (c as Map)['productNo']).toList();
    expect(applied, ['A01', 'A03']); // 沒有 U 的 A02，也沒有別面牆的 ZZZ
    expect((apply.$2[1] as Map)['clear'], false); // 保留案件原有櫃體
    // 在使用者確認之前，絕不能自動更新案件
    expect(tp.calls.any((c) => c.$1 == 'updateCase'), false);
    expect(tp.calls.any((c) => c.$1 == 'submit'), false);
  });

  test('存檔成功後回報 MCP 已套用的柜子；存檔前不回報', () async {
    flow.handleLink(link);
    await loadPage();
    expect(mcp.requests.where((r) => r.$1 == 'POST'), isEmpty);

    ctrl.onBridgeEvent({
      'type': 'saved',
      'data': {'caseNo': '261100M', 'updated': true},
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final post = mcp.requests.where((r) => r.$1 == 'POST').toList();
    expect(post.length, 1);
    expect(post.first.$2, '/drafts/261100M/applied');
    expect((post.first.$3 as Map)['cabinets'], ['s1:w1:c1', 's1:w1:c3']);

    // 同一批不會重複回報
    ctrl.onBridgeEvent({'type': 'saved', 'data': {'updated': true}});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(mcp.requests.where((r) => r.$1 == 'POST').length, 1);
  });

  test('草稿取不到：顯示錯誤，不套入、不回報', () async {
    mcp.draft = null;
    flow.handleLink(link);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ctrl.error, contains('取得草稿失敗'));
    expect(tp.calls.any((c) => c.$1 == 'applyDraft'), false);
  });

  test('這面牆沒有新增柜子：顯示錯誤', () async {
    mcp.draft = {
      'spaces': [
        {
          'localId': 's1',
          'walls': [
            {'localId': 'w1', 'cabinets': [cab('c2', 'U', 'A02')]},
          ],
        },
      ],
    };
    flow.handleLink(link);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ctrl.error, contains('沒有要新增'));
  });
}
