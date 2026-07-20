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
import 'package:voice_app/ui/screens/audio_file_transcription_screen.dart';
import 'package:voice_app/ui/screens/simultaneous_translation_screen.dart';
import 'package:voice_app/services/vad_settings.dart';
import 'package:voice_app/services/advanced_settings.dart';

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
                  title: const Text('Show performance metrics', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748))),
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
