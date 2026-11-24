import 'package:flutter/widgets.dart';
import 'cabinet_web_controller.dart';

/// 標出「聊天的文字對話區」在螢幕上的位置。
///
/// 系統櫃視窗（挑選產品、配置畫面）預設只貼在這一塊上，不蓋住整個螢幕；
/// 要全螢幕時使用者再按「放大」。位置會在每次畫面更新、鍵盤彈出或視窗大小改變後重新回報。
class DockRegion extends StatefulWidget {
  const DockRegion({super.key, required this.controller, required this.child});

  final CabinetWebController controller;
  final Widget child;

  @override
  State<DockRegion> createState() => _DockRegionState();
}

class _DockRegionState extends State<DockRegion> with WidgetsBindingObserver {
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.clearDockRect(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _scheduleReport();

  void _scheduleReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  void _report() {
    if (!mounted) return;
    final ro = _key.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
    widget.controller.setDockRect(this, ro.localToGlobal(Offset.zero) & ro.size);
  }

  @override
  Widget build(BuildContext context) {
    _scheduleReport();
    return KeyedSubtree(key: _key, child: widget.child);
  }
}
