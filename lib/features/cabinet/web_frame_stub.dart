import 'package:flutter/widgets.dart';
import 'cabinet_transport.dart';

/// 非 Web 平台用不到 iframe 容器（手機／桌面走原生 WebView）。
Widget buildCabinetFrame({
  required Uri uri,
  required bool interactive,
  required void Function(CabinetTransport transport) onTransport,
  required VoidCallback onLoaded,
  required void Function(Map<String, dynamic> payload) onEvent,
}) =>
    const SizedBox.shrink();
