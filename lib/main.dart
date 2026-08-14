import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app_scope.dart';
import 'app/app_shell.dart';
import 'app/app_state.dart';
import 'backend/supabase_service.dart';
import 'theme/sr_tokens.dart';
import 'widgets/toast_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(useDemoData: false);
  const url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://tyniwgrvfxkfzhbiufib.supabase.co',
  );
  const key = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_8TRsZIH1OEeEGkOrJ0y7oQ_g_IRxcr8',
  );
  await Supabase.initialize(url: url, publishableKey: key);
  state.configureBackend(SupabaseService(Supabase.instance.client));
  runApp(SmartReserveApp(state: state));
}

class SmartReserveApp extends StatefulWidget {
  const SmartReserveApp({super.key, required this.state});

  final AppState state;

  @override
  State<SmartReserveApp> createState() => _SmartReserveAppState();
}

class _SmartReserveAppState extends State<SmartReserveApp> {
  late Future<void> _bootstrap;

  @override
  void initState() {
    super.initState();
    _bootstrap = _boot();
  }

  Future<void> _boot() =>
      widget.state.initializeBackend().timeout(const Duration(seconds: 20));

  void _retryBoot() => setState(() => _bootstrap = _boot());

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _bootstrap,
    builder: (context, snapshot) => AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'SmartReserve · CSU Aparri',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'IBM Plex Sans',
          scaffoldBackgroundColor: SR.bg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: SR.blue,
            primary: SR.blue,
            surface: SR.surface,
          ),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          textSelectionTheme: const TextSelectionThemeData(
            selectionColor: Color(0xFFCFE0F7),
            cursorColor: SR.blue,
          ),
          tooltipTheme: TooltipThemeData(
            waitDuration: const Duration(milliseconds: 400),
            decoration: BoxDecoration(
              color: SR.ink,
              borderRadius: BorderRadius.circular(7),
            ),
            textStyle: sans(11, color: SR.surface),
          ),
          scrollbarTheme: ScrollbarThemeData(
            thickness: WidgetStateProperty.all(10),
            thumbColor: WidgetStateProperty.all(const Color(0xFFD5D9E0)),
            radius: const Radius.circular(6),
          ),
        ),
        builder: (context, child) =>
            AppToastHost(child: child ?? const SizedBox.shrink()),
        home: switch (snapshot.connectionState) {
          ConnectionState.waiting => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
          _ when snapshot.hasError => Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Could not connect',
                      style: sans(15, w: 600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Check your connection and try again.',
                      textAlign: TextAlign.center,
                      style: sans(12, color: SR.muted),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _retryBoot,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _ => const AppShell(),
        },
      ),
    ),
  );
}
