import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'asr_screen.dart';
import 'tts_screen.dart';
import 'translation_screen.dart';
import 'model_manager.dart';
import 'model_management_sheet.dart';
import 'native_nmt_service.dart';
import 'llama_nmt_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HardwareKeyboard.instance.clearState();
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

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _currentIndex = 0;
  bool _showPerfMetrics = false;

  List<Widget> get _screens => [
    const AsrScreen(),
    const TtsScreen(),
    TranslationScreen(showPerfMetrics: _showPerfMetrics),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () {
            showModalBottomSheet(
              context: context,
              builder: (context) => StatefulBuilder(
                builder: (context, setModalState) => Padding(
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
                        value: _showPerfMetrics,
                        onChanged: (val) {
                          setModalState(() {});
                          setState(() {
                            _showPerfMetrics = val;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
          tooltip: 'Settings',
        ),
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_shared_outlined),
            onPressed: () {
              final type = _currentIndex == 0 ? 'asr' : (_currentIndex == 1 ? 'tts' : 'nmt');
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => ModelManagementSheet(
                  initialType: type,
                  onModelsChanged: () {},
                ),
              );
            },
            tooltip: 'Manage Models',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.mic),
            label: 'ASR (STT)',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.speaker_notes),
            label: 'TTS (Speech)',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.translate),
            label: 'NMT (Translate)',
          ),
        ],
      ),
    );
  }
}
