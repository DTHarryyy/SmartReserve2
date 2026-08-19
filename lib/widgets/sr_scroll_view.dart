import 'package:flutter/material.dart';

class SrScrollView extends StatefulWidget {
  const SrScrollView({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  State<SrScrollView> createState() => _SrScrollViewState();
}

class _SrScrollViewState extends State<SrScrollView> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _controller,
    child: SingleChildScrollView(
      controller: _controller,
      padding: widget.padding,
      child: widget.child,
    ),
  );
}
