import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DioClient {
  static final DioClient _instance = DioClient._internal();
  factory DioClient() => _instance;
  DioClient._internal();
  
  // Cached SharedPreferences instance for faster token access
  static SharedPreferences? _cachedPrefs;

  // Production API URL - your deployed EC2 instance
  static const String productionUrl = 'http://15.185.100.83:3000';
  
  // Local development URLs (keep for testing)
  static const String localUrl = 'http://localhost:3000';
  static const String androidEmulatorUrl = 'http://10.0.2.2:3000';
  
  // Default to production
  String _baseUrl = productionUrl;
  late Dio dio;
  bool _isRefreshing = false;

  /// Set the base URL dynamically
  void setBaseUrl(String url) {
    _baseUrl = url;
    init(); // Reinitialize with new URL
  }

  // Helper to get cached SharedPreferences (faster than getInstance each time)
  static Future<SharedPreferences> _getPrefs() async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  Future<bool> _refreshToken() async {
    if (_isRefreshing) return false; // Already refreshing
    
    try {
      _isRefreshing = true;
      final prefs = await _getPrefs();
      final refreshToken = prefs.getString('refresh_token');
      
      if (refreshToken == null || refreshToken.isEmpty) {
        print('⚠️ No refresh token available');
        return false;
      }
      
      print('🔄 Attempting to refresh access token...');
      final response = await dio.post('/auth/refresh', data: {'refreshToken': refreshToken});
      final data = response.data as Map<String, dynamic>;
      
      final newAccessToken = data['accessToken']?.toString() ?? '';
      final newRefreshToken = data['refreshToken']?.toString() ?? '';
      
      if (newAccessToken.isNotEmpty) {
        await prefs.setString('auth_token', newAccessToken);
        print('✅ Token refreshed successfully');
        if (newRefreshToken.isNotEmpty) {
          await prefs.setString('refresh_token', newRefreshToken);
        }
        return true;
      }
      
      return false;
    } catch (e) {
      print('❌ Failed to refresh token: $e');
      // Clear tokens on refresh failure
      final prefs = await _getPrefs();
      await prefs.remove('auth_token');
      await prefs.remove('refresh_token');
      return false;
    } finally {
      _isRefreshing = false;
    }
  }

  void init() {
    dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 15),
        responseType: ResponseType.json,  // ✅ Explicitly set response type
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/html, */*',  // ✅ Accept multiple MIME types
          'Connection': 'keep-alive',
          'User-Agent': 'Flutter-App/1.0',  // ✅ Add User-Agent to help server identify client
        },
      ),
    );

    // Add interceptors for logging, token handling, and auto-refresh
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // For FormData (multipart), do not force JSON Content-Type; Dio sets multipart/form-data
          if (options.data is FormData) {
            options.headers.remove('Content-Type');
          }
          
          // Add auth token to requests if available
          final prefs = await _getPrefs();
          final token = prefs.getString('auth_token');
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          
          return handler.next(options);
        },
        onResponse: (response, handler) {
          return handler.next(response);
        },
        onError: (error, handler) async {
          // Log errors for debugging
          print('DioError: ${error.message}');
          if (error.response != null) {
            print('Response: ${error.response?.data}');
            print('Status: ${error.response?.statusCode}');
          }
          
          // ✅ Handle 406 Not Acceptable - server doesn't accept our MIME type
          if (error.response?.statusCode == 406) {
            print('⚠️ 406 Not Acceptable - Server rejected MIME type');
            print('   Request path: ${error.requestOptions.path}');
            print('   Accept header: ${error.requestOptions.headers['Accept']}');
            
            // Try to retry with different Accept header
            try {
              final opts = error.requestOptions;
              opts.headers['Accept'] = '*/*';  // Accept any MIME type
              print('🔄 Retrying request with Accept: */*');
              final response = await dio.fetch(opts);
              return handler.resolve(response);
            } catch (e) {
              print('❌ Retry with */* failed: $e');
              return handler.next(error);
            }
          }
          
          // Auto-refresh token on 401 (except for auth endpoints)
          if (error.response?.statusCode == 401) {
            final requestPath = error.requestOptions.path;
            
            // Don't refresh for auth endpoints (login, register, refresh, etc.)
            if (!requestPath.startsWith('/auth/')) {
              print('🔄 401 Unauthorized - attempting token refresh...');
              
              final refreshed = await _refreshToken();
              if (refreshed) {
                // Retry the original request with new token
                final prefs = await _getPrefs();
                final newToken = prefs.getString('auth_token');
                
                if (newToken != null) {
                  error.requestOptions.headers['Authorization'] = 'Bearer $newToken';
                  print('🔄 Retrying request with new token...');
                  
                  try {
                    final opts = error.requestOptions;
                    final response = await dio.fetch(opts);
                    return handler.resolve(response);
                  } catch (e) {
                    return handler.next(error);
                  }
                }
              }
            }
          }
          
          return handler.next(error);
        },
      ),
    );
  }
}
