import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'asr_screen.dart';
import 'tts_screen.dart';
import 'translation_screen.dart';
import 'chat_screen.dart';
import 'model_manager.dart';
import 'model_management_sheet.dart';
import 'native_nmt_service.dart';
import 'llama_nmt_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HardwareKeyboard.instance.clearState();

  // Configure AudioPlayer globally for iOS to ignore the silent/mute switch
  await AudioPlayer.global.setGlobalAudioContext(AudioContext(
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const [
        AVAudioSessionOptions.mixWithOthers,
        AVAudioSessionOptions.defaultToSpeaker,
      ],
    ),
  ));

  await ModelManager.ensureEspeakDataExtractor();
  await NativeNmtService.init();
  await LlamaNmtService.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sherpa Onnx Offline SDK Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Voice App - Offline Speech Hub'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;
  static final ValueNotifier<bool> showPerfMetricsNotifier = ValueNotifier<bool>(false);

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Text(
          widget.title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showSettingsBottomSheet(context),
            tooltip: 'Settings',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Welcome Banner / Title Section
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E3C72), Color(0xFF2A5298)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1E3C72).withOpacity(0.3),
                      blurRadius: 15,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.blur_on_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'VoiceHub SDK',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'High-Performance Offline Speech & Translation Engine',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.offline_bolt_rounded,
                            color: Colors.amberAccent,
                            size: 14,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '100% Offline Processing',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              // Features Heading
              const Text(
                'Speech & Language Services',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2D3748),
                ),
              ),
              const SizedBox(height: 16),

              // Two-column Grid for Services
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 95,
                      child: GridMenuCard(
                        title: 'ASR (STT)',
                        description: 'Speech Recognition',
                        icon: Icons.mic_rounded,
                        gradientColors: const [Color(0xFF2193b0), Color(0xFF6dd5ed)],
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => Scaffold(
                                appBar: AppBar(
                                  title: const Text('ASR Speech Recognition'),
                                  centerTitle: true,
                                  actions: [
                                    IconButton(
                                      icon: const Icon(Icons.folder_shared_outlined),
                                      onPressed: () {
                                        showModalBottomSheet(
                                          context: context,
                                          isScrollControlled: true,
                                          backgroundColor: Colors.transparent,
                                          builder: (context) => ModelManagementSheet(
                                            initialType: 'asr',
                                            onModelsChanged: () {},
                                          ),
                                        );
                                      },
                                      tooltip: 'Manage Models',
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                ),
                                body: const AsrScreen(),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 95,
                      child: GridMenuCard(
                        title: 'TTS (Speech)',
                        description: 'Speech Synthesis',
                        icon: Icons.record_voice_over_rounded,
                        gradientColors: const [Color(0xFF11998e), Color(0xFF38ef7d)],
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => Scaffold(
                                appBar: AppBar(
                                  title: const Text('TTS Speech Synthesis'),
                                  centerTitle: true,
                                  actions: [
                                    IconButton(
                                      icon: const Icon(Icons.folder_shared_outlined),
                                      onPressed: () {
                                        showModalBottomSheet(
                                          context: context,
                                          isScrollControlled: true,
                                          backgroundColor: Colors.transparent,
                                          builder: (context) => ModelManagementSheet(
                                            initialType: 'tts',
                                            onModelsChanged: () {},
                                          ),
                                        );
                                      },
                                      tooltip: 'Manage Models',
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                ),
                                body: const TtsScreen(),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 95,
                      child: GridMenuCard(
                        title: 'NMT (Translate)',
                        description: 'Text Translation',
                        icon: Icons.translate_rounded,
                        gradientColors: const [Color(0xFFFF8C00), Color(0xFFFF0080)],
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ValueListenableBuilder<bool>(
                                valueListenable: MyHomePage.showPerfMetricsNotifier,
                                builder: (context, showPerfMetrics, _) {
                                  return Scaffold(
                                    appBar: AppBar(
                                      title: const Text('NMT Text Translation'),
                                      centerTitle: true,
                                      actions: [
                                        IconButton(
                                          icon: const Icon(Icons.settings_outlined),
                                          onPressed: () => showSettingsBottomSheet(context),
                                          tooltip: 'Settings',
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.folder_shared_outlined),
                                          onPressed: () {
                                            showModalBottomSheet(
                                              context: context,
                                              isScrollControlled: true,
                                              backgroundColor: Colors.transparent,
                                              builder: (context) => ModelManagementSheet(
                                                initialType: 'nmt',
                                                onModelsChanged: () {},
                                              ),
                                            );
                                          },
                                          tooltip: 'Manage Models',
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                    ),
                                    body: TranslationScreen(showPerfMetrics: showPerfMetrics),
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 95,
                      child: GridMenuCard(
                        title: 'LLM Chat',
                        description: 'Smart Dialogue',
                        icon: Icons.forum_rounded,
                        gradientColors: const [Color(0xFF654ea3), Color(0xFFeaafc8)],
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ValueListenableBuilder<bool>(
                                valueListenable: MyHomePage.showPerfMetricsNotifier,
                                builder: (context, showPerfMetrics, _) {
                                  return Scaffold(
                                    appBar: AppBar(
                                      title: const Text('LLM Smart Dialogue'),
                                      centerTitle: true,
                                      actions: [
                                        IconButton(
                                          icon: const Icon(Icons.settings_outlined),
                                          onPressed: () => showSettingsBottomSheet(context),
                                          tooltip: 'Settings',
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.folder_shared_outlined),
                                          onPressed: () {
                                            showModalBottomSheet(
                                              context: context,
                                              isScrollControlled: true,
                                              backgroundColor: Colors.transparent,
                                              builder: (context) => ModelManagementSheet(
                                                initialType: 'llm',
                                                onModelsChanged: () {},
                                              ),
                                            );
                                          },
                                          tooltip: 'Manage Models',
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                    ),
                                    body: ChatScreen(showPerfMetrics: showPerfMetrics),
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Full-width Model Warehouse card
              SizedBox(
                height: 95,
                width: double.infinity,
                child: GridMenuCard(
                  title: 'Model Repository (模型仓库)',
                  description: 'Manage and download offline speech & LLM models',
                  icon: Icons.inventory_2_rounded,
                  gradientColors: const [Color(0xFF2C3E50), Color(0xFF4CA1AF)],
                  onTap: () {
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (context) => ModelManagementSheet(
                        initialType: 'asr',
                        onModelsChanged: () {},
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void showSettingsBottomSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    builder: (context) => ValueListenableBuilder<bool>(
      valueListenable: MyHomePage.showPerfMetricsNotifier,
      builder: (context, showPerfMetrics, _) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Settings',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Show performance metrics'),
                  subtitle: const Text(
                    'Display encoder time and decoder tokens/second for MT translation',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: showPerfMetrics,
                  onChanged: (val) {
                    MyHomePage.showPerfMetricsNotifier.value = val;
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class GridMenuCard extends StatefulWidget {
  final String title;
  final String description;
  final IconData icon;
  final List<Color> gradientColors;
  final VoidCallback onTap;

  const GridMenuCard({
    Key? key,
    required this.title,
    required this.description,
    required this.icon,
    required this.gradientColors,
    required this.onTap,
  }) : super(key: key);

  @override
  State<GridMenuCard> createState() => _GridMenuCardState();
}

class _GridMenuCardState extends State<GridMenuCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.95),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: widget.gradientColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.gradientColors.first.withOpacity(0.25),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              children: [
                Positioned(
                  right: -10,
                  bottom: -15,
                  child: Icon(
                    widget.icon,
                    size: 75,
                    color: Colors.white.withOpacity(0.12),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 12.0),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          widget.icon,
                          size: 22,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.title,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.description,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withOpacity(0.95),
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
