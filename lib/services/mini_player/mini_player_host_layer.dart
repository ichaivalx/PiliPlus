import 'dart:async' show Completer;

import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:PiliPlus/services/mini_player/mini_player_window.dart';
import 'package:flutter/foundation.dart' show mergeSort;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 宿主中详情页所处的状态
enum MiniHostState {
  /// 通过窗口显示（被内容页覆盖的过程中仍为此状态）
  shown,

  /// 被页面覆盖且未转入小窗，按上游的离开处理
  parked,

  /// 收起为小窗，详情页不显示但照常运行
  mini,

  /// 新打开的视频入场期间仍在其下方显示，入场结束后释放
  outgoing,

  /// 窗口出栈，随其转场离开后释放
  closing,
}

/// 一个视频详情页的宿主：详情页在宿主层中保持存在，展开、收起与被覆盖
/// 只改变其显示方式，不重建页面
class MiniPlayerHostEntry extends ChangeNotifier {
  MiniPlayerHostEntry(
    this.args, {
    this.hidden = false,
    this.deferPlayer = false,
    this.resume = MiniPlayerResume.playing,
  }) : heroTag = args['heroTag'];

  final Map<String, dynamic> args;
  final String heroTag;

  /// 构建时不显示（在小窗中切换、回到上一个视频），首次显示前等待内容到达
  final bool hidden;

  /// 播放器空出（显示中的其他详情页离开）前不接管播放器，由会话通知接管
  bool deferPlayer;

  /// 回到旧视频时按其离开时的播放状态恢复：已暂停的接管播放器后保持
  /// 暂停，尚未开始播放的等待用户开始
  final MiniPlayerResume resume;

  MiniHostState state = MiniHostState.shown;

  /// 详情页在浏览历史中的位置
  MiniPlayerWindowRoute? anchor;

  /// 从小窗展开时临时推入的窗口
  MiniPlayerWindowRoute? presented;

  MiniPlayerWindowRoute? get window => presented ?? anchor;

  /// 宿主 Navigator 中唯一的路由，页面的控制器、面板与 PopScope 都属于它
  late final MiniPlayerDetailRoute route = MiniPlayerDetailRoute(this);

  MiniPlayerHost? _page;
  MiniPlayerHost? get page => _page;
  final _attached = Completer<void>();

  /// 页面初始化后接入，宿主构建前为 null
  Future<void> get attached => _attached.future;

  void attach(MiniPlayerHost page) {
    _page = page;
    if (!_attached.isCompleted) {
      _attached.complete();
    }
  }

  void detach(MiniPlayerHost page) {
    if (identical(_page, page)) {
      _page = null;
    }
  }

  bool _painted = false;
  bool get painted => _painted;

  /// 绘制顺序：负数位于浏览 Navigator 下方并按窗口在栈中的位置排列，
  /// 正数位于其上方
  int _z = -1;
  int get z => _z;

  void updateLayer({required bool painted, required int z}) {
    if (_painted != painted || _z != z) {
      _painted = painted;
      _z = z;
      notifyListeners();
    }
  }

  /// 呈现所用的窗口或其转场变化
  final presentation = _Notifier();

  void presentationChanged() => presentation.notify();

  @override
  void dispose() {
    presentation.dispose();
    super.dispose();
  }
}

class _Notifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// 宿主中的详情页路由：没有自身的转场，显示所用窗口的转场
class MiniPlayerDetailRoute extends GetPageRoute<void> {
  MiniPlayerDetailRoute(this.host)
    : super(
        page: () => const VideoDetailPageV(),
        routeName: MiniPlayerPolicy.videoRoute,
        settings: RouteSettings(
          name: MiniPlayerPolicy.videoRoute,
          arguments: host.args,
        ),
      );

  final MiniPlayerHostEntry host;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => ListenableBuilder(
    listenable: host.presentation,
    builder: (context, child) =>
        host.window?.buildPresentation(context, child!) ?? child!,
    child: child,
  );
}

/// 详情页内的组件据此找到其所属的宿主路由
class MiniPlayerHostScope extends InheritedWidget {
  const MiniPlayerHostScope({
    super.key,
    required this.host,
    required super.child,
  });

  final MiniPlayerHostEntry host;

  /// 不建立依赖，可在 initState 中调用
  static MiniPlayerHostEntry? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MiniPlayerHostScope>()?.host;

  /// 宿主中的组件注册面板、PopScope 等所用的路由，不在宿主中时为 null
  static Route<dynamic>? routeOf(BuildContext context) =>
      maybeOf(context)?.route;

  @override
  bool updateShouldNotify(MiniPlayerHostScope oldWidget) =>
      !identical(host, oldWidget.host);
}

/// 宿主层：各宿主与浏览 Navigator 位于同一层，宿主默认位于其下方，透过
/// 窗口显示；窗口自身转场期间位于其上方，按窗口的转场覆盖下方页面
class MiniPlayerHostLayer extends StatelessWidget {
  const MiniPlayerHostLayer({super.key, required this.child});

  final Widget child;

  static const _browsingKey = ValueKey('browsing');

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: miniPlayerSession.layer,
    builder: (context, child) => _PresentationStack(
      children: [
        for (final host in miniPlayerSession.hosts)
          ListenableBuilder(
            key: ObjectKey(host),
            listenable: host,
            builder: (context, child) => _PresentationChild(
              z: host.z,
              child: Offstage(
                offstage: !host.painted,
                child: TickerMode(
                  enabled: host.painted,
                  child: ExcludeFocus(excluding: !host.painted, child: child!),
                ),
              ),
            ),
            child: _HostContent(host: host),
          ),
        _PresentationChild(key: _browsingKey, z: 0, child: child!),
      ],
    ),
    child: child,
  );
}

class _HostContent extends StatelessWidget {
  const _HostContent({required this.host});

  final MiniPlayerHostEntry host;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: MiniPlayerHostScope(
      host: host,
      child: HeroControllerScope.none(
        child: _HostScope(
          host: host,
          child: _HostNavigator(host: host),
        ),
      ),
    ),
  );
}

/// 详情页在布局时构建（与 [LayoutBuilder] 相同），构建与布局期间创建的
/// 依赖归属本宿主的详情页路由，读取的路由参数为本宿主的参数；宿主不显示
/// 时浏览栈中的当前路由属于其他页面，懒加载的区域（如标签页中的相关视频）
/// 同样随详情页释放
class _HostScope extends ConstrainedLayoutBuilder<BoxConstraints> {
  _HostScope({required this.host, required Widget child})
    : super(builder: (_, _) => child);

  final MiniPlayerHostEntry host;

  @override
  RenderAbstractLayoutBuilderMixin<BoxConstraints, RenderBox>
  createRenderObject(BuildContext context) => _RenderHostScope(host);

  @override
  void updateRenderObject(BuildContext context, _RenderHostScope renderObject) {
    renderObject.host = host;
  }
}

class _RenderHostScope extends RenderBox
    with
        RenderObjectWithChildMixin<RenderBox>,
        RenderObjectWithLayoutCallbackMixin,
        RenderAbstractLayoutBuilderMixin<BoxConstraints, RenderBox> {
  _RenderHostScope(this.host);

  MiniPlayerHostEntry host;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    miniPlayerSession.runInHost(host, () {
      runLayoutCallback();
      child?.layout(BoxConstraints.tight(size));
    });
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      child?.hitTest(result, position: position) ?? false;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child case final child?) {
      context.paintChild(child, offset);
    }
  }
}

/// 只持有详情页路由，提供 Overlay 与焦点等；推入、出栈一律交给浏览
/// Navigator，从详情页打开的弹窗与页面都位于浏览栈中
class _HostNavigator extends Navigator {
  _HostNavigator({required MiniPlayerHostEntry host})
    : super(onGenerateInitialRoutes: (_, _) => [host.route]);

  @override
  NavigatorState createState() => _HostNavigatorState();
}

class _HostNavigatorState extends NavigatorState {
  NavigatorState get _browsing => Get.key.currentState!;

  @override
  Future<T?> push<T extends Object?>(Route<T> route) => _browsing.push(route);

  @override
  Future<T?> pushNamed<T extends Object?>(
    String routeName, {
    Object? arguments,
  }) => _browsing.pushNamed(routeName, arguments: arguments);

  @override
  Future<T?> pushReplacement<T extends Object?, TO extends Object?>(
    Route<T> newRoute, {
    TO? result,
  }) => _browsing.pushReplacement(newRoute, result: result);

  @override
  Future<T?> pushReplacementNamed<T extends Object?, TO extends Object?>(
    String routeName, {
    TO? result,
    Object? arguments,
  }) => _browsing.pushReplacementNamed(
    routeName,
    result: result,
    arguments: arguments,
  );

  @override
  Future<T?> pushAndRemoveUntil<T extends Object?>(
    Route<T> newRoute,
    RoutePredicate predicate,
  ) => _browsing.pushAndRemoveUntil(newRoute, predicate);

  @override
  Future<T?> pushNamedAndRemoveUntil<T extends Object?>(
    String newRouteName,
    RoutePredicate predicate, {
    Object? arguments,
  }) => _browsing.pushNamedAndRemoveUntil(
    newRouteName,
    predicate,
    arguments: arguments,
  );

  @override
  void pop<T extends Object?>([T? result]) => _browsing.pop(result);

  @override
  Future<bool> maybePop<T extends Object?>([T? result]) =>
      _browsing.maybePop(result);

  @override
  bool canPop() => _browsing.canPop();

  @override
  void popUntil(RoutePredicate predicate) => _browsing.popUntil(predicate);
}

class _PresentationParentData extends ContainerBoxParentData<RenderBox> {
  int z = 0;
}

class _PresentationChild extends ParentDataWidget<_PresentationParentData> {
  const _PresentationChild({super.key, required this.z, required super.child});

  final int z;

  @override
  void applyParentData(RenderObject renderObject) {
    final parentData = renderObject.parentData! as _PresentationParentData;
    if (parentData.z != z) {
      parentData.z = z;
      renderObject.parent?.markNeedsPaint();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _PresentationStack;
}

/// 子节点铺满，按 z 绘制与命中；改变顺序只重排图层，不重新构建
class _PresentationStack extends MultiChildRenderObjectWidget {
  const _PresentationStack({required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPresentationStack();
}

class _RenderPresentationStack extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PresentationParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PresentationParentData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PresentationParentData) {
      child.parentData = _PresentationParentData();
    }
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final constraints = BoxConstraints.tight(size);
    var child = firstChild;
    while (child != null) {
      child.layout(constraints);
      child = childAfter(child);
    }
  }

  List<RenderBox> get _ordered {
    final children = getChildrenAsList();
    mergeSort(
      children,
      compare: (a, b) =>
          (a.parentData! as _PresentationParentData).z -
          (b.parentData! as _PresentationParentData).z,
    );
    return children;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _ordered) {
      context.paintChild(child, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _ordered.reversed) {
      if (child.hitTest(result, position: position)) {
        return true;
      }
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) =>
      _ordered.forEach(visitor);
}
