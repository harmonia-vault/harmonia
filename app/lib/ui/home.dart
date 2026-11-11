// 首页保留独立页面状态，窗口调整由工作台处理。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/updater.dart';
import 'workspace.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.c});
  final AppController c;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => checkForUpdate(context, manual: false, channel: widget.c.updateChannel),
    );
  }

  @override
  Widget build(BuildContext context) => Workspace(c: widget.c);
}
