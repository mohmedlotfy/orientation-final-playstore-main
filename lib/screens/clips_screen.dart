import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../models/clip_model.dart';
import '../services/api/project_api.dart';
import '../services/api/improved_clip_api.dart';
import '../utils/auth_helper.dart';
import '../widgets/skeleton_loader.dart';
import 'project_details_screen.dart';

class ClipsScreen extends StatefulWidget {
  const ClipsScreen({super.key});

  @override
  State<ClipsScreen> createState() => ClipsScreenState();
}

class ClipsScreenState extends State<ClipsScreen> with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  final ProjectApi _projectApi = ProjectApi();
  final ImprovedClipApi _clipApi = ImprovedClipApi();
  
  List<ClipModel> _clips = [];
  final Map<String, bool> _savedReelIds = {}; // Store saved status by reel ID
  final Map<int, VideoPlayerController> _controllers = {}; // Direct video controllers
  final Set<int> _failedVideoIndices = {}; // Track failed videos (4K)
  int _currentIndex = 0;
  bool _isLoading = true;
  bool _isVisible = false; // Track if screen is visible
  bool _isInitialized = false;

  static const Color brandRed = Color(0xFFE50914);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadClips();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || 
        state == AppLifecycleState.inactive) {
      pauseAllVideos();
    }
  }

  void pauseAllVideos() {
    for (var controller in _controllers.values) {
      try {
        if (controller.value.isInitialized && controller.value.isPlaying) {
          controller.pause();
        }
      } catch (e) {
        debugPrint('⚠️ Error pausing video: $e');
      }
    }
  }

  // Call this when tab becomes visible
  void setVisible(bool visible) {
    _isVisible = visible;
    if (visible) {
      // Resume current video if visible
      final controller = _controllers[_currentIndex];
      if (controller != null && controller.value.isInitialized && !controller.value.isPlaying) {
        controller.play();
      }
    } else {
      // Pause all videos when not visible
      pauseAllVideos();
    }
  }

  Future<void> _loadClips({bool isRefresh = false}) async {
    try {
      if (!isRefresh) {
        if (mounted) {
          setState(() {
            _isLoading = true;
          });
        }
      }
      
      // When refreshing, clear cache first to ensure fresh data
      if (isRefresh) {
        await ProjectApi.clearReelsCache();
        await _clipApi.clearCache();
      }
      
      // ✅ Load only first 20 clips initially for fast display
      final clips = await _clipApi.getAllClips(page: 1, limit: 20, forceRefresh: isRefresh);
      if (mounted) {
        setState(() {
          _clips = clips;
          _isLoading = false;
        });
        if (clips.isNotEmpty) {
          // Mark as initialized immediately so UI can start building
          if (mounted) {
            setState(() {
              _isInitialized = true;
            });
          }
          
          // Initialize current video (non-blocking for UI)
          _initializeCurrentVideo().then((_) {
            if (mounted) {
              setState(() {}); // Refresh UI when video is ready
            }
          }).catchError((e) {
            debugPrint('⚠️ Error in _initializeCurrentVideo: $e');
          });
          
          // ✅ Load saved status in parallel (non-blocking, don't wait)
          _loadSavedStatus();
          
          // ✅ Load more clips in background after initial display
          if (!isRefresh) {
            _loadMoreClipsInBackground();
          }
        } else {
          // No clips - mark as initialized anyway
          if (mounted) {
            setState(() {
              _isInitialized = true;
            });
          }
        }
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Error loading clips: $e');
      debugPrint('Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isInitialized = true; // Mark as initialized even on error to show UI
        });
      }
    }
  }

  Future<void> _loadSavedStatus() async {
    try {
      // ✅ Check cache first, API second (non-blocking)
      final cachedIds = await _getCachedSavedIds();
      if (cachedIds.isNotEmpty && mounted) {
        setState(() {
          _savedReelIds.clear();
          for (var id in cachedIds) {
            _savedReelIds[id] = true;
          }
        });
      }
      
      // ✅ Then update from API in background (don't wait)
      _projectApi.getSavedReels().then((savedReels) {
        if (mounted) {
          setState(() {
            _savedReelIds.clear();
            for (final reel in savedReels) {
              _savedReelIds[reel.id] = true;
            }
          });
        }
      }).catchError((e) {
        debugPrint('⚠️ Error loading saved status from API: $e');
      });
    } catch (e) {
      debugPrint('⚠️ Error loading saved status: $e');
      // If loading fails, set all to false
      if (mounted) {
        setState(() {
          _savedReelIds.clear();
        });
      }
    }
  }
  
  /// Get cached saved IDs (instant, non-blocking)
  Future<List<String>> _getCachedSavedIds() async {
    // This would use SharedPreferences if implemented
    // For now, return empty list
    return [];
  }
  
  /// ✅ Load more clips in background after initial display
  void _loadMoreClipsInBackground() async {
    try {
      // Wait 2 seconds, then load more clips
      await Future.delayed(const Duration(seconds: 2));
      final moreClips = await _clipApi.getAllClips(page: 2, limit: 100, forceRefresh: false);
      
      if (mounted && moreClips.isNotEmpty) {
        setState(() {
          _clips.addAll(moreClips);
        });
      }
    } catch (e) {
      debugPrint('⚠️ Error loading more clips: $e');
    }
  }

  Future<void> _initializeCurrentVideo() async {
    if (_clips.isEmpty || _currentIndex < 0 || _currentIndex >= _clips.length) {
      return;
    }
    
    if (_controllers.containsKey(_currentIndex)) {
      final controller = _controllers[_currentIndex]!;
      if (controller.value.isInitialized) {
        if (_isVisible && !controller.value.isPlaying) {
          controller.play();
        }
        return;
      }
    }
    
    await _initializeVideoAt(_currentIndex);
    
    // ✅ Preload next video in background (don't wait)
    if (_currentIndex + 1 < _clips.length) {
      _initializeVideoAt(_currentIndex + 1).catchError((e) {
        debugPrint('⚠️ Preload failed: $e');
      });
    }
  }
  
  Future<void> _initializeVideoAt(int index) async {
    if (index < 0 || index >= _clips.length) return;
    if (_failedVideoIndices.contains(index)) return;
    if (_controllers.containsKey(index)) {
      final controller = _controllers[index]!;
      if (controller.value.isInitialized) return;
    }
    
    final clip = _clips[index];
    final videoUrl = clip.videoUrl;
    if (videoUrl.isEmpty) return;
    
    // ✅ Adaptive timeout: Android needs more time
    final baseTimeout = Platform.isAndroid 
        ? const Duration(seconds: 15)  // Android needs more time
        : const Duration(seconds: 6);
    
    // ✅ Retry mechanism with exponential backoff
    VideoPlayerController? controller;
    Exception? lastError;
    
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        debugPrint('🔄 ClipsScreen: Initializing video at index $index (attempt $attempt/3)');
        
        // Dispose previous controller if retrying
        if (controller != null && attempt > 1) {
          try {
            await controller.dispose();
          } catch (_) {}
        }
        
        controller = VideoPlayerController.networkUrl(
          Uri.parse(videoUrl),
          videoPlayerOptions: VideoPlayerOptions(
            mixWithOthers: false,
            allowBackgroundPlayback: false,
          ),
        );
        
        // ✅ Increase timeout with each attempt
        final timeoutDuration = Duration(
          seconds: baseTimeout.inSeconds * attempt, // 15s, 30s, 45s on Android
        );
        
        await controller.initialize().timeout(
          timeoutDuration,
          onTimeout: () {
            controller?.dispose();
            throw TimeoutException('Video initialization timeout after ${timeoutDuration.inSeconds}s');
          },
        );
        
        // ✅ Success! Setup controller
        controller.setLooping(true);
        if (index == _currentIndex && _isVisible) {
          controller.play();
        }
        
        if (mounted) {
          setState(() {
            _controllers[index] = controller!;
          });
        }
        
        debugPrint('✅ ClipsScreen: Video initialized successfully at index $index');
        return; // Success, exit retry loop
        
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        debugPrint('❌ ClipsScreen: Error initializing video at $index (attempt $attempt/3): $e');
        
        // ✅ Check for 4K errors ONLY (don't retry 4K videos)
        // Note: MediaCodec errors on 1080p videos should still retry
        final errorStr = e.toString().toLowerCase();
        final is4KError = errorStr.contains('3840') || 
                         (errorStr.contains('4k') && errorStr.contains('2160')) ||
                         (errorStr.contains('3840') && errorStr.contains('2160'));
        
        if (is4KError) {
          debugPrint('⚠️ ClipsScreen: 4K video detected (3840x2160), marking as failed');
          _failedVideoIndices.add(index);
          if (mounted) setState(() {});
          return; // Don't retry 4K videos
        }
        
        // ✅ For 1080p videos with MediaCodec errors, continue retrying
        // This helps with network issues and temporary codec problems
        
        // ✅ If not last attempt, wait before retry (exponential backoff)
        if (attempt < 3) {
          final backoffDelay = Duration(seconds: attempt); // 1s, 2s
          debugPrint('⏳ ClipsScreen: Waiting ${backoffDelay.inSeconds}s before retry...');
          await Future.delayed(backoffDelay);
        }
      }
    }
    
    // ✅ All attempts failed
    debugPrint('❌ ClipsScreen: Failed to initialize video at $index after 3 attempts');
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  void _onPageChanged(int index) {
    if (index == _currentIndex) return;
    if (index < 0 || index >= _clips.length) return;
    
    try {
      // Pause previous video
      final prevController = _controllers[_currentIndex];
      if (prevController != null && prevController.value.isInitialized && prevController.value.isPlaying) {
        prevController.pause();
      }
      
      if (mounted) {
        setState(() {
          _currentIndex = index;
        });
      }
      
      // ✅ Initialize current video if not already loaded
      _initializeCurrentVideo().then((_) {
        // Preload next video is already handled in _initializeCurrentVideo
      }).catchError((e) {
        debugPrint('⚠️ Error initializing current video after page change: $e');
      });
      
      // Play if visible
      if (_isVisible) {
        final currentController = _controllers[index];
        if (currentController != null && currentController.value.isInitialized && !currentController.value.isPlaying) {
          currentController.play();
        }
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Error in _onPageChanged: $e');
      debugPrint('Stack trace: $stackTrace');
      // Don't crash - just update index
      if (mounted) {
        setState(() {
          _currentIndex = index;
        });
      }
    }
  }

  @override
  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
      pauseAllVideos();
      _pageController.dispose();
      // Dispose all controllers
      for (var controller in _controllers.values) {
        try {
          controller.dispose();
        } catch (e) {
          debugPrint('⚠️ Error disposing controller: $e');
        }
      }
      _controllers.clear();
    } catch (e) {
      debugPrint('⚠️ Error in ClipsScreen dispose: $e');
    }
    super.dispose();
  }

  Future<void> _toggleSave(int index) async {
    if (!mounted) return;
    
    final isAuth = await AuthHelper.requireAuth(context);
    if (!isAuth || !mounted) return;
    
    final clip = _clips[index];
    final isCurrentlySaved = _savedReelIds[clip.id] ?? false;

    // Optimistic update
    if (mounted) {
      setState(() {
        _savedReelIds[clip.id] = !isCurrentlySaved;
      });
    }

    try {
      if (!isCurrentlySaved) {
        final success = await _projectApi.saveReel(clip.id);
        if (!mounted) return;
        
        if (success) {
          _showSnackBar('Saved!', isSuccess: true);
        } else {
          // Revert on failure
          if (mounted) {
            setState(() {
              _savedReelIds[clip.id] = isCurrentlySaved;
            });
          }
          _showSnackBar('Error saving reel', isSuccess: false);
        }
      } else {
        final success = await _projectApi.unsaveReel(clip.id);
        if (!mounted) return;
        
        if (success) {
          _showSnackBar('Removed from saved', isSuccess: true);
        } else {
          // Revert on failure
          if (mounted) {
            setState(() {
              _savedReelIds[clip.id] = isCurrentlySaved;
            });
          }
          _showSnackBar('Error removing reel', isSuccess: false);
        }
      }
    } catch (e) {
      if (!mounted) return;
      
      if (mounted) {
        setState(() {
          _savedReelIds[clip.id] = isCurrentlySaved;
        });
      }
      _showSnackBar('Error saving');
    }
  }

  Future<void> _openWhatsApp(ClipModel clip) async {
    const phone = '201205403733';
    final message = 'مهتم بمشروع ${clip.developerName}';
    final url = 'https://wa.me/$phone?text=${Uri.encodeComponent(message)}';

    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      _showSnackBar('Could not open WhatsApp');
    }
  }

  Future<void> _shareClip(ClipModel clip) async {
    final shareText = '''
🎬 ${clip.title}
🏗️ ${clip.developerName}

${clip.description}

شاهد المزيد على تطبيق Orientation!
''';

    try {
      await Share.share(shareText, subject: clip.title);
    } catch (e) {
      _showSnackBar('Error sharing');
    }
  }

  void _openProjectDetails(ClipModel clip) async {
    final isAuth = await AuthHelper.requireAuth(context);
    if (!isAuth || !mounted) return;
    
    // Pause current video before navigating
    pauseAllVideos();
    
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProjectDetailsScreen(projectId: clip.projectId),
      ),
    );
  }

  void _openEpisodes(ClipModel clip) async {
    final isAuth = await AuthHelper.requireAuth(context);
    if (!isAuth || !mounted) return;
    
    // Pause current video before navigating
    pauseAllVideos();
    
    if (!mounted) return;
    // Navigate to Project Details on Episodes tab
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProjectDetailsScreen(
          projectId: clip.projectId,
          initialTabIndex: 1, // Episodes tab
        ),
      ),
    );
  }

  void _showSnackBar(String message, {bool isSuccess = false}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isSuccess ? Icons.check_circle : Icons.error_outline,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
        duration: const Duration(seconds: 2),
        backgroundColor: isSuccess ? Colors.green : brandRed,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: PageView.builder(
          scrollDirection: Axis.vertical,
          itemCount: 3, // Show 3 skeleton items
          itemBuilder: (context, index) {
            return const SkeletonClipItem();
          },
        ),
      );
    }

    if (_clips.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.video_library_outlined,
                color: Colors.white.withOpacity(0.3),
                size: 80,
              ),
              const SizedBox(height: 24),
              Text(
                'No Clips Available',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 20,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: RefreshIndicator(
        onRefresh: () => _loadClips(isRefresh: true),
        color: brandRed,
        backgroundColor: Colors.white,
        child: PageView.builder(
          controller: _pageController,
          scrollDirection: Axis.vertical,
          itemCount: _clips.length,
          onPageChanged: _onPageChanged,
          physics: const AlwaysScrollableScrollPhysics(), // Enable pull to refresh
          itemBuilder: (context, index) {
            return _buildClipItem(index);
          },
        ),
      ),
    );
  }

  Widget _buildClipItem(int index) {
    // Safety checks
    if (index < 0 || index >= _clips.length) {
      return const SizedBox.shrink();
    }
    
    final clip = _clips[index];
    final controller = _controllers[index];
    final isSaved = _savedReelIds[clip.id] ?? false;
    final videoFailed = _failedVideoIndices.contains(index);
    
    // ✅ Start loading immediately if not loaded (don't wait)
    if (controller == null && _isInitialized && !videoFailed &&
        (index == _currentIndex || index == _currentIndex + 1 || index == _currentIndex - 1)) {
      _initializeVideoAt(index).catchError((e) {
        debugPrint('⚠️ Error initializing video at $index: $e');
      });
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Video or Placeholder
        GestureDetector(
          onTap: () async {
            try {
              if (controller != null && controller.value.isInitialized) {
                if (controller.value.isPlaying) {
                  controller.pause();
                } else {
                  controller.play();
                }
                if (mounted) {
                  setState(() {});
                }
              } else if (controller == null && _isInitialized && !_failedVideoIndices.contains(index)) {
                // Try to initialize if not loaded
                await _initializeVideoAt(index);
              }
            } catch (e) {
              debugPrint('⚠️ Error in video tap handler: $e');
            }
          },
          child: (controller != null && controller.value.isInitialized)
              ? Center(
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: VideoPlayer(controller),
                  ),
                )
              : _buildLoadingPlaceholder(),
        ),
        // Show "Unsupported" indicator for failed videos
        if (videoFailed)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, color: Colors.white70, size: 40),
                  SizedBox(height: 4),
                  Text(
                    'Video playback\nnot supported',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        // Play/Pause indicator
        if (controller != null && !controller.value.isPlaying && !videoFailed)
          Center(
            child: Image.asset(
              'assets/icons_clips/play.png',
              width: 80,
              height: 80,
              errorBuilder: (context, error, stackTrace) {
                // Fallback to icon if image not found
                return const Icon(
                  Icons.play_arrow,
                  color: Colors.white54,
                  size: 80,
                );
              },
            ),
          ),
        // Gradient overlay
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 300,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.95),
                ],
              ),
            ),
          ),
        ),
        // Action buttons - positioned higher
        Positioned(
          right: 16,
          bottom: 200,
          child: Column(
            children: [
              if (clip.hasWhatsApp) ...[
                _ActionButton(
                  imagePath: 'assets/icons_clips/whatsapp.png',
                  label: 'WhatsApp',
                  onTap: () => _openWhatsApp(clip),
                ),
                const SizedBox(height: 18),
              ],
              _ActionButton(
                imagePath: isSaved ? '' : 'assets/icons_clips/save.png',
                icon: isSaved ? Icons.bookmark : null,
                iconColor: isSaved ? brandRed : Colors.white,
                label: isSaved ? 'Saved' : 'Save',
                onTap: () => _toggleSave(index),
              ),
              const SizedBox(height: 18),
              _ActionButton(
                imagePath: 'assets/icons_clips/share.png',
                label: 'Share',
                onTap: () => _shareClip(clip),
              ),
            ],
          ),
        ),
        // Bottom content
        Positioned(
          left: 16,
          right: 80,
          bottom: 30,
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Developer info row - tappable to go to project details
                Row(
                  children: [
                    // Developer avatar - tappable
                    GestureDetector(
                      onTap: () => _openProjectDetails(clip),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: ClipOval(
                          child: clip.developerLogo.isNotEmpty
                              ? Image.asset(
                                  clip.developerLogo,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    Icons.business,
                                    color: Colors.grey,
                                    size: 20,
                                  ),
                                )
                              : const Icon(
                                  Icons.business,
                                  color: Colors.grey,
                                  size: 20,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Developer name - tappable, flexible width
                    Flexible(
                      child: GestureDetector(
                        onTap: () => _openProjectDetails(clip),
                        child: Text(
                          clip.developerName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Watch Orientation button
                    GestureDetector(
                      onTap: () => _openEpisodes(clip),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: brandRed,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_circle_filled,
                              color: Colors.white,
                              size: 16,
                            ),
                            SizedBox(width: 5),
                            Text(
                              'Watch Orientation',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // Title - tappable to go to project details
                GestureDetector(
                  onTap: () => _openProjectDetails(clip),
                  child: Text(
                    clip.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    clip.description,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 14,
                      height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingPlaceholder() {
    return _buildFastLoadingPlaceholder(_clips.isNotEmpty && _currentIndex < _clips.length 
        ? _clips[_currentIndex] 
        : null);
  }
  
  /// ✅ Fast loading placeholder with thumbnail support
  Widget _buildFastLoadingPlaceholder(ClipModel? clip) {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ✅ Show thumbnail immediately if available
          if (clip != null && clip.thumbnail.isNotEmpty)
            Image.network(
              clip.thumbnail,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(color: Colors.grey[900]),
            )
          else
            Container(color: Colors.grey[900]),
          
          // Small loading indicator
          Center(
            child: CircularProgressIndicator(
              color: Color(0xFFE50914),
              strokeWidth: 2,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String imagePath;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Color iconColor;

  const _ActionButton({
    required this.imagePath,
    required this.label,
    required this.onTap,
    this.icon,
    this.iconColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          icon != null
              ? Icon(icon, color: iconColor, size: 32)
              : Image.asset(
                  imagePath,
                  width: 32,
                  height: 32,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.circle,
                    color: iconColor,
                    size: 32,
                  ),
                ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
