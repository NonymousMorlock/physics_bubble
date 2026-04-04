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
}
