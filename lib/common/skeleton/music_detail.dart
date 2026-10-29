import 'package:PiliPlus/common/skeleton/skeleton.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:material_ui/material_ui.dart';

/// 音乐详情页的信息卡片，结构对应加载完成后的卡片：封面、标题与歌手、
/// 原唱等信息、热歌榜排名
class MusicCardSkeleton extends StatelessWidget {
  const MusicCardSkeleton({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final color = ColorScheme.of(context).onInverseSurface;
    Widget line(double width, double height) =>
        Container(width: width, height: height, color: color);
    return SizedBox(
      width: width,
      child: Card(
        margin: const .all(8),
        child: Skeleton(
          child: Padding(
            padding: const .all(16),
            child: Column(
              crossAxisAlignment: .start,
              children: [
                Row(
                  spacing: 10,
                  crossAxisAlignment: .start,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: Style.mdRadius,
                      ),
                      child: const SizedBox.square(dimension: 80),
                    ),
                    Expanded(
                      child: Column(
                        spacing: 6,
                        crossAxisAlignment: .start,
                        children: [
                          const SizedBox(height: 2),
                          line(160, 16),
                          line(120, 12),
                          line(60, 14),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                line(200, 14),
                const SizedBox(height: 4),
                line(140, 14),
                const Divider(),
                SizedBox(
                  height: 44,
                  child: Row(
                    mainAxisAlignment: .spaceBetween,
                    children: [
                      line(64, 14),
                      line(44, 30),
                      line(44, 30),
                      line(56, 30),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 音乐详情页的热度趋势图，结构对应加载完成后的标题与图表区域
class MusicChartSkeleton extends StatelessWidget {
  const MusicChartSkeleton({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final color = ColorScheme.of(context).onInverseSurface;
    return Skeleton(
      child: Padding(
        padding: const .only(top: 8),
        child: Column(
          spacing: 8,
          children: [
            Container(width: 120, height: 18, color: color),
            SizedBox(
              width: width,
              height: width * 0.5,
              child: Padding(
                padding: const .only(top: 4, right: 22, left: 55, bottom: 42),
                child: ColoredBox(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
