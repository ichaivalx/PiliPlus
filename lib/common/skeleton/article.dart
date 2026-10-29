import 'package:PiliPlus/common/skeleton/skeleton.dart';
import 'package:material_ui/material_ui.dart';

/// 专栏、图文正文，结构对应加载完成后的标题、作者与正文段落
class ArticleSkeleton extends StatelessWidget {
  const ArticleSkeleton({super.key});

  /// 正文各行的宽度比例
  static const _lines = [1.0, 1.0, 0.92, 1.0, 0.64, 1.0, 0.96, 1.0, 0.8, 0.5];

  @override
  Widget build(BuildContext context) {
    final color = ColorScheme.of(context).onInverseSurface;
    Widget line(double widthFactor, double height) => FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: .centerLeft,
      child: Container(height: height, color: color),
    );
    return Skeleton(
      child: Column(
        crossAxisAlignment: .start,
        children: [
          const SizedBox(height: 2),
          line(0.7, 18),
          Padding(
            padding: const .symmetric(vertical: 10),
            child: Row(
              spacing: 10,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(color: color, shape: .circle),
                  child: const SizedBox.square(dimension: 40),
                ),
                Column(
                  spacing: 6,
                  crossAxisAlignment: .start,
                  children: [
                    Container(width: 80, height: 14, color: color),
                    Container(width: 60, height: 11, color: color),
                  ],
                ),
              ],
            ),
          ),
          for (final widthFactor in _lines)
            Padding(
              padding: const .only(bottom: 10),
              child: line(widthFactor, 14),
            ),
        ],
      ),
    );
  }
}
