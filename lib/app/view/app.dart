import 'package:flutter/material.dart';
import 'package:physics_bubble/app/view/physics_bubble_screen.dart';
import 'package:physics_bubble/l10n/l10n.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const PhysicsBubbleScreen(),
    );
  }
}
