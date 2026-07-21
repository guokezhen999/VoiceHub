import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:voice_app/ui/screens/asr_screen.dart';
import 'package:voice_app/ui/screens/tts_screen.dart';
import 'package:voice_app/ui/screens/translation_screen.dart';
import 'package:voice_app/ui/screens/chat_screen.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/ui/widgets/model_management_sheet.dart';
import 'package:voice_app/services/native_nmt_service.dart';
import 'package:voice_app/services/llama_nmt_service.dart';
import 'package:voice_app/services/llama_chat_service.dart';
import 'package:voice_app/ui/screens/cascade_translation_screen.dart';
import 'package:voice_app/ui/screens/dual_dialogue_screen.dart';
import 'package:voice_app/ui/screens/audio_file_transcription_screen.dart';
import 'package:voice_app/ui/screens/simultaneous_translation_screen.dart';
import 'package:voice_app/services/vad_settings.dart';
import 'package:voice_app/services/advanced_settings.dart';
import 'package:voice_app/services/cache_statistics_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LanguageManager.load();
  HardwareKeyboard.instance.clearState();

  // Configure AudioPlayer globally for iOS to ignore the silent/mute switch.
  // NB: `.defaultToSpeaker` is only valid with the `.playAndRecord` category —
  // using it here with `.playback` makes iOS reject the whole config (-50).
  // `.playback` already routes to the speaker and bypasses the mute switch,
  // so `.defaultToSpeaker` is both redundant and invalid in this context.
  await AudioPlayer.global.setGlobalAudioContext(AudioContext(
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const [
        AVAudioSessionOptions.mixWithOthers,
      ],
    ),
  ));

  await ModelManager.ensureEspeakDataExtractor();
  await NativeNmtService.init();
  await LlamaNmtService.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // Delay process exit until llama Metal/GPU resources are destroyed.
    // Without this, Cmd+Q / closing the last window can tear down the
    // process while ggml Metal is still alive → "unexpectedly quit".
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await Future.wait([
          LlamaNmtService.releaseAll(),
          LlamaChatService.releaseAll(),
        ]);
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Hub',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Voice Hub'),
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
                          'Voice Hub',
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
                                      icon: const Icon(Icons.settings_outlined),
                                      onPressed: () => showSettingsBottomSheet(context),
                                      tooltip: 'Settings',
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
                                      icon: const Icon(Icons.settings_outlined),
                                      onPressed: () => showSettingsBottomSheet(context),
                                      tooltip: 'Settings',
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
              // Full-width Cascade Voice Translation card
              SizedBox(
                height: 95,
                width: double.infinity,
                child: GridMenuCard(
                  title: 'Cascade Translation (级联语音翻译)',
                  description: 'End-to-end voice translation (ASR -> MT -> TTS)',
                  icon: Icons.layers_rounded,
                  gradientColors: const [Color(0xFF1E3C72), Color(0xFF2A5298)],
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ValueListenableBuilder<bool>(
                          valueListenable: MyHomePage.showPerfMetricsNotifier,
                          builder: (context, showPerfMetrics, _) {
                            return Scaffold(
                              appBar: AppBar(
                                title: const Text('Cascade Voice Translation'),
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
                              body: CascadeTranslationScreen(showPerfMetrics: showPerfMetrics),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Full-width Dual Dialogue card
              SizedBox(
                height: 95,
                width: double.infinity,
                child: GridMenuCard(
                  title: 'Dual Dialogue (双人对话)',
                  description: 'Two-sided ASR/MT/TTS with shared LLM translation',
                  icon: Icons.people_alt_rounded,
                  gradientColors: const [Color(0xFF134E5E), Color(0xFF71B280)],
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ValueListenableBuilder<bool>(
                          valueListenable: MyHomePage.showPerfMetricsNotifier,
                          builder: (context, showPerfMetrics, _) {
                            return Scaffold(
                              appBar: AppBar(
                                title: const Text('Dual Dialogue'),
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
                              body: DualDialogueScreen(showPerfMetrics: showPerfMetrics),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Full-width Simultaneous Interpretation card
              SizedBox(
                height: 95,
                width: double.infinity,
                child: GridMenuCard(
                  title: 'Simultaneous Interpretation (同声传译)',
                  description: 'End-to-end streaming speech recognition & translation',
                  icon: Icons.hearing_rounded,
                  gradientColors: const [Color(0xFF0F2027), Color(0xFF203A43)],
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ValueListenableBuilder<bool>(
                          valueListenable: MyHomePage.showPerfMetricsNotifier,
                          builder: (context, showPerfMetrics, _) {
                            return Scaffold(
                              appBar: AppBar(
                                title: const Text('Simultaneous Interpretation'),
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
                              body: SimultaneousTranslationScreen(
                                  showPerfMetrics: showPerfMetrics),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Full-width Audio File Transcription card
              SizedBox(
                height: 95,
                width: double.infinity,
                child: GridMenuCard(
                  title: 'Audio File Subtitles (音频文件转录翻译)',
                  description: 'Transcribe audio files & translate to timestamped subtitles',
                  icon: Icons.subtitles_rounded,
                  gradientColors: const [Color(0xFF8E2DE2), Color(0xFF4A00E0)],
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ValueListenableBuilder<bool>(
                          valueListenable: MyHomePage.showPerfMetricsNotifier,
                          builder: (context, showPerfMetrics, _) {
                            return Scaffold(
                              appBar: AppBar(
                                title: const Text('Audio File Transcription'),
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
                              body: AudioFileTranscriptionScreen(showPerfMetrics: showPerfMetrics),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
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
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => ValueListenableBuilder<bool>(
      valueListenable: MyHomePage.showPerfMetricsNotifier,
      builder: (context, showPerfMetrics, _) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'General Settings (通用设置)',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show Performance Metrics', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748))),
                  subtitle: const Text(
                    'Display encoder time and decoder tokens/second for MT translation',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  value: showPerfMetrics,
                  onChanged: (val) {
                    MyHomePage.showPerfMetricsNotifier.value = val;
                  },
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Language Settings (语言设置)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                  subtitle: const Text(
                    'Choose which languages to show in the model repository',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                  onTap: () {
                    Navigator.pop(context);
                    showLanguageSettingsBottomSheet(context);
                  },
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'VAD Settings (VAD 参数设置)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                  subtitle: const Text(
                    'Configure silence and speech durations for voice engines',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                  onTap: () {
                    Navigator.pop(context);
                    showVadSettingsBottomSheet(context);
                  },
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Advanced Settings (高级设置)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                  subtitle: const Text(
                    'Fine-tune decoding parameters for simultaneous translation',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                  onTap: () {
                    Navigator.pop(context);
                    showAdvancedSettingsBottomSheet(context);
                  },
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Cache Statistics (缓存信息统计)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                  subtitle: const Text(
                    'View model and mode history cache statistics, clear history',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                  onTap: () {
                    Navigator.pop(context);
                    showCacheSettingsBottomSheet(context);
                  },
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'About VoiceHub (关于 VoiceHub)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                  subtitle: const Text(
                    'Developer info, open-source repo, and third-party licenses',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                  onTap: () {
                    Navigator.pop(context);
                    showAboutSettingsBottomSheet(context);
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

void showLanguageSettingsBottomSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => _LanguageSettingsSheet(
      onBack: () {
        Navigator.pop(sheetContext);
        showSettingsBottomSheet(context);
      },
    ),
  );
}

class _LanguageSettingsSheet extends StatefulWidget {
  final VoidCallback onBack;

  const _LanguageSettingsSheet({required this.onBack});

  @override
  State<_LanguageSettingsSheet> createState() => _LanguageSettingsSheetState();
}

class _LanguageSettingsSheetState extends State<_LanguageSettingsSheet> {
  late final TextEditingController _newLangController;

  @override
  void initState() {
    super.initState();
    _newLangController = TextEditingController();
  }

  @override
  void dispose() {
    _newLangController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF2D3748)),
                      onPressed: widget.onBack,
                    ),
                    const Text(
                      'Language Settings (语言设置)',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            const Text(
              'Choose which languages to show in the repository:',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
                childAspectRatio: 2.8,
              ),
              itemCount: LanguageManager.languages.length,
              itemBuilder: (context, index) {
                final lang = LanguageManager.languages[index];
                final isEnabled = LanguageManager.enabledLanguages.contains(lang);
                final isDefault = LanguageManager.defaultLanguages.contains(lang);

                return InkWell(
                  onTap: () async {
                    await LanguageManager.toggleLanguage(lang, !isEnabled);
                    if (mounted) setState(() {});
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      color: isEnabled
                          ? const Color(0xFF1E3C72).withOpacity(0.08)
                          : Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isEnabled
                            ? const Color(0xFF1E3C72)
                            : Colors.grey.shade300,
                        width: isEnabled ? 1.5 : 1.0,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6.0),
                            child: Text(
                              lang,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isEnabled
                                    ? const Color(0xFF1E3C72)
                                    : Colors.grey.shade700,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        if (!isDefault)
                          Positioned(
                            right: 1,
                            top: 1,
                            child: GestureDetector(
                              onTap: () async {
                                await LanguageManager.removeLanguage(lang);
                                if (mounted) setState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.all(1),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 2,
                                    )
                                  ],
                                ),
                                child: const Icon(
                                  Icons.close_rounded,
                                  color: Colors.redAccent,
                                  size: 10,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newLangController,
                    decoration: const InputDecoration(
                      hintText: 'Add custom language...',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E3C72),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onPressed: () async {
                    final text = _newLangController.text.trim();
                    if (text.isNotEmpty) {
                      await LanguageManager.addLanguage(text);
                      _newLangController.clear();
                      if (mounted) setState(() {});
                    }
                  },
                  child: const Text('Add'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

void showAdvancedSettingsBottomSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF2D3748)),
                          onPressed: () {
                            Navigator.pop(context);
                            showSettingsBottomSheet(context);
                          },
                        ),
                        const Text(
                          'Advanced Settings (高级设置)',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Repetition Penalty (重复惩罚)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
                    ),
                    Text(
                      AdvancedSettings.repetitionPenalty.toStringAsFixed(2),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1E3C72)),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                const Text(
                  'Higher values discourage repeated tokens in simultaneous translation. 1.0 disables the penalty.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                Slider(
                  value: AdvancedSettings.repetitionPenalty,
                  min: 1.0,
                  max: 2.0,
                  divisions: 20,
                  label: AdvancedSettings.repetitionPenalty.toStringAsFixed(2),
                  activeColor: const Color(0xFF1E3C72),
                  onChanged: (val) {
                    setSheetState(() {
                      AdvancedSettings.repetitionPenalty = val;
                    });
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

void showVadSettingsBottomSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF2D3748)),
                          onPressed: () {
                            Navigator.pop(context);
                            showSettingsBottomSheet(context);
                          },
                        ),
                        const Text(
                          'VAD Settings (VAD 设置)',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(),
                const SizedBox(height: 8),
                _buildVadConfigSection(
                  title: 'General Mode VAD (一般模式 VAD 设置)',
                  config: VadSettings.generalMode,
                  setState: setSheetState,
                ),
                const Divider(height: 24),
                _buildVadConfigSection(
                  title: 'Simultaneous Interpretation VAD (同传模式 VAD 设置)',
                  config: VadSettings.simulstMode,
                  setState: setSheetState,
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Widget _buildVadConfigSection({
  required String title,
  required VadConfig config,
  required StateSetter setState,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: Color(0xFF1E3C72),
        ),
      ),
      const SizedBox(height: 12),
      // VAD Threshold
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Detection Threshold (检测阈值)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
          ),
          Text(
            config.threshold.toStringAsFixed(2),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1E3C72)),
          ),
        ],
      ),
      const SizedBox(height: 2),
      const Text(
        'Lower is more sensitive; higher is more strict (filters noise).',
        style: TextStyle(fontSize: 11, color: Colors.grey),
      ),
      Slider(
        value: config.threshold,
        min: 0.1,
        max: 0.9,
        divisions: 16,
        label: config.threshold.toStringAsFixed(2),
        activeColor: const Color(0xFF1E3C72),
        onChanged: (val) {
          setState(() {
            config.threshold = val;
          });
        },
      ),
      const SizedBox(height: 8),
      // Min Silence Duration
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Min Silence Duration (静音判定时长)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
          ),
          Text(
            '${config.minSilenceDuration.toStringAsFixed(2)}s',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1E3C72)),
          ),
        ],
      ),
      const SizedBox(height: 2),
      const Text(
        'Silence duration required to finalize speech segments.',
        style: TextStyle(fontSize: 11, color: Colors.grey),
      ),
      Slider(
        value: config.minSilenceDuration,
        min: 0.1,
        max: 2.0,
        divisions: 38,
        label: '${config.minSilenceDuration.toStringAsFixed(2)}s',
        activeColor: const Color(0xFF1E3C72),
        onChanged: (val) {
          setState(() {
            config.minSilenceDuration = val;
          });
        },
      ),
      const SizedBox(height: 8),
      // Min Speech Duration
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Min Speech Duration (最少发言时长)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
          ),
          Text(
            '${config.minSpeechDuration.toStringAsFixed(2)}s',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1E3C72)),
          ),
        ],
      ),
      const SizedBox(height: 2),
      const Text(
        'Minimum duration of speech to be considered valid.',
        style: TextStyle(fontSize: 11, color: Colors.grey),
      ),
      Slider(
        value: config.minSpeechDuration,
        min: 0.1,
        max: 2.0,
        divisions: 38,
        label: '${config.minSpeechDuration.toStringAsFixed(2)}s',
        activeColor: const Color(0xFF1E3C72),
        onChanged: (val) {
          setState(() {
            config.minSpeechDuration = val;
          });
        },
      ),
    ],
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

void showCacheSettingsBottomSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => _CacheSettingsSheet(
      onBack: () {
        Navigator.pop(sheetContext);
        showSettingsBottomSheet(context);
      },
    ),
  );
}

class _CacheSettingsSheet extends StatefulWidget {
  final VoidCallback onBack;

  const _CacheSettingsSheet({required this.onBack});

  @override
  State<_CacheSettingsSheet> createState() => _CacheSettingsSheetState();
}

class _CacheSettingsSheetState extends State<_CacheSettingsSheet> {
  bool _loading = true;
  ModelCacheSummary? _modelCache;
  List<ModeCacheInfo> _modeCaches = [];

  @override
  void initState() {
    super.initState();
    _loadCacheData();
  }

  Future<void> _loadCacheData() async {
    setState(() => _loading = true);
    final modelSummary = await CacheStatisticsService.getModelCacheSummary();
    final modeCaches = await CacheStatisticsService.getModeCacheInfos();
    if (mounted) {
      setState(() {
        _modelCache = modelSummary;
        _modeCaches = modeCaches;
        _loading = false;
      });
    }
  }

  Future<void> _confirmAndClearMode(ModeCacheInfo mode) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 24),
            const SizedBox(width: 8),
            const Text('确认清理历史记录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '确定要清理【${mode.title}】的历史记录缓存吗？\n清理后所有相关会话与音频文件将被删除，且无法恢复。',
          style: const TextStyle(fontSize: 14, color: Color(0xFF4A5568)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清理', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await CacheStatisticsService.clearModeHistory(mode.key);
      await _loadCacheData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功清理【${mode.title}】的历史记录缓存'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _confirmAndClearAllHistories() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 26),
            const SizedBox(width: 8),
            const Text('确认清理全部历史', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          '确定要清理所有模式的历史记录缓存吗？\n此操作将清空所有模式下的记录与文件，且无法撤销。',
          style: TextStyle(fontSize: 14, color: Color(0xFF4A5568)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清理全部', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await CacheStatisticsService.clearAllModeHistories();
      await _loadCacheData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已成功清理所有模式的历史记录缓存'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF2D3748)),
                      onPressed: widget.onBack,
                    ),
                    const Text(
                      'Cache Statistics (缓存信息统计)',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              )
            else ...[
              _buildModelCacheSection(),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              _buildModeHistoryCacheSection(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModelCacheSection() {
    final totalSizeStr = CacheStatisticsService.formatBytes(_modelCache?.totalSizeInBytes ?? 0);
    final totalCount = _modelCache?.totalCount ?? 0;
    final details = _modelCache?.details ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: const [
                Icon(Icons.inventory_2_rounded, color: Color(0xFF1E3C72), size: 20),
                SizedBox(width: 8),
                Text(
                  '模型缓存统计 (Model Cache)',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (ctx) => ModelManagementSheet(
                    initialType: 'asr',
                    onModelsChanged: _loadCacheData,
                  ),
                );
              },
              icon: const Icon(Icons.tune_rounded, size: 16),
              label: const Text('模型管理', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF7FAFC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('已下载模型总计', style: TextStyle(fontSize: 13, color: Color(0xFF718096))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEBF8FF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$totalCount 个模型 · $totalSizeStr',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2B6CB0)),
                    ),
                  ),
                ],
              ),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
                ...details.map((d) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(d.icon, size: 16, color: const Color(0xFF4A5568)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              d.title,
                              style: const TextStyle(fontSize: 13, color: Color(0xFF2D3748)),
                            ),
                          ),
                          Text(
                            '${d.count} 个 · ${CacheStatisticsService.formatBytes(d.sizeInBytes)}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF4A5568)),
                          ),
                        ],
                      ),
                    )),
              ] else ...[
                const SizedBox(height: 8),
                const Text(
                  '暂无已下载模型',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildModeHistoryCacheSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: const [
                Icon(Icons.history_rounded, color: Color(0xFF1E3C72), size: 20),
                SizedBox(width: 8),
                Text(
                  '各个模式历史记录缓存',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                ),
              ],
            ),
            if (_modeCaches.isNotEmpty)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent, width: 1),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _confirmAndClearAllHistories,
                icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                label: const Text('一键清理全部', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          '仅显示存在缓存数据的模式（无缓存数据不显示）',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 12),
        if (_modeCaches.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              color: const Color(0xFFF7FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              children: const [
                Icon(Icons.cleaning_services_rounded, size: 40, color: Colors.grey),
                SizedBox(height: 8),
                Text(
                  '暂无历史记录缓存',
                  style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _modeCaches.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final mode = _modeCaches[index];
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.02),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: mode.color.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(mode.icon, color: mode.color, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mode.title,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${mode.count} 条记录 · ${CacheStatisticsService.formatBytes(mode.sizeInBytes)}',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF718096), fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 22),
                      tooltip: '清理【${mode.title}】缓存',
                      onPressed: () => _confirmAndClearMode(mode),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

void showAboutSettingsBottomSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => _AboutSettingsSheet(
      onBack: () {
        Navigator.pop(sheetContext);
        showSettingsBottomSheet(context);
      },
    ),
  );
}

class _AboutSettingsSheet extends StatelessWidget {
  final VoidCallback onBack;

  const _AboutSettingsSheet({required this.onBack});

  static const String _repoUrl = 'https://github.com/guokezhen999/VoiceHub.git';

  static final List<Map<String, String>> _thirdPartyLibraries = [
    {
      'name': 'sherpa-onnx',
      'description': 'Next-generation Kaldi offline ASR, TTS, and VAD engine based on ONNX Runtime',
      'license': 'Apache-2.0',
    },
    {
      'name': 'onnxruntime',
      'description': 'Microsoft high-performance cross-platform machine learning inference engine',
      'license': 'MIT',
    },
    {
      'name': 'llama.cpp',
      'description': 'High-performance C/C++ LLM inference engine supporting GGUF quantizations',
      'license': 'MIT',
    },
    {
      'name': 'Silero VAD',
      'description': 'Pre-trained enterprise-grade voice activity detector',
      'license': 'MIT',
    },
    {
      'name': 'Opus-MT / MarianMT',
      'description': 'Fast neural machine translation framework and models',
      'license': 'MIT',
    },
    {
      'name': 'audioplayers',
      'description': 'Flutter plugin for audio playback across iOS, Android, macOS, and Web',
      'license': 'MIT',
    },
    {
      'name': 'record',
      'description': 'Audio recorder plugin supporting PCM, WAV, and AAC encoding',
      'license': 'MIT',
    },
    {
      'name': 'flutter_markdown',
      'description': 'Markdown renderer for Flutter supporting GitHub Flavored Markdown',
      'license': 'BSD-3-Clause',
    },
    {
      'name': 'archive',
      'description': 'Dart library for zip, tar, gzip compression and extraction',
      'license': 'MIT',
    },
    {
      'name': 'path_provider & path',
      'description': 'Flutter filesystem path location utilities and path manipulations',
      'license': 'BSD-3-Clause',
    },
    {
      'name': 'ffi',
      'description': 'Dart Foreign Function Interface for native C/C++ bindings',
      'license': 'BSD-3-Clause',
    },
    {
      'name': 'Flutter SDK',
      'description': 'Google open-source multi-platform application UI framework',
      'license': 'BSD-3-Clause',
    },
  ];

  void _copyRepoUrl(BuildContext context) {
    Clipboard.setData(const ClipboardData(text: _repoUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制 GitHub 开源仓库地址到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.88;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF2D3748)),
                      onPressed: onBack,
                    ),
                    const Text(
                      'About VoiceHub (关于应用)',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 12),
            Center(
              child: Column(
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset(
                        'assets/app_icon.png',
                        width: 76,
                        height: 76,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'VoiceHub',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'v1.0.0 (Build 1)',
                    style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '跨平台离线语音转写、实时同传与 AI 助手',
                    style: TextStyle(fontSize: 12, color: Color(0xFF718096)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '开发者信息 (Developer)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () {
                Clipboard.setData(const ClipboardData(text: 'guokezhen999@gmail.com'));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制开发者邮箱 (guokezhen999@gmail.com) 到剪贴板'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E3C72).withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.person_rounded, color: Color(0xFF1E3C72), size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text(
                            '郭珂桢 (Kezhen Guo)',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'guokezhen999@gmail.com',
                            style: TextStyle(fontSize: 12, color: Color(0xFF2B6CB0), fontWeight: FontWeight.w500),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Lead Developer & Project Maintainer',
                            style: TextStyle(fontSize: 11, color: Color(0xFF718096)),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.email_outlined, color: Colors.grey, size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Git 开源仓库 (Repository)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _copyRepoUrl(context),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF27AE60).withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.code_rounded, color: Color(0xFF27AE60), size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text(
                            'VoiceHub GitHub 仓库',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                          ),
                          SizedBox(height: 2),
                          Text(
                            _repoUrl,
                            style: TextStyle(fontSize: 12, color: Color(0xFF2B6CB0), fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.copy_rounded, color: Colors.grey, size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '第三方开源库清单 (Third-Party Libraries)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                ),
                Text(
                  '${_thirdPartyLibraries.length} 项',
                  style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _thirdPartyLibraries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final lib = _thirdPartyLibraries[index];
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            lib['name']!,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEDF2F7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              lib['license']!,
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF4A5568)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        lib['description']!,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF718096)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
