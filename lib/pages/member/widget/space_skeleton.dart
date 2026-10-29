import 'package:PiliPlus/common/skeleton/skeleton.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/button/more_btn.dart';
import 'package:PiliPlus/common/widgets/dynamic_sliver_app_bar/dynamic_sliver_app_bar.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/models/common/member/tab_type.dart';
import 'package:PiliPlus/models/common/member/user_info_type.dart';
import 'package:PiliPlus/pages/member/widget/header_layout_widget.dart';
import 'package:PiliPlus/pages/member_opus/widgets/opus_grid.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

/// 空间页加载中的骨架，结构对应加载完成后的 `MemberPage` 与 `UserInfoCard`：
/// 头图、头像、名字与数据的位置一致；设置优先展示主页（或默认）时，内容区
/// 对应主页的视频分区，其他标签页的结构各不相同，内容区留空
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
              if (Pref.memberTab case MemberTabType.def || MemberTabType.home)
                const SliverToBoxAdapter(child: _HomeArchiveSkeleton()),
            ],
          ),
        ),
      ],
    );
  }
}

/// 对应 `MemberHome` 的视频分区：标题行与竖版卡片网格，网格参数与行数一致
class _HomeArchiveSkeleton extends StatelessWidget {
  const _HomeArchiveSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = ColorScheme.of(context).onInverseSurface;
    final rows = MediaQuery.widthOf(context) < 600 ? 2 : 1;
    final gridDelegate = OpusGridDelegate(
      mainAxisSpacing: Style.cardSpace,
      crossAxisSpacing: Style.cardSpace,
      maxCrossAxisExtent: Grid.smallCardWidth,
      childAspectRatio: Style.aspectRatio,
      mainAxisExtent: MediaQuery.textScalerOf(context).scale(55),
    );
    return Skeleton(
      child: Column(
        crossAxisAlignment: .start,
        children: [
          // 对应 `MemberHome._header`，文字透明，只保留尺寸
          Padding(
            padding: const .symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisAlignment: .spaceBetween,
              children: [
                ColoredBox(
                  color: color,
                  child: const Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '视频 '),
                        TextSpan(text: '000', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                    style: TextStyle(color: Colors.transparent),
                  ),
                ),
                ColoredBox(
                  color: color,
                  child: IgnorePointer(
                    child: moreTextButton(
                      onTap: () {},
                      color: Colors.transparent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const .symmetric(horizontal: Style.safeSpace),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final info = gridDelegate.calcCrossAxisCount(constraints);
                final card = SizedBox(
                  width: info.childCrossAxisExtent,
                  height: info.childMainAxisExtent,
                  child: _HomeVideoCardSkeleton(color: color),
                );
                return Column(
                  spacing: Style.cardSpace,
                  children: List.filled(
                    rows,
                    Row(
                      spacing: Style.cardSpace,
                      children: List.filled(info.crossAxisCount, card),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 对应 `VideoCardVMemberHome`：封面与两行标题
class _HomeVideoCardSkeleton extends StatelessWidget {
  const _HomeVideoCardSkeleton({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    Widget line(double widthFactor) => FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: .centerLeft,
      child: Container(height: 13, color: color),
    );
    return Card(
      child: Column(
        crossAxisAlignment: .start,
        children: [
          AspectRatio(
            aspectRatio: Style.aspectRatio,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: const .vertical(top: .circular(12)),
              ),
            ),
          ),
          Padding(
            padding: const .fromLTRB(6, 8, 6, 0),
            child: Column(
              spacing: 6,
              crossAxisAlignment: .start,
              children: [line(0.9), line(0.6)],
            ),
          ),
        ],
      ),
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
