import 'dart:async';

import 'package:curtain_mcp_flutter/features/cabinet/cabinet_sync.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_transport.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:curtain_mcp_flutter/features/cabinet/wall.dart';
import 'package:curtain_mcp_flutter/services/chat_orchestrator.dart';
import 'package:curtain_mcp_flutter/services/web_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Transport implements CabinetTransport {
  final calls = <(String, List<dynamic>)>[];
  final Map<String, Map<String, dynamic>> replies = {};

  @override
  Future<Map<String, dynamic>> call(String method, List<dynamic> args) async {
    calls.add((method, args));
    return replies[method] ?? {'ok': true};
  }

  @override
  Future<bool> hasBridge() async => true;
  @override
  Future<bool> hasSession() async => true;
  @override
  Future<Map<String, dynamic>> signIn(String u, String p) async => {'ok': true};
  @override
  Future<void> reload(Uri uri) async {}
}

void main() {
  layoutWallTests();
  moveWallTests();
  group('牆面名稱：以面對後牆為視角', () {
    test('代號與中文都認得', () {
      expect(normalizeWall('back'), 'back');
      expect(normalizeWall('left'), 'left');
      expect(normalizeWall('right'), 'right');
      expect(normalizeWall('front'), 'front');
      expect(normalizeWall('後牆'), 'back');
      expect(normalizeWall('左邊'), 'left');
      expect(normalizeWall('右邊'), 'right');
      expect(normalizeWall('前牆'), 'front');
      expect(normalizeWall(' RIGHT '), 'right');
    });

    test('沒給或認不得：null（用預設後牆）', () {
      expect(normalizeWall(null), isNull);
      expect(normalizeWall(''), isNull);
      expect(normalizeWall('天花板'), isNull);
    });

    test('後牆（預設）和沒指定不標牆名，其他牆才標', () {
      expect(wallTagOf(null), '');
      expect(wallTagOf('back'), '');
      expect(wallTagOf('left'), '左牆');
      expect(wallTagOf('right'), '右牆');
      expect(wallTagOf('front'), '前牆');
    });
  });

  group('PickedItem 的牆面', () {
    test('指定右牆：標籤標出右牆，後牆不標', () {
      const right = PickedItem('A01', '單門衣櫃', 1, wall: 'right');
      const back = PickedItem('A01', '單門衣櫃', 1);
      expect(right.label, 'A01 單門衣櫃 ×1（右牆）');
      expect(back.label, 'A01 單門衣櫃 ×1');
    });

    test('牆名與規格文字並列', () {
      const p = PickedItem('A01', '單門衣櫃', 2,
          wall: 'left', specText: '寬度 60公分');
      expect(p.label, 'A01 單門衣櫃 ×2（左牆・寬度 60公分）');
    });

    test('同品號同規格但不同牆：不能合併；沒指定與後牆視為同一面', () {
      const a = PickedItem('A01', 'x', 1, wall: 'left');
      const b = PickedItem('A01', 'x', 1, wall: 'right');
      const c = PickedItem('A01', 'x', 1);
      const d = PickedItem('A01', 'x', 1, wall: 'back');
      expect(a.sameAs(b), false);
      expect(c.sameAs(d), true);
      expect(a.sameAs(a.withQuantity(3)), true);
    });

    test('改數量、套用實際值之後牆面還在', () {
      const p = PickedItem('A01', 'x', 1, wall: 'right');
      expect(p.withQuantity(2).wall, 'right');
      expect(p.withActual({'width': 600}, '').wall, 'right');
    });

    test('pickedSignature 會因牆面不同而不同（才會重新同步）', () {
      const a = PickedItem('A01', 'x', 1, wall: 'left');
      const b = PickedItem('A01', 'x', 1, wall: 'right');
      expect(pickedSignature([a]) == pickedSignature([b]), false);
    });
  });

  group('AI 的 pick_product 參數 → 預選', () {
    test('帶 wall：進到預選的 items', () {
      final p = ChatOrchestrator.buildPreselect(
          {'productNo': 'A01', 'quantity': 2, 'wall': 'right'});
      final item = (p!['items'] as List).single as Map;
      expect(item['wall'], 'right');
      expect(item['quantity'], 2);
    });

    test('wall 寫中文也能整理成代號', () {
      final p = ChatOrchestrator.buildPreselect(
          {'productNo': 'A01', 'wall': '左邊'});
      expect(((p!['items'] as List).single as Map)['wall'], 'left');
    });

    test('沒說方位：不帶 wall（預設後牆）；認不得的也不帶', () {
      final none = ChatOrchestrator.buildPreselect({'productNo': 'A01'});
      expect(((none!['items'] as List).single as Map).containsKey('wall'), false);
      final bogus =
          ChatOrchestrator.buildPreselect({'productNo': 'A01', 'wall': '天花板'});
      expect(((bogus!['items'] as List).single as Map).containsKey('wall'), false);
    });
  });

  group('挑選頁回傳 → 已選清單', () {
    late CabinetWebController ctrl;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final session = WebSession();
      await session.init();
      ctrl = CabinetWebController(session);
    });

    test('picked 事件的 wall 會帶進 PickedItem', () async {
      final f = ctrl.pickProducts();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctrl.onBridgeEvent({
        'type': 'picked',
        'data': {
          'items': [
            {'productNo': 'A01', 'name': '單門衣櫃', 'quantity': 1, 'wall': 'right'},
            {'productNo': 'A02', 'name': '抽屜櫃', 'quantity': 1, 'wall': null},
          ],
        },
      });
      final items = await f;
      expect(items![0].wall, 'right');
      expect(items[1].wall, isNull);
    });
  });

  group('同步進配置頁時把 wall 交給網頁', () {
    late CabinetWebController ctrl;
    late _Transport tp;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final session = WebSession();
      await session.init();
      ctrl = CabinetWebController(session);
      tp = _Transport()
        ..replies['whenReady'] = {'ok': true}
        ..replies['getState'] = {'ok': true, 'price': 0, 'cabinets': []}
        ..replies['applyDraft'] = {'ok': true, 'added': []};
      await ctrl.openNew();
      ctrl.attachTransport(tp);
      await ctrl.onPageLoaded();
      await ctrl.waitUntilReady(timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      tp.calls.clear();
    });

    test('有指定牆的帶 wall，沒指定的不帶', () async {
      // 送出後 syncCabinets 還會等網頁回報櫃子穩定（假網頁一直回空清單），這裡只看送出的內容，不等它收尾
      unawaited(ctrl.syncCabinets(const [
        PickedItem('A01', '單門衣櫃', 1, wall: 'left'),
        PickedItem('A02', '抽屜櫃', 2),
      ]));
      for (var i = 0;
          i < 40 && !tp.calls.any((c) => c.$1 == 'applyDraft');
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final apply = tp.calls.firstWhere((c) => c.$1 == 'applyDraft');
      final cabinets = ((apply.$2.first as Map)['cabinets'] as List).cast<Map>();
      expect(cabinets[0]['productNo'], 'A01');
      expect(cabinets[0]['wall'], 'left');
      expect(cabinets[1]['productNo'], 'A02');
      expect(cabinets[1].containsKey('wall'), false);
    });
  });
}

void layoutWallTests() {
  group('發送到聊天後把牆面寫回已選清單', () {
    test('網頁回報在右牆：已選項目變右牆', () {
      final r = applyWallsFromLayout(
          [const PickedItem('F06', '轉角桌', 1)],
          [{'productNo': 'F06', 'wall': 'right'}]);
      expect(r.single.wall, 'right');
    });
    test('同品號 2 個分在不同牆：拆成兩項', () {
      final r = applyWallsFromLayout(
          [const PickedItem('A01', 'x', 2)],
          [{'productNo': 'A01', 'wall': 'left'}, {'productNo': 'A01', 'wall': 'back'}]);
      expect(r.length, 2);
      expect(r.map((e) => e.wall).toSet(), {'left', null});
    });
    test('網頁沒回報牆面：維持原樣', () {
      final r = applyWallsFromLayout(
          [const PickedItem('A01', 'x', 1, wall: 'left')],
          [{'productNo': 'A01'}]);
      expect(r.single.wall, 'left');
    });
  });
}

void moveWallTests() {
  group('AI 要把已選櫃子換牆', () {
    test('全部換到右牆', () {
      final r = moveWall([const PickedItem('A', 'a', 1), const PickedItem('B', 'b', 2)], 'right');
      expect(r.map((e) => e.wall), ['right', 'right']);
    });
    test('只換指定品號；換回後牆變 null', () {
      final r = moveWall([const PickedItem('A', 'a', 1, wall: 'left'), const PickedItem('B', 'b', 1)], 'back', productNo: 'A');
      expect(r[0].wall, isNull);
      expect(r[1].wall, isNull);
    });
    test('拆數量：2 個衣櫃，1 個放左、1 個放右', () {
      var r = movePicked([const PickedItem('A01', 'a', 2)],
          wall: 'left', productNo: 'A01', count: 1);
      r = movePicked(r, wall: 'right', productNo: 'A01', count: 1);
      expect(r.length, 2);
      expect(r.map((e) => e.wall).toSet(), {'left', 'right'});
      expect(r.every((e) => e.quantity == 1), true);
    });
    test('拆數量：3 個先全放右，再拿 1 個去左；數量對得上', () {
      var r = movePicked([const PickedItem('A01', 'a', 3)],
          wall: 'right', productNo: 'A01');
      r = movePicked(r, wall: 'left', productNo: 'A01', count: 1);
      expect(r.firstWhere((e) => e.wall == 'right').quantity, 2);
      expect(r.firstWhere((e) => e.wall == 'left').quantity, 1);
    });
    test('拆數量：count 比數量大就整個搬；不影響別的品號', () {
      final r = movePicked([
        const PickedItem('A01', 'a', 2),
        const PickedItem('F06', 'f', 1),
      ], wall: 'left', productNo: 'A01', count: 5);
      expect(r.firstWhere((e) => e.productNo == 'A01').wall, 'left');
      expect(r.firstWhere((e) => e.productNo == 'A01').quantity, 2);
      expect(r.firstWhere((e) => e.productNo == 'F06').wall, isNull);
    });
    test('排序：衣櫃排到右牆第 1 個（轉角桌原本第 1）', () {
      final r = movePicked([
        const PickedItem('F06', 'f', 1, wall: 'right'),
        const PickedItem('A02', 'a', 1, wall: 'right'),
        const PickedItem('C01', 'c', 1, wall: 'left'),
      ], productNo: 'A02', position: 1);
      expect(r.map((e) => e.productNo), ['A02', 'F06', 'C01']);
    });
    test('排序：換牆同時指定第 2 個', () {
      final r = movePicked([
        const PickedItem('F06', 'f', 1, wall: 'right'),
        const PickedItem('B01', 'b', 1, wall: 'right'),
        const PickedItem('A02', 'a', 1, wall: 'left'),
      ], wall: 'right', productNo: 'A02', position: 2);
      expect(r.map((e) => e.productNo), ['F06', 'A02', 'B01']);
      expect(r[1].wall, 'right');
    });
    test('排序：位置超過就排最後；數量 2 的品項佔兩個位置', () {
      final r = movePicked([
        const PickedItem('F06', 'f', 2, wall: 'right'),
        const PickedItem('B01', 'b', 1, wall: 'right'),
        const PickedItem('A02', 'a', 1, wall: 'right'),
      ], productNo: 'A02', position: 3);
      expect(r.map((e) => e.productNo), ['F06', 'A02', 'B01']);
      final last = movePicked([
        const PickedItem('A02', 'a', 1, wall: 'right'),
        const PickedItem('F06', 'f', 1, wall: 'right'),
      ], productNo: 'A02', position: 9);
      expect(last.map((e) => e.productNo), ['F06', 'A02']);
    });
    test('換牆後變成同一面的相同櫃子會合併', () {
      final r = moveWall([const PickedItem('A', 'a', 1, wall: 'left'), const PickedItem('A', 'a', 1, wall: 'right')], 'right');
      expect(r.length, 1);
      expect(r.single.quantity, 2);
    });
  });
}
