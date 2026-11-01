import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:ffi/ffi.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart'
    show isDesktopFullScreen;
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerCancelEvent,
        PointerDownEvent,
        PointerEvent,
        PointerPanZoomEndEvent,
        PointerPanZoomStartEvent,
        PointerUpEvent,
        kPrimaryButton,
        kSecondaryButton;
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyUpEvent,
        LogicalKeyboardKey;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 桌面端一键黑屏：窗口全屏覆盖所在的显示器，画面纯黑、隐藏指针，播放与联动照常；
/// 期间阻止系统关闭显示器或睡眠（显示器的扬声器随之断电）。按 Esc 或鼠标左、
/// 右键点击退出，移动鼠标与滚轮不退出；退出时恢复进入前的窗口状态
class Blackout {
  Blackout._() {
    if (isSupported) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_trackPointer);
    }
  }

  static final instance = Blackout._();

  final active = false.obs;

  /// 进入时窗口不是全屏，退出时恢复
  bool _enteredFullScreen = false;

  /// 因最小化或隐藏而结束，窗口重新显示时再恢复为非全屏
  bool _restoreOnShow = false;

  _PowerRequest? _power;

  /// 用于退出的这次点击：按下后抬起时退出，整个手势由黑屏层接住
  int? _exitPointer;

  /// 按下中的指针与进行中的触摸板手势：要进入时有（如正在拖动进度条、双指
  /// 滑动），等全部结束、这次操作照常完成后再进入
  final Set<int> _pressed = {};
  bool _pending = false;

  /// 由黑屏接住的按键：其重复与抬起在退出后也不再交给其他控件，直到松开
  final Set<LogicalKeyboardKey> _swallowed = {};

  static bool get isSupported => PlatformUtils.isDesktop;

  void _trackPointer(PointerEvent event) {
    if (event is PointerDownEvent || event is PointerPanZoomStartEvent) {
      _pressed.add(event.pointer);
    } else if (event is PointerUpEvent ||
        event is PointerCancelEvent ||
        event is PointerPanZoomEndEvent) {
      _pressed.remove(event.pointer);
      if (_pending && _pressed.isEmpty) {
        _pending = false;
        _activate();
      }
    }
  }

  void enter() {
    if (!isSupported || active.value) return;
    if (_pressed.isNotEmpty) {
      _pending = true;
      return;
    }
    _activate();
  }

  void _activate() {
    if (active.value) return;
    final player = PlPlayerController.instance;
    // 桌面小窗时不进入
    if (player?.isDesktopPip ?? false) return;
    final window = WindowController.instance.window;
    if (window == null || !window.isVisible) return;
    _restoreOnShow = false;
    _enteredFullScreen = !window.isFullScreen;
    if (_enteredFullScreen) window.isFullScreen = true;
    if (Platform.isWindows) _power = _PowerRequest.create();
    // 按住中的键的抬起将由黑屏接住，其长按效果（连调音量、临时倍速、连续快退）
    // 在此结束
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    _swallowed.addAll(pressed);
    if (player != null) {
      player.cancelLongPressTimer();
      if (player.longPressStatus.value) player.setLongPressStatus(false);
      if (pressed.contains(LogicalKeyboardKey.arrowLeft)) {
        player.isSeeking.value = false;
      }
    }
    active.value = true;
  }

  /// [restoreWindow] 为 false 时（最小化、隐藏）窗口等重新显示时再恢复
  void exit({bool restoreWindow = true}) {
    _pending = false;
    if (!active.value) return;
    active.value = false;
    _exitPointer = null;
    _power?.dispose();
    _power = null;
    if (_enteredFullScreen) {
      _enteredFullScreen = false;
      if (restoreWindow) {
        _restoreWindow();
      } else {
        _restoreOnShow = true;
      }
    }
    PlPlayerController.instance?.controls = true;
  }

  /// 恢复为非全屏；播放器此时处于窗口全屏（如期间打开了自动全屏的视频）则保持
  void _restoreWindow() {
    if (isDesktopFullScreen) return;
    WindowController.instance.window?.isFullScreen = false;
  }

  /// 窗口在最小化或隐藏后重新显示
  void onWindowShown() {
    if (!_restoreOnShow || active.value) return;
    _restoreOnShow = false;
    _restoreWindow();
  }

  /// 黑屏期间窗口被其他操作退出全屏（如播放结束后自动退出全屏）：重新全屏，
  /// 退出黑屏时恢复为非全屏
  void onWindowExitedFullScreen() {
    if (!active.value) return;
    _enteredFullScreen = true;
    WindowController.instance.window?.isFullScreen = true;
  }

  /// 最先处理的按键：黑屏期间全部由黑屏接住，Esc 退出；接住的键在退出后松开前
  /// 的重复与抬起也接住
  bool handleKey(KeyEvent event) {
    final key = event.logicalKey;
    if (active.value) {
      if (event is KeyDownEvent) {
        _swallowed.add(key);
        if (key == LogicalKeyboardKey.escape) exit();
      } else if (event is KeyUpEvent) {
        _swallowed.remove(key);
      }
      return true;
    }
    if (event is KeyDownEvent) {
      _swallowed.remove(key);
      return false;
    }
    if (event is KeyUpEvent) return _swallowed.remove(key);
    return _swallowed.contains(key);
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
