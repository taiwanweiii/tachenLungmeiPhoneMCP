import 'dart:ui' show Rect;
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late CabinetWebController ctrl;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final session = WebSession();
    await session.init();
    ctrl = CabinetWebController(session);
  });

  test('挑選網址：帶 embed=1 和 mode=pick', () async {
    final f = ctrl.pickProducts();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final q = ctrl.targetUri!.queryParameters;
    expect(q['embed'], '1');
    expect(q['mode'], 'pick');
    expect(ctrl.pickMode, true);
    expect(ctrl.isOpen, true);
    ctrl.close();
    await f;
  });

  test('選好：回傳清單並自動關掉視窗', () async {
    final f = ctrl.pickProducts();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    ctrl.onBridgeEvent({
      'type': 'picked',
      'data': {
        'items': [
          {'productNo': 'A01', 'name': '單門衣櫃', 'quantity': 2},
          {'productNo': 'A02', 'name': '抽屜櫃', 'quantity': 1},
        ],
      },
    });
    final items = await f;
    expect(items, isNotNull);
    expect(items!.map((i) => i.productNo), ['A01', 'A02']);
    expect(items.first.quantity, 2);
    expect(items.first.label, 'A01 單門衣櫃 ×2');
    expect(ctrl.isOpen, false);
    expect(ctrl.pickMode, false);
  });

  test('按取消：回傳 null 並關掉視窗', () async {
    final f = ctrl.pickProducts();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    ctrl.onBridgeEvent({'type': 'pickCancelled', 'data': {}});
    expect(await f, isNull);
    expect(ctrl.isOpen, false);
  });

  test('挑選中直接關掉視窗：視為取消', () async {
    final f = ctrl.pickProducts();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    ctrl.close();
    expect(await f, isNull);
  });

  test('空的選擇或格式不對：回傳 null，不會回傳空清單', () async {
    final f = ctrl.pickProducts();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    ctrl.onBridgeEvent({
      'type': 'picked',
      'data': {'items': []},
    });
    expect(await f, isNull);
  });

  test('連續開兩次：前一次當作取消', () async {
    final first = ctrl.pickProducts();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final second = ctrl.pickProducts();
    expect(await first, isNull);
    ctrl.onBridgeEvent({
      'type': 'picked',
      'data': {
        'items': [
          {'productNo': 'A01', 'name': 'x', 'quantity': 1}
        ]
      },
    });
    expect((await second)!.single.productNo, 'A01');
  });


  group('視窗位置（貼在聊天的文字對話區）', () {
    const dock = Rect.fromLTWH(0, 160, 360, 420);
    final owner = Object();

    test('知道文字對話區的位置：預設只佔那一塊（docked）', () async {
      ctrl.setDockRect(owner, dock);
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ctrl.mode, CabinetPanelMode.docked);
      expect(ctrl.effectiveMode, CabinetPanelMode.docked);
      expect(ctrl.dockRect, dock);
      ctrl.close();
      await f;
    });

    test('不在聊天頁（沒有位置）：改用全螢幕', () async {
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ctrl.mode, CabinetPanelMode.full);
      ctrl.close();
      await f;
    });

    test('放大 → 全螢幕；縮小 → 回到文字對話區', () async {
      ctrl.setDockRect(owner, dock);
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctrl.expand();
      expect(ctrl.effectiveMode, CabinetPanelMode.full);
      ctrl.dock();
      expect(ctrl.effectiveMode, CabinetPanelMode.docked);
      ctrl.close();
      await f;
    });

    test('挑選畫面按縮小：回到文字對話區，不會縮成小視窗', () async {
      ctrl.setDockRect(owner, dock);
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctrl.expand();
      ctrl.minimize();
      expect(ctrl.effectiveMode, CabinetPanelMode.docked);
      ctrl.close();
      await f;
    });

    test('配置畫面可以縮成小視窗，點小視窗回到文字對話區', () async {
      ctrl.setDockRect(owner, dock);
      await ctrl.openNew();
      expect(ctrl.mode, CabinetPanelMode.docked);
      ctrl.minimize();
      expect(ctrl.mode, CabinetPanelMode.mini);
      ctrl.restore();
      expect(ctrl.effectiveMode, CabinetPanelMode.docked);
    });

    test('文字對話區消失（離開聊天頁）：docked 自動改全螢幕；只清自己設的位置', () async {
      ctrl.setDockRect(owner, dock);
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctrl.clearDockRect(Object()); // 別人的，不能清
      expect(ctrl.dockRect, dock);
      ctrl.clearDockRect(owner);
      expect(ctrl.dockRect, isNull);
      expect(ctrl.effectiveMode, CabinetPanelMode.full);
      ctrl.close();
      await f;
    });

    test('位置改變會通知，沒改變不通知', () {
      var n = 0;
      ctrl.addListener(() => n++);
      ctrl.setDockRect(owner, dock); // 還沒開視窗，不通知
      expect(n, 0);
    });
  });


  group('規格', () {
    test('選好的規格會顯示在標籤並附上原樣參數給 AI', () async {
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctrl.onBridgeEvent({
        'type': 'picked',
        'data': {
          'items': [
            {
              'productNo': 'A01',
              'name': '單門衣櫃',
              'quantity': 2,
              'specs': {'width': 600, 'direction': 'L'},
              'specText': '寬度 60公分・開門方向 左開門',
              'missing': ['上固隔'],
            }
          ],
        },
      });
      final it = (await f)!.single;
      expect(it.specs, {'width': 600, 'direction': 'L'});
      expect(it.label, 'A01 單門衣櫃 ×2（寬度 60公分・開門方向 左開門）');
      expect(it.forAi, contains('width=600, direction=L'));
      expect(it.forAi, contains('還沒選：上固隔'));
      expect(it.missing, ['上固隔']);
    });

    test('沒有規格的舊格式照常運作', () {
      const p = PickedItem('A01', '單門衣櫃', 1);
      expect(p.label, 'A01 單門衣櫃 ×1');
      expect(p.forAi, 'A01 單門衣櫃 ×1');
    });

    test('數量調整會保留規格；同產品同規格才能合併', () {
      const a = PickedItem('A01', 'x', 1, specs: {'width': 600});
      expect(a.withQuantity(3).specs, {'width': 600});
      expect(a.sameAs(const PickedItem('A01', 'x', 5, specs: {'width': 600})), true);
      expect(a.sameAs(const PickedItem('A01', 'x', 1, specs: {'width': 450})), false);
      expect(a.sameAs(const PickedItem('A02', 'x', 1, specs: {'width': 600})), false);
    });
  });

  test('數量調整不改原物件', () {
    const p = PickedItem('A01', '單門衣櫃', 1);
    final q = p.withQuantity(3);
    expect(p.quantity, 1);
    expect(q.quantity, 3);
    expect(q.productNo, 'A01');
  });
}
