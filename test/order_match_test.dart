import 'package:curtain_mcp_flutter/features/cabinet/cabinet_sync.dart';
import 'package:curtain_mcp_flutter/features/cabinet/cabinet_web_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// 背景頁核對過規格的已選品項
PickedItem item(String pn, int qty, Map<String, dynamic> actual, {String? wall}) =>
    PickedItem(pn, pn, qty, actual: actual, wall: wall);

void main() {
  group('訂單跟背景頁算的清單是不是同一份（是才直接存）', () {
    final picked = [
      item('A01', 2, {'width': 600, 'height': 2000, 'direction': 'L', 'marginB': 0}),
      item('F07', 1, {'width': 1200, 'direction': 'R'}),
    ];

    test('品號、數量、規格都一樣（順序不同、大小寫不同也算）', () {
      expect(
          orderMatchesPicked([
            {'productNo': 'f07', 'direction': 'r'},
            {'productNo': 'A01', 'width': 600, 'direction': 'L'},
            {'productNo': 'A01', 'width': 600, 'params': {'marginB': 0}},
          ], picked),
          isTrue);
    });

    test('數量不一樣', () {
      expect(
          orderMatchesPicked([
            {'productNo': 'A01'},
            {'productNo': 'F07'},
          ], picked),
          isFalse);
    });

    test('AI 改了規格（寬度不同）', () {
      expect(
          orderMatchesPicked([
            {'productNo': 'A01', 'width': 800},
            {'productNo': 'A01', 'width': 600},
            {'productNo': 'F07'},
          ], picked),
          isFalse);
    });

    test('訂單有寫、背景頁沒算到的規格', () {
      expect(
          orderMatchesPicked([
            {'productNo': 'A01', 'depth': 580},
            {'productNo': 'A01'},
            {'productNo': 'F07'},
          ], picked),
          isFalse);
    });

    test('品號不一樣', () {
      expect(
          orderMatchesPicked([
            {'productNo': 'A01'},
            {'productNo': 'A01'},
            {'productNo': 'A02'},
          ], picked),
          isFalse);
    });

    test('還有沒核對過的（背景頁還沒算完）', () {
      expect(
          orderMatchesPicked([
            {'productNo': 'A01'},
          ], [const PickedItem('A01', 'A01', 1)]),
          isFalse);
    });

    test('分在不同牆面（quick_order 一次只建一面牆）', () {
      expect(
          orderMatchesPicked([
            {'productNo': 'A01'},
            {'productNo': 'F07'},
          ], [
            item('A01', 1, {'width': 600}),
            item('F07', 1, {'width': 1200}, wall: 'left'),
          ]),
          isFalse);
    });

    test('沒有櫃子', () {
      expect(orderMatchesPicked([], picked), isFalse);
      expect(orderMatchesPicked([{'productNo': 'A01'}], []), isFalse);
    });
  });
}
