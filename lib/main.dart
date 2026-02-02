import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/splash_screen.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  
  // Initialize notification service to start periodic checks
  final notificationService = NotificationService();
  await notificationService.initialize();
  
  // Note: Background tasks using workmanager are temporarily disabled
  // The periodic check will work when the app is open (every 5 minutes)
  // To enable background tasks, uncomment the workmanager code below
  // and ensure workmanager package is properly installed
  
  print('✅ Notification service initialized');
  
  runApp(const OrientationApp());
}

class OrientationApp extends StatelessWidget {
  const OrientationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orientation',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFFE50914),
          secondary: const Color(0xFFE50914),
          surface: Colors.black,
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

