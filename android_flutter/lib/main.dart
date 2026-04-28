
import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BooxTabletApp());
}

class BooxTabletApp extends StatelessWidget {
  const BooxTabletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Boox Tablet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A237E),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
