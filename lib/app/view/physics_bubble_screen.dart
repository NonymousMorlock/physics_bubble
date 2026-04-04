// Painter-heavy code uses sequential canvas commands where cascades read worse.
// ignore_for_file: cascade_invocations

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

const _bottomOrbRatio = 0.92;
const _topOrbRatio = 0.28;
const _maxOrbRadius = 250.0;
const _minOrbRadius = 85.0;
const _textYBottomRatio = 0.48;
const _textYTopRatio = 0.42;
const _snapUnlockThreshold = 10.0;
const _dragOvershootRatio = 0.05;
const _deformationFactor = 0.015;
const _deformationClamp = 0.6;
const _velocitySmoothing = 0.15;
const _themeRevealDuration = Duration(milliseconds: 1100);
const _popDuration = Duration(milliseconds: 150);
const _popDelay = Duration(milliseconds: 2000);
const _themeMorphStiffness = 300.0;
const _themeMorphDamping = 26.0;
const _toggleScaleStiffness = 400.0;
const _toggleScaleDamping = 24.0;
const _snapSpringStiffness = 200.0;
const _snapSpringDamping = 18.4;
const _unlockedSpringDamping = 12.8;
const _deformationSpringStiffness = 1500.0;
const _deformationSpringDamping = 34.8;
const _shaderAsset = 'shaders/physics_bubble.frag';
const _platformChannel = MethodChannel('physics_bubble/platform');

class PhysicsBubbleScreen extends StatefulWidget {
  const PhysicsBubbleScreen({super.key});

  @override
  State<PhysicsBubbleScreen> createState() => _PhysicsBubbleScreenState();
}

class _PhysicsBubbleScreenState extends State<PhysicsBubbleScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  ui.FragmentShader? _shader;
  _BubbleShaderBindings? _shaderBindings;

  Duration? _lastTick;
  Duration? _themeRevealStartedAt;
  Duration? _popStartedAt;
  int? _androidSdkInt;

  bool _hasLayout = false;
  bool _isDarkTheme = false;
  bool _previousIsDarkTheme = false;
  bool _isDragging = false;
  bool _isUnlocked = false;
  bool _snapToTop = false;

  int? _activePointer;
  Offset? _pointerStartPosition;
  Offset? _lastPointerPosition;
  bool _ignoreActivePointer = false;

  _BubbleLayout? _layout;

  double _bubbleX = 0;
  double _bubbleY = 0;
  double _bubbleVelocityX = 0;
  double _bubbleVelocityY = 0;
  double _bubbleTargetX = 0;
  double _bubbleTargetY = 0;
  double _deformationX = 0;
  double _deformationY = 0;
  double _deformationVelocityX = 0;
  double _deformationVelocityY = 0;
  double _smoothedVelocityX = 0;
  double _smoothedVelocityY = 0;
  double _previousBubbleX = 0;
  double _previousBubbleY = 0;
  double _shaderTime = 0;
  double _themeMorphProgress = 0;
  double _themeMorphVelocity = 0;
  double _toggleScale = 1;
  double _toggleScaleVelocity = 0;
  double _themeRevealProgress = 1;
  double _popProgress = 0;
  double _snapDamping = _snapSpringDamping;

  final Cubic _themeRevealCurve = const Cubic(0.1, 0.8, 0.2, 1);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_handleTick);
    unawaited(_ticker.start());
    unawaited(_loadAndroidSdkInt());
    unawaited(_loadShader());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  Future<void> _loadShader() async {
    if (!ui.ImageFilter.isShaderFilterSupported) {
      return;
    }

    try {
      final program = await ui.FragmentProgram.fromAsset(_shaderAsset);
      if (!mounted) {
        return;
      }

      final shader = program.fragmentShader();
      final shaderBindings = _BubbleShaderBindings(shader);
      setState(() {
        _shader?.dispose();
        _shader = shader;
        _shaderBindings = shaderBindings;
      });
    } on Exception {
      _shader?.dispose();
      _shader = null;
      _shaderBindings = null;
    }
  }

  Future<void> _loadAndroidSdkInt() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    try {
      final sdkInt = await _platformChannel.invokeMethod<int>('sdkInt');
      if (!mounted || sdkInt == null) {
        return;
      }

      setState(() {
        _androidSdkInt = sdkInt;
      });
    } on MissingPluginException {
      // Widget tests and non-Android hosts do not provide this channel.
    } on PlatformException {
      // Ignore platform lookup failures and avoid substituting
      // a broader fallback.
    }
  }

  void _handleTick(Duration elapsed) {
    final layout = _layout;
    if (layout == null) {
      _lastTick = elapsed;
      return;
    }

    final lastTick = _lastTick;
    _lastTick = elapsed;
    if (lastTick == null) {
      _previousBubbleX = _bubbleX;
      _previousBubbleY = _bubbleY;
      return;
    }

    final dt = math.min(
      (elapsed - lastTick).inMicroseconds / Duration.microsecondsPerSecond,
      0.032,
    );
    if (dt <= 0) {
      return;
    }

    _shaderTime = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _updateThemeAnimations(dt, elapsed);
    _updatePopState(elapsed, layout);

    if (!_isDragging && _popStartedAt == null) {
      _stepBubbleSnap(dt);
    }

    _updateDeformation(dt);

    _previousBubbleX = _bubbleX;
    _previousBubbleY = _bubbleY;

    if (mounted) {
      setState(() {});
    }
  }

  void _updateThemeAnimations(double dt, Duration elapsed) {
    final themeMorphTarget = _isDarkTheme ? 1.0 : 0.0;
    final themeMorph = _stepSpring(
      value: _themeMorphProgress,
      velocity: _themeMorphVelocity,
      target: themeMorphTarget,
      stiffness: _themeMorphStiffness,
      damping: _themeMorphDamping,
      dt: dt,
    );
    _themeMorphProgress = themeMorph.value;
    _themeMorphVelocity = themeMorph.velocity;

    final scaleSpring = _stepSpring(
      value: _toggleScale,
      velocity: _toggleScaleVelocity,
      target: 1,
      stiffness: _toggleScaleStiffness,
      damping: _toggleScaleDamping,
      dt: dt,
    );
    _toggleScale = scaleSpring.value;
    _toggleScaleVelocity = scaleSpring.velocity;

    if (_themeRevealStartedAt == null) {
      _themeRevealProgress = 1;
      return;
    }

    final normalized =
        ((elapsed - _themeRevealStartedAt!).inMilliseconds /
                _themeRevealDuration.inMilliseconds)
            .clamp(0, 1)
            .toDouble();
    _themeRevealProgress = _themeRevealCurve.transform(normalized);
    if (normalized >= 1) {
      _themeRevealStartedAt = null;
      _themeRevealProgress = 1;
    }
  }

  void _updatePopState(Duration elapsed, _BubbleLayout layout) {
    if (_popStartedAt == null) {
      _popProgress = 0;
      return;
    }

    final elapsedSincePop = elapsed - _popStartedAt!;
    if (elapsedSincePop <= _popDuration) {
      final normalized =
          elapsedSincePop.inMicroseconds / _popDuration.inMicroseconds;
      _popProgress = Curves.easeIn.transform(
        normalized.clamp(0.0, 1.0),
      );
      return;
    }

    if (elapsedSincePop <= _popDuration + _popDelay) {
      _popProgress = 1;
      return;
    }

    _popStartedAt = null;
    _popProgress = 0;
    _isDragging = false;
    _isUnlocked = false;
    _bubbleVelocityX = 0;
    _bubbleVelocityY = 0;
    _deformationX = 0;
    _deformationY = 0;
    _deformationVelocityX = 0;
    _deformationVelocityY = 0;
    _smoothedVelocityX = 0;
    _smoothedVelocityY = 0;
    _bubbleX = layout.centerX;
    _bubbleY = layout.bottomOrbCenterY;
    _bubbleTargetX = _bubbleX;
    _bubbleTargetY = _bubbleY;
    _previousBubbleX = _bubbleX;
    _previousBubbleY = _bubbleY;
  }

  void _stepBubbleSnap(double dt) {
    final targetDistance = math.sqrt(
      math.pow(_bubbleTargetX - _bubbleX, 2) +
          math.pow(_bubbleTargetY - _bubbleY, 2),
    );
    final velocityMagnitude = math.sqrt(
      _bubbleVelocityX * _bubbleVelocityX + _bubbleVelocityY * _bubbleVelocityY,
    );

    if (targetDistance < 0.5 && velocityMagnitude < 0.5) {
      _bubbleX = _bubbleTargetX;
      _bubbleY = _bubbleTargetY;
      _bubbleVelocityX = 0;
      _bubbleVelocityY = 0;
      _isUnlocked = _snapToTop;
      return;
    }

    final xSpring = _stepSpring(
      value: _bubbleX,
      velocity: _bubbleVelocityX,
      target: _bubbleTargetX,
      stiffness: _snapSpringStiffness,
      damping: _snapDamping,
      dt: dt,
    );
    final ySpring = _stepSpring(
      value: _bubbleY,
      velocity: _bubbleVelocityY,
      target: _bubbleTargetY,
      stiffness: _snapSpringStiffness,
      damping: _snapDamping,
      dt: dt,
    );

    _bubbleX = xSpring.value;
    _bubbleVelocityX = xSpring.velocity;
    _bubbleY = ySpring.value;
    _bubbleVelocityY = ySpring.velocity;
  }

  void _updateDeformation(double dt) {
    final rawVelocityX = _bubbleX - _previousBubbleX;
    final rawVelocityY = _bubbleY - _previousBubbleY;

    _smoothedVelocityX +=
        (rawVelocityX - _smoothedVelocityX) * _velocitySmoothing;
    _smoothedVelocityY +=
        (rawVelocityY - _smoothedVelocityY) * _velocitySmoothing;

    if (_popProgress > 0) {
      _deformationX = 0;
      _deformationY = 0;
      _deformationVelocityX = 0;
      _deformationVelocityY = 0;
      return;
    }

    final targetX = (_smoothedVelocityX * _deformationFactor).clamp(
      -_deformationClamp,
      _deformationClamp,
    );
    final targetY = (_smoothedVelocityY * _deformationFactor).clamp(
      -_deformationClamp,
      _deformationClamp,
    );

    final springX = _stepSpring(
      value: _deformationX,
      velocity: _deformationVelocityX,
      target: targetX,
      stiffness: _deformationSpringStiffness,
      damping: _deformationSpringDamping,
      dt: dt,
    );
    final springY = _stepSpring(
      value: _deformationY,
      velocity: _deformationVelocityY,
      target: targetY,
      stiffness: _deformationSpringStiffness,
      damping: _deformationSpringDamping,
      dt: dt,
    );

    _deformationX = springX.value;
    _deformationVelocityX = springX.velocity;
    _deformationY = springY.value;
    _deformationVelocityY = springY.velocity;
  }

  void _ensureLayout(_BubbleLayout layout) {
    final previousLayout = _layout;
    if (previousLayout != null &&
        previousLayout.size == layout.size &&
        previousLayout.safeTopInset == layout.safeTopInset) {
      return;
    }

    _layout = layout;

    if (!_hasLayout) {
      _bubbleX = layout.centerX;
      _bubbleY = layout.bottomOrbCenterY;
      _bubbleTargetX = _bubbleX;
      _bubbleTargetY = _bubbleY;
      _previousBubbleX = _bubbleX;
      _previousBubbleY = _bubbleY;
      _hasLayout = true;
      return;
    }

    if (previousLayout != null) {
      final progress = previousLayout.progressFor(_bubbleY);
      final horizontalOffset = _bubbleX - previousLayout.centerX;
      _bubbleX = layout.centerX + horizontalOffset;
      _bubbleY = ui.lerpDouble(
        layout.bottomOrbCenterY,
        layout.topOrbCenterY,
        progress,
      )!;
      _bubbleTargetX = layout.centerX;
      _bubbleTargetY = _snapToTop
          ? layout.topOrbCenterY
          : layout.bottomOrbCenterY;
      _previousBubbleX = _bubbleX;
      _previousBubbleY = _bubbleY;
    }
  }

  bool get _showLegacyFallbackBubble =>
      _androidSdkInt != null && _androidSdkInt! < 33;

  void _onDragStart() {
    if (_layout == null || _popStartedAt != null) {
      return;
    }

    _isDragging = true;
    _bubbleVelocityX = 0;
    _bubbleVelocityY = 0;
    _isUnlocked = _isAtTop(_layout!);
  }

  void _onDragUpdate(Offset delta) {
    final layout = _layout;
    if (layout == null || _popStartedAt != null) {
      return;
    }

    final proposedY = _bubbleY + delta.dy;
    if (!_isUnlocked && proposedY <= layout.topOrbCenterY) {
      _isUnlocked = true;
    }

    if (_isUnlocked) {
      _bubbleX += delta.dx;
      _bubbleY = proposedY;
    } else {
      _bubbleX = layout.centerX;
      _bubbleY = proposedY.clamp(double.negativeInfinity, layout.maxDragY);
    }
  }

  void _onDragEnd() {
    final layout = _layout;
    if (layout == null || _popStartedAt != null) {
      return;
    }

    _isDragging = false;
    _snapToTop = _bubbleY < layout.midPoint;
    _bubbleTargetX = layout.centerX;
    _bubbleTargetY = _snapToTop
        ? layout.topOrbCenterY
        : layout.bottomOrbCenterY;
    _snapDamping = _isUnlocked && _snapToTop
        ? _unlockedSpringDamping
        : _snapSpringDamping;
  }

  void _handlePointerDown(PointerDownEvent event, Rect toggleRect) {
    if (_activePointer != null) {
      return;
    }

    _activePointer = event.pointer;
    _pointerStartPosition = event.localPosition;
    _lastPointerPosition = event.localPosition;
    _ignoreActivePointer = toggleRect.contains(event.localPosition);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer || _ignoreActivePointer) {
      return;
    }

    final start = _pointerStartPosition;
    final last = _lastPointerPosition;
    if (start == null || last == null) {
      return;
    }

    if (!_isDragging && (event.localPosition - start).distance > kTouchSlop) {
      _onDragStart();
    }

    if (_isDragging) {
      _onDragUpdate(event.localPosition - last);
    }

    _lastPointerPosition = event.localPosition;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) {
      return;
    }

    if (!_ignoreActivePointer) {
      if (_isDragging) {
        _onDragEnd();
      } else {
        _onScreenTap();
      }
    }

    _resetPointerTracking();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) {
      return;
    }

    if (_isDragging && !_ignoreActivePointer) {
      _onDragEnd();
    }

    _resetPointerTracking();
  }

  void _resetPointerTracking() {
    _activePointer = null;
    _pointerStartPosition = null;
    _lastPointerPosition = null;
    _ignoreActivePointer = false;
  }

  void _onScreenTap() {
    if (_popStartedAt != null || _layout == null) {
      return;
    }

    _popStartedAt = _lastTick ?? Duration.zero;
  }

  void _toggleTheme() {
    if (_themeRevealStartedAt != null) {
      return;
    }

    _previousIsDarkTheme = _isDarkTheme;
    _isDarkTheme = !_isDarkTheme;
    _themeRevealStartedAt = _lastTick ?? Duration.zero;
    _themeRevealProgress = 0;
    _toggleScale = 0.85;
    _toggleScaleVelocity = 0;
    setState(() {});
  }

  bool _isAtTop(_BubbleLayout layout) =>
      _bubbleY <= layout.topOrbCenterY + _snapUnlockThreshold;

  @override
  Widget build(BuildContext context) {
    final overlayStyle = _isDarkTheme
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final mediaPadding = MediaQuery.paddingOf(context);
            final layout = _BubbleLayout.fromSize(
              Size(constraints.maxWidth, constraints.maxHeight),
              mediaPadding.top,
            );
            _ensureLayout(layout);

            final progress = layout.progressFor(_bubbleY);
            final orbRadius = layout.orbRadiusFor(progress);
            final textOffsetY = layout.textYOffsetFor(progress);
            final toggleRect = Rect.fromLTWH(
              constraints.maxWidth - 24 - 48,
              mediaPadding.top + 16,
              48,
              48,
            );

            final mainTextColor = Color.lerp(
              _BubbleColors.lightMainText,
              _BubbleColors.darkMainText,
              _themeMorphProgress,
            )!;
            final titleColor = Color.lerp(
              _BubbleColors.lightTitle,
              _BubbleColors.darkTitle,
              _themeMorphProgress,
            )!;
            final subtitleColor = Color.lerp(
              _BubbleColors.lightSubtitle,
              _BubbleColors.darkSubtitle,
              _themeMorphProgress,
            )!;

            final bubbleScene = Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _ThemeBackgroundPainter(
                    isDarkTheme: _isDarkTheme,
                    previousIsDarkTheme: _previousIsDarkTheme,
                    revealProgress: _themeRevealProgress,
                    revealEpicenter: layout.revealEpicenter,
                  ),
                ),
                Positioned(
                  top: mediaPadding.top + 16,
                  right: 24,
                  child: _ThemeToggleButton(
                    progress: _themeMorphProgress,
                    scale: _toggleScale,
                    onTap: _toggleTheme,
                  ),
                ),
                Align(
                  child: Transform.translate(
                    offset: const Offset(0, -80),
                    child: Opacity(
                      opacity: (1 - (progress * 4)).clamp(0, 1),
                      child: Text(
                        'Pixels are now\nphysical.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: mainTextColor,
                          fontSize: 32,
                          height: 1.25,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
                Transform.translate(
                  offset: Offset(0, textOffsetY),
                  child: Align(
                    child: Opacity(
                      opacity: (progress * 3).clamp(0, 1),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'AGSL Pipelines',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: titleColor,
                              fontSize: 44,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -1,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Real-time thin-film interference\n'
                            'driven by kinematic springs.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: subtitleColor,
                              fontSize: 24,
                              height: 1.08,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_shader == null && _showLegacyFallbackBubble)
                  CustomPaint(
                    painter: _BubbleFallbackPainter(
                      center: Offset(_bubbleX, _bubbleY),
                      radius: orbRadius,
                      deformation: Offset(_deformationX, _deformationY),
                      popProgress: _popProgress,
                    ),
                  ),
              ],
            );

            final filteredScene = _buildFilteredScene(
              orbRadius: orbRadius,
              scene: bubbleScene,
            );

            return Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) => _handlePointerDown(event, toggleRect),
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: filteredScene,
            );
          },
        ),
      ),
    );
  }

  Widget _buildFilteredScene({
    required double orbRadius,
    required Widget scene,
  }) {
    final shader = _shader;
    final shaderBindings = _shaderBindings;
    if (shader == null || shaderBindings == null) {
      return scene;
    }

    shaderBindings.touchCenter.set(_bubbleX, _bubbleY);
    shaderBindings.radius.set(orbRadius);
    shaderBindings.deformation.set(_deformationX, _deformationY);
    shaderBindings.popProgress.set(_popProgress);
    shaderBindings.time.set(_shaderTime);

    return ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.shader(shader),
        child: scene,
      ),
    );
  }
}

class _BubbleShaderBindings {
  _BubbleShaderBindings(ui.FragmentShader shader)
    : touchCenter = shader.getUniformVec2('u_touchCenter'),
      radius = shader.getUniformFloat('u_radius'),
      deformation = shader.getUniformVec2('u_deformation'),
      popProgress = shader.getUniformFloat('u_popProgress'),
      time = shader.getUniformFloat('u_time');

  final ui.UniformVec2Slot touchCenter;
  final ui.UniformFloatSlot radius;
  final ui.UniformVec2Slot deformation;
  final ui.UniformFloatSlot popProgress;
  final ui.UniformFloatSlot time;
}

class _ThemeToggleButton extends StatelessWidget {
  const _ThemeToggleButton({
    required this.progress,
    required this.scale,
    required this.onTap,
  });

  final double progress;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Toggle theme',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Transform.scale(
            scale: scale,
            child: SizedBox(
              width: 48,
              height: 48,
              child: CustomPaint(
                painter: _ThemeTogglePainter(progress: progress),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeTogglePainter extends CustomPainter {
  const _ThemeTogglePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.width / 2;
    const sunColor = Color(0xFFFDB813);
    const moonColor = Color(0xFFE5E5EA);
    final currentColor = Color.lerp(sunColor, moonColor, progress)!;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate((-math.pi / 2) * progress);
    canvas.translate(-center.dx, -center.dy);

    final rayAlpha = (1 - progress * 2.5).clamp(0.0, 1.0);
    if (rayAlpha > 0) {
      final rayPaint = Paint()
        ..color = currentColor.withValues(alpha: rayAlpha)
        ..strokeWidth = maxRadius * 0.15
        ..strokeCap = StrokeCap.round;

      final rayLength = maxRadius * 0.25;
      final rayOffset = maxRadius * 0.6;
      for (var i = 0; i < 8; i++) {
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate((math.pi / 4) * i);
        canvas.translate(-center.dx, -center.dy);
        canvas.drawLine(
          Offset(center.dx, center.dy - rayOffset),
          Offset(center.dx, center.dy - rayOffset - rayLength),
          rayPaint,
        );
        canvas.restore();
      }
    }

    final sunRadius = maxRadius * 0.45;
    final moonRadius = maxRadius * 0.85;
    final currentRadius = ui.lerpDouble(sunRadius, moonRadius, progress)!;

    final mainPath = Path()
      ..addOval(
        Rect.fromCircle(center: center, radius: currentRadius),
      );

    final cutoutStart = Offset(
      center.dx + maxRadius * 2,
      center.dy - maxRadius * 2,
    );
    final cutoutEnd = Offset(
      center.dx + currentRadius * 0.3,
      center.dy - currentRadius * 0.3,
    );
    final cutoutCenter = Offset(
      ui.lerpDouble(cutoutStart.dx, cutoutEnd.dx, progress)!,
      ui.lerpDouble(cutoutStart.dy, cutoutEnd.dy, progress)!,
    );
    final cutoutPath = Path()
      ..addOval(
        Rect.fromCircle(center: cutoutCenter, radius: currentRadius * 0.95),
      );

    final finalPath = Path.combine(
      ui.PathOperation.difference,
      mainPath,
      cutoutPath,
    );

    final fillPaint = Paint()..color = currentColor;
    canvas.drawPath(finalPath, fillPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ThemeTogglePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _ThemeBackgroundPainter extends CustomPainter {
  const _ThemeBackgroundPainter({
    required this.isDarkTheme,
    required this.previousIsDarkTheme,
    required this.revealProgress,
    required this.revealEpicenter,
  });

  final bool isDarkTheme;
  final bool previousIsDarkTheme;
  final double revealProgress;
  final Offset revealEpicenter;

  @override
  void paint(Canvas canvas, Size size) {
    final previousPaint = Paint()
      ..shader = _backgroundShaderFor(size, previousIsDarkTheme);
    final currentPaint = Paint()
      ..shader = _backgroundShaderFor(size, isDarkTheme);

    canvas.drawRect(Offset.zero & size, previousPaint);

    if (revealProgress < 1) {
      final maxRadius = math.sqrt(
        (size.width * size.width) + (size.height * size.height),
      );
      final radius = revealProgress * maxRadius;
      final clipPath = Path()
        ..addOval(Rect.fromCircle(center: revealEpicenter, radius: radius));

      canvas.save();
      canvas.clipPath(clipPath);
      canvas.drawRect(Offset.zero & size, currentPaint);
      canvas.restore();
      return;
    }

    canvas.drawRect(Offset.zero & size, currentPaint);
  }

  ui.Shader _backgroundShaderFor(Size size, bool dark) {
    final colors = dark
        ? <Color>[
            _BubbleColors.darkCenter,
            _BubbleColors.darkMid,
            _BubbleColors.darkMid,
            _BubbleColors.darkEdge,
          ]
        : <Color>[
            _BubbleColors.lightCenter,
            _BubbleColors.lightMid1,
            _BubbleColors.lightMid2,
            _BubbleColors.lightEdge,
          ];

    return ui.Gradient.radial(
      Offset(size.width / 2, size.height * 0.4),
      size.longestSide * 0.72,
      colors,
      const [0, 0.3, 0.7, 1],
    );
  }

  @override
  bool shouldRepaint(covariant _ThemeBackgroundPainter oldDelegate) {
    return oldDelegate.isDarkTheme != isDarkTheme ||
        oldDelegate.previousIsDarkTheme != previousIsDarkTheme ||
        oldDelegate.revealProgress != revealProgress ||
        oldDelegate.revealEpicenter != revealEpicenter;
  }
}

class _BubbleFallbackPainter extends CustomPainter {
  const _BubbleFallbackPainter({
    required this.center,
    required this.radius,
    required this.deformation,
    required this.popProgress,
  });

  final Offset center;
  final double radius;
  final Offset deformation;
  final double popProgress;

  @override
  void paint(Canvas canvas, Size size) {
    if (popProgress >= 1) {
      return;
    }

    final activeRadius = radius * (1 + (popProgress * 1.5));
    final speed = deformation.distance;
    final stretch = 1 + speed;
    final squash = 1 / math.sqrt(stretch);
    final angle = speed > 0.001
        ? math.atan2(deformation.dy, deformation.dx)
        : 0.0;
    final alpha = 1 - math.sqrt(popProgress);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    if (speed > 0.001) {
      canvas.rotate(angle);
    }
    canvas.scale(stretch, squash);

    final bubbleRect = Rect.fromCircle(
      center: Offset.zero,
      radius: activeRadius,
    );
    final fillPaint = Paint()
      ..shader = ui.Gradient.radial(
        Offset(-activeRadius * 0.15, -activeRadius * 0.2),
        activeRadius,
        [
          Colors.white.withValues(alpha: 0.28 * alpha),
          const Color(0x66AEE7FF).withValues(alpha: 0.18 * alpha),
          Colors.transparent,
        ],
        const [0, 0.55, 1],
      );
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, activeRadius * 0.03)
      ..shader = ui.Gradient.sweep(
        Offset.zero,
        [
          const Color(0xFFFF8AAE).withValues(alpha: 0.45 * alpha),
          const Color(0xFF8ED6FF).withValues(alpha: 0.35 * alpha),
          const Color(0xFFFFF5AE).withValues(alpha: 0.45 * alpha),
          const Color(0xFFFF8AAE).withValues(alpha: 0.45 * alpha),
        ],
        const [0, 0.33, 0.66, 1],
      );
    final highlightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, activeRadius * 0.02)
      ..color = Colors.white.withValues(alpha: 0.6 * alpha)
      ..strokeCap = StrokeCap.round;

    canvas.drawOval(bubbleRect, fillPaint);
    canvas.drawOval(bubbleRect, rimPaint);
    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: activeRadius * 0.7),
      -math.pi * 0.95,
      math.pi * 0.42,
      false,
      highlightPaint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BubbleFallbackPainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.radius != radius ||
        oldDelegate.deformation != deformation ||
        oldDelegate.popProgress != popProgress;
  }
}

class _BubbleColors {
  static const lightCenter = Color(0xFFFFFFFF);
  static const lightMid1 = Color(0xFFFBF8F6);
  static const lightMid2 = Color(0xFFF5EFEE);
  static const lightEdge = Color(0xFFEEEAE8);

  static const darkCenter = Color(0xFF2A2D34);
  static const darkMid = Color(0xFF16171B);
  static const darkEdge = Color(0xFF0A0B0D);

  static const lightMainText = Color(0xFF4A403A);
  static const darkMainText = Color(0xFFE5E5EA);
  static const lightTitle = Color(0xFF1F1A17);
  static const darkTitle = Color(0xFFF5F5F7);
  static const lightSubtitle = Color(0xFF8A807A);
  static const darkSubtitle = Color(0xFFA1A1A6);
}

class _BubbleLayout {
  const _BubbleLayout({
    required this.size,
    required this.safeTopInset,
  });

  factory _BubbleLayout.fromSize(Size size, double safeTopInset) {
    return _BubbleLayout(size: size, safeTopInset: safeTopInset);
  }

  final Size size;
  final double safeTopInset;

  double get centerX => size.width / 2;

  double get bottomOrbCenterY => size.height * _bottomOrbRatio;

  double get topOrbCenterY => size.height * _topOrbRatio;

  double get midPoint => (bottomOrbCenterY + topOrbCenterY) / 2;

  double get maxDragY => bottomOrbCenterY + (size.height * _dragOvershootRatio);

  double get textBottomY => size.height * _textYBottomRatio;

  double get textTopY => size.height * _textYTopRatio;

  Offset get revealEpicenter => Offset(size.width - 48, safeTopInset + 40);

  double progressFor(double bubbleY) {
    final orbRange = bottomOrbCenterY - topOrbCenterY;
    return ((bottomOrbCenterY - bubbleY) / orbRange).clamp(0, 1);
  }

  double orbRadiusFor(double progress) =>
      ui.lerpDouble(_maxOrbRadius, _minOrbRadius, progress)!;

  double textYOffsetFor(double progress) =>
      ui.lerpDouble(textBottomY, textTopY, progress)!;
}

({double value, double velocity}) _stepSpring({
  required double value,
  required double velocity,
  required double target,
  required double stiffness,
  required double damping,
  required double dt,
}) {
  final force = ((target - value) * stiffness) - (velocity * damping);
  final nextVelocity = velocity + (force * dt);
  final nextValue = value + (nextVelocity * dt);
  return (value: nextValue, velocity: nextVelocity);
}
