import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physics_bubble/app/view/physics_bubble_screen.dart';

import '../../helpers/helpers.dart';

void main() {
  testWidgets('renders the physics bubble screen copy', (tester) async {
    await tester.pumpApp(const PhysicsBubbleScreen());

    expect(find.text('Pixels are now\nphysical.'), findsOneWidget);
    expect(find.text('AGSL Pipelines'), findsOneWidget);
    expect(find.byType(PhysicsBubbleScreen), findsOneWidget);
  });

  testWidgets('theme toggle changes the screen theme', (tester) async {
    await tester.pumpApp(const PhysicsBubbleScreen());

    final textFinder = find.text('Pixels are now\nphysical.');
    final before = tester.widget<Text>(textFinder).style!.color;

    await tester.tap(find.byKey(const ValueKey<String>('theme_toggle')));
    await tester.pump(const Duration(milliseconds: 400));

    final after = tester.widget<Text>(textFinder).style!.color;

    expect(after, isNot(before));
  });
}
