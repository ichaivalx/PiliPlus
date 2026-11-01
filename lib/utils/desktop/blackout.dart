import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart'
    show kPrimaryButton, kSecondaryButton;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyUpEvent, LogicalKeyboardKey;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 桌面端一键黑屏：窗口全屏覆盖所在的显示器，画面纯黑、隐藏指针，播放与联动照常；
/// 期间阻止系统关闭显示器或睡眠（显示器的扬声器随之断电）。按 Esc 或鼠标左、
/// 右键点击退出，移动鼠标与滚轮不退出；退出时恢复进入前的窗口状态
class Blackout {
  Blackout._();

  static final instance = Blackout._();

  final active = false.obs;

  /// 进入时窗口不是全屏，退出时恢复
  bool _enteredFullScreen = false;

  _PowerRequest? _power;

  /// 用于退出的这次点击：按下后抬起时退出，整个手势由黑屏层接住
  int? _exitPointer;

  /// 按 Esc 退出后，其抬起也不再交给其他控件
  bool _swallowEscapeUp = false;

  static bool get isSupported => PlatformUtils.isDesktop;

  void enter() {
    if (!isSupported || active.value) return;
    // 桌面小窗时不进入
    if (PlPlayerController.instance?.isDesktopPip ?? false) return;
    final window = WindowController.instance.window;
    if (window == null || !window.isVisible) return;
    _enteredFullScreen = !window.isFullScreen;
    if (_enteredFullScreen) window.isFullScreen = true;
    if (Platform.isWindows) _power = _PowerRequest.create();
    active.value = true;
  }

  void exit() {
    if (!active.value) return;
    active.value = false;
    _exitPointer = null;
    _power?.dispose();
    _power = null;
    if (_enteredFullScreen) {
      _enteredFullScreen = false;
      WindowController.instance.window?.isFullScreen = false;
    }
    PlPlayerController.instance?.controls = true;
  }

  /// 黑屏期间窗口被其他操作退出全屏（如播放结束后自动退出全屏）：重新全屏，
  /// 退出黑屏时恢复为非全屏
  void onWindowExitedFullScreen() {
    if (!active.value) return;
    _enteredFullScreen = true;
    WindowController.instance.window?.isFullScreen = true;
  }

  /// 最先处理的按键：黑屏期间全部由黑屏接住，Esc 退出
  bool handleKey(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        event is KeyUpEvent &&
        _swallowEscapeUp) {
      _swallowEscapeUp = false;
      return true;
    }
    if (!active.value) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        event is KeyDownEvent) {
      _swallowEscapeUp = true;
      exit();
    }
    return true;
  }
}

/// 覆盖整个界面（含提示与弹窗）的黑屏层
class BlackoutLayer extends StatelessWidget {
  const BlackoutLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Blackout.instance.active.value
          ? const _BlackoutScreen()
          : const SizedBox.shrink(),
    );
  }
}

class _BlackoutScreen extends StatefulWidget {
  const _BlackoutScreen();

  @override
  State<_BlackoutScreen> createState() => _BlackoutScreenState();
}

class _BlackoutScreenState extends State<_BlackoutScreen> {
  /// 提示显示的时长，之后淡出为纯黑
  static const _hintDuration = Duration(seconds: 2);
  static const _fadeDuration = Duration(milliseconds: 600);

  /// 很暗的提示文字，避免 OLED 上出现亮点
  static const _hintColor = Color(0xFF262626);

  bool _hint = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_hintDuration, () => setState(() => _hint = false));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons & (kPrimaryButton | kSecondaryButton) != 0) {
      Blackout.instance._exitPointer = event.pointer;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (Blackout.instance._exitPointer == event.pointer) {
      Blackout.instance.exit();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 不透明地接住所有指针事件，按下到抬起的整个手势都不会到达下面的控件
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: (event) {
        if (Blackout.instance._exitPointer == event.pointer) {
          Blackout.instance._exitPointer = null;
        }
      },
      onPointerSignal: (_) {},
      child: MouseRegion(
        cursor: SystemMouseCursors.none,
        opaque: true,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: AnimatedOpacity(
              opacity: _hint ? 1 : 0,
              duration: _fadeDuration,
              child: const Text(
                '按 Esc 或点击退出黑屏',
                // 位于页面之外，不继承页面的文字样式
                style: TextStyle(
                  inherit: false,
                  color: _hintColor,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// REASON_CONTEXT（简单文字原因）
final class _ReasonContext extends Struct {
  @Uint32()
  external int version;

  @Uint32()
  external int flags;

  external Pointer<Utf16> reason;

  /// 联合体其余部分
  @Uint64()
  external int detail1;

  @Uint64()
  external int detail2;
}

/// Windows 电源请求：保持显示器开启、系统不睡眠，不受播放器亮屏设置的影响
class _PowerRequest {
  _PowerRequest._(this._handle, this._reason);

  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _create = _kernel32
      .lookupFunction<
        IntPtr Function(Pointer<_ReasonContext>),
        int Function(Pointer<_ReasonContext>)
      >('PowerCreateRequest');
  static final _set = _kernel32
      .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
        'PowerSetRequest',
      );
  static final _clear = _kernel32
      .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
        'PowerClearRequest',
      );
  static final _close = _kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'CloseHandle',
      );

  static const _contextVersion = 0;
  static const _simpleString = 0x1;
  static const _invalidHandle = -1;
  static const _displayRequired = 0;
  static const _systemRequired = 1;

  final int _handle;
  final Pointer<Utf16> _reason;

  static _PowerRequest? create() {
    final reason = '黑屏播放中'.toNativeUtf16();
    final context = calloc<_ReasonContext>();
    try {
      context.ref
        ..version = _contextVersion
        ..flags = _simpleString
        ..reason = reason;
      final handle = _create(context);
      if (handle == 0 || handle == _invalidHandle) {
        calloc.free(reason);
        return null;
      }
      _set(handle, _displayRequired);
      _set(handle, _systemRequired);
      return _PowerRequest._(handle, reason);
    } finally {
      calloc.free(context);
    }
  }

  void dispose() {
    _clear(_handle, _displayRequired);
    _clear(_handle, _systemRequired);
    _close(_handle);
    calloc.free(_reason);
  }
}
