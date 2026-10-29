import 'package:PiliPlus/common/sliver_single_child_delegate.dart';
import 'package:PiliPlus/common/skeleton/skeleton.dart';
import 'package:PiliPlus/common/skeleton/video_card_h.dart';
import 'package:PiliPlus/common/widgets/dynamic_sliver_app_bar/dynamic_sliver_app_bar.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/models/common/member/user_info_type.dart';
import 'package:PiliPlus/pages/member/widget/header_layout_widget.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:material_ui/material_ui.dart';

/// 空间页加载中的骨架，结构对应加载完成后的 `MemberPage` 与 `UserInfoCard`：
/// 头图、头像、名字与数据的位置一致
class MemberSpaceSkeleton extends StatelessWidget {
  const MemberSpaceSkeleton({
    super.key,
    required this.isOwner,
    required this.actions,
  });

  final bool isOwner;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    return CustomScrollView(
      physics: const NeverScrollableScrollPhysics(),
      slivers: [
        DynamicSliverAppBar.medium(
          title: const Text(''),
          actions: actions,
          flexibleSpace: Skeleton(child: _UserInfoSkeleton(isOwner: isOwner)),
        ),
        SliverPadding(
          padding: .only(left: padding.left, right: padding.right),
          sliver: SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Container(
                  height: 45,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: colorScheme.outline.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                ),
              ),
              SliverGrid(
                gridDelegate: Grid.videoCardHDelegate(),
                delegate: const SliverSingleChildDelegate(
                  count: 10,
                  child: VideoCardHSkeleton(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 对应 `UserInfoCard` 的竖屏与横屏布局，头像按无挂件时的尺寸
class _UserInfoSkeleton extends StatelessWidget {
  const _UserInfoSkeleton({required this.isOwner});

  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final color = colorScheme.onInverseSurface;
    final isPortrait = MediaQuery.widthOf(context) < 600;
    final avatar = _buildAvatar(colorScheme, color);
    final left = _buildLeft(color);
    final right = _buildRight(colorScheme, color);
    return ViewSafeArea(
      top: !isPortrait,
      child: isPortrait
          ? Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                HeaderLayoutWidget(
                  header: SizedBox(
                    width: .infinity,
                    height: kHeaderHeight,
                    child: ColoredBox(color: color),
                  ),
                  avatar: avatar,
                  actions: right,
                ),
                const SizedBox(height: 5),
                ...left,
                const SizedBox(height: 5),
              ],
            )
          : Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                const SizedBox(height: kToolbarHeight),
                Row(
                  children: [
                    const SizedBox(width: 20),
                    Padding(
                      padding: const .symmetric(vertical: 10),
                      child: avatar,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 5,
                      child: Column(
                        mainAxisSize: .min,
                        crossAxisAlignment: .start,
                        children: [
                          const SizedBox(height: 10),
                          ...left,
                          const SizedBox(height: 5),
                        ],
                      ),
                    ),
                    Expanded(flex: 3, child: right),
                    const SizedBox(width: 20),
                  ],
                ),
              ],
            ),
    );
  }

  static Widget _buildAvatar(ColorScheme colorScheme, Color color) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: .all(width: 2, color: colorScheme.surface),
        shape: .circle,
      ),
      child: Padding(
        padding: const .all(2),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: .circle),
          child: const SizedBox.square(dimension: kAvatarSize),
        ),
      ),
    );
  }

  /// 名字、签名与其他信息；名字的行高对应 `UserInfoCard._buildName`
  static List<Widget> _buildLeft(Color color) => [
    Padding(
      padding: const .symmetric(horizontal: 20),
      child: ColoredBox(
        color: color,
        child: const SizedBox(
          width: 120,
          child: Text(
            '',
            strutStyle: StrutStyle(
              height: 1,
              leading: 0,
              fontSize: 17,
              fontWeight: .bold,
            ),
            style: TextStyle(height: 1, fontSize: 17, fontWeight: .bold),
          ),
        ),
      ),
    ),
    Padding(
      padding: const .only(left: 20, top: 8, right: 20),
      child: ColoredBox(
        color: color,
        child: const SizedBox(
          width: 200,
          child: Text('', style: TextStyle(fontSize: 14)),
        ),
      ),
    ),
    Padding(
      padding: const .only(left: 20, top: 8, right: 20),
      child: ColoredBox(
        color: color,
        child: const SizedBox(
          width: 150,
          child: Text('', style: TextStyle(fontSize: 12)),
        ),
      ),
    ),
  ];

  /// 数据与按钮，高度对应 `UserInfoCard._buildRight`
  Widget _buildRight(ColorScheme colorScheme, Color color) => Column(
    spacing: 5,
    mainAxisSize: .min,
    children: [
      Row(
        children: UserInfoType.values
            .map(
              (e) => Expanded(
                child: Align(
                  alignment: e.alignment,
                  widthFactor: 1.0,
                  child: Column(
                    mainAxisSize: .min,
                    children: [
                      ColoredBox(
                        color: color,
                        child: const Text(
                          '0000',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.transparent,
                          ),
                        ),
                      ),
                      Text(
                        e.title,
                        style: TextStyle(
                          height: 1.2,
                          fontSize: 12,
                          color: colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
            .expand((child) sync* {
              yield const SizedBox(
                height: 15,
                width: 1,
                child: VerticalDivider(),
              );
              yield child;
            })
            .skip(1)
            .toList(),
      ),
      Row(
        spacing: 10,
        mainAxisSize: .min,
        children: [
          if (!isOwner)
            DecoratedBox(
              decoration: BoxDecoration(
                shape: .circle,
                border: .all(
                  color: colorScheme.outline.withValues(alpha: 0.3),
                ),
              ),
              child: const SizedBox.square(dimension: 32),
            ),
          const Expanded(
            child: FilledButton.tonal(
              onPressed: null,
              style: ButtonStyle(
                padding: WidgetStatePropertyAll(.zero),
                tapTargetSize: .padded,
                visualDensity: VisualDensity(vertical: -1.8),
              ),
              child: SizedBox.shrink(),
            ),
          ),
        ],
      ),
    ],
  );
}
