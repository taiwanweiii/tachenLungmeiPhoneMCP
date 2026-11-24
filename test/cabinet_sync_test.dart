import 'package:curtain_mcp_flutter/features/cabinet/cabinet_sync.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> cab(String uuid, String no,
        {num w = 600, List<Map<String, dynamic>>? props}) =>
    {
      'uuid': uuid,
      'productNo': no,
      'title': '$no 標題',
      'width': w,
      'height': 2400,
      'depth': 580,
      'props': props ??
          [
            {'propsName': 'direction', 'label': '開門方向', 'value': 'L', 'editable': true},
          ],
    };

void main() {
  group('解析與指紋', () {
    test('取出櫃子；少了 uuid 或品號的略過', () {
      final list = parseConfigCabinets([
        cab('u1', 'A01'),
        {'productNo': 'A02'},
        'x',
      ]);
      expect(list.length, 1);
      expect(list.first.dims['width'], 600);
      expect(list.first.props['direction'], 'L');
    });

    test('尺寸或規格不同，指紋就不同', () {
      final a = parseConfigCabinets([cab('u1', 'A01')]);
      final b = parseConfigCabinets([cab('u1', 'A01', w: 800)]);
      expect(configSignature(a), configSignature(a));
      expect(configSignature(a) == configSignature(b), false);
    });
  });

  group('assignSources', () {
    test('同品號依序分配、數量用完換下一個', () {
      const a = PickedItem('A01', '單門', 2);
      const b = PickedItem('A01', '單門', 1, specs: {'width': 800});
      final m = assignSources([
        (uuid: 'u1', productNo: 'A01'),
        (uuid: 'u2', productNo: 'A01'),
        (uuid: 'u3', productNo: 'A01'),
      ], [a, b]);
      expect(m['u1'], a);
      expect(m['u2'], a);
      expect(m['u3'], b);
    });
  });

  group('跟配置頁核對（預設值）', () {
    Map<String, dynamic> cabWith(String uuid) => {
          'uuid': uuid,
          'productNo': 'A01',
          'title': 'A01 標題',
          'width': 450,
          'height': 2304,
          'depth': 580,
          'props': [
            {
              'propsName': 'width', 'label': 'width', 'type': 'SELECT',
              'value': 450, 'editable': true,
              'options': [
                {'label': '60公分', 'value': 600},
                {'label': '45公分', 'value': 450},
              ],
            },
            {
              'propsName': 'direction', 'label': '開門方向', 'type': 'SELECT',
              'value': 'L', 'editable': true,
              'options': {'左開門 <': 'L', '右開門 >': 'R'},
            },
            {
              'propsName': 'marginB', 'label': '上固隔', 'type': 'SELECT',
              'value': 0, 'editable': true,
              'options': {'後縮0cm': 0, '後縮1.0cm': 10},
            },
            // 非挑選頁會讓人選的類型（例如顏色）不收
            {
              'propsName': 'color', 'label': '顏色', 'type': 'COLOR',
              'value': 'x', 'editable': true,
            },
          ],
        };

    test('實際值取出規格（含預設），文字用選項的顯示名稱', () {
      final c = parseConfigCabinets([cabWith('u1')]).first;
      final a = actualSpecs(c);
      // 只有挑選頁會讓人選的規格；顏色（COLOR）和尺寸欄位不收
      expect(a.keys.toSet(), {'width', 'direction', 'marginB'});
      final text = actualText(c, a);
      expect(text, contains('寬度 45公分')); // 標籤是 width → 備援成「寬度」，值用選項名稱
      expect(text, contains('開門方向 左開門 <'));
      expect(text, contains('上固隔 後縮0cm'));
    });

    test('套用：同品號同規格同數量的品項被核對，「還沒選」清掉', () {
      const item = PickedItem('A01', '單門衣櫃', 1,
          missing: ['direction', 'marginB']);
      final cabs = parseConfigCabinets([cabWith('u1')]);
      final r = applyResolved(
        current: [item],
        synced: [item],
        sources: {'u1': item},
        cabinets: cabs,
      );
      expect(r.changed, true);
      expect(r.items.first.verified, true);
      expect(r.items.first.missing, isEmpty);
      expect(r.items.first.actual['direction'], 'L');
      expect(r.items.first.forAi, contains('direction=L'));
      // 再套一次內容一樣 → 不算變動
      final r2 = applyResolved(
        current: r.items,
        synced: [item],
        sources: {'u1': item},
        cabinets: cabs,
      );
      expect(r2.changed, false);
    });

    test('灌進去之後清單又被改過（數量不同）：不動它', () {
      const synced = PickedItem('A01', '單門衣櫃', 1);
      const now = PickedItem('A01', '單門衣櫃', 2);
      final r = applyResolved(
        current: [now],
        synced: [synced],
        sources: {'u1': synced},
        cabinets: parseConfigCabinets([cabWith('u1')]),
      );
      expect(r.changed, false);
      expect(r.items.first.verified, false);
    });

    test('指紋：規格或數量不同就不同', () {
      const a = PickedItem('A01', 'x', 1, specs: {'width': 600});
      const b = PickedItem('A01', 'x', 1, specs: {'width': 450});
      expect(pickedSignature([a]) == pickedSignature([a]), true);
      expect(pickedSignature([a]) == pickedSignature([b]), false);
      expect(pickedSignature([a]) == pickedSignature([a.withQuantity(2)]), false);
    });
  });

  group('配置頁 → 已選清單', () {
    const item = PickedItem('A01', '單門衣櫃', 1,
        specs: {'direction': 'L'}, specText: '開門方向 L');
    final base = parseConfigCabinets([cab('u1', 'A01')]);
    final baseline = {for (final c in base) c.uuid: c};
    final sources = {'u1': item};

    test('在網頁改寬度：只改寬度，其他規格沿用，文字重新產生', () {
      final cur = parseConfigCabinets([cab('u1', 'A01', w: 800)]);
      final r = pickedFromConfig(
          current: cur, baseline: baseline, sources: sources, previous: [item]);
      expect(r.items.length, 1);
      expect(r.items.first.specs['width'], 800);
      expect(r.items.first.specs['direction'], 'L');
      expect(r.items.first.specText, contains('寬度 80公分'));
      expect(r.items.first.name, '單門衣櫃');
    });

    test('沒變的櫃子保留原本的文字', () {
      final cur = parseConfigCabinets([cab('u1', 'A01')]);
      final r = pickedFromConfig(
          current: cur, baseline: baseline, sources: sources, previous: [item]);
      expect(r.items.first.specText, '開門方向 L');
    });

    test('網頁新加同品號的櫃子：數量合併要看規格，新的沒有規格覆蓋', () {
      final cur = parseConfigCabinets([cab('u1', 'A01'), cab('u2', 'A01')]);
      final r = pickedFromConfig(
          current: cur, baseline: baseline, sources: sources, previous: [item]);
      // u1 帶著 direction=L；u2 是新的、沒有覆蓋 → 兩項
      expect(r.items.length, 2);
      expect(r.items.map((e) => e.quantity), [1, 1]);
      expect(r.items.last.name, '單門衣櫃'); // 名稱借用已選清單裡同品號的
    });

    test('兩顆一樣的合併成數量 2', () {
      final two = parseConfigCabinets([cab('u1', 'A01'), cab('u2', 'A01')]);
      final bl = {for (final c in two) c.uuid: c};
      final r = pickedFromConfig(
          current: two,
          baseline: bl,
          sources: {'u1': item, 'u2': item},
          previous: [item]);
      expect(r.items.length, 1);
      expect(r.items.first.quantity, 2);
    });

    test('網頁刪掉櫃子：清單跟著少', () {
      final r = pickedFromConfig(
          current: const [], baseline: baseline, sources: sources, previous: [item]);
      expect(r.items, isEmpty);
    });
  });
}
