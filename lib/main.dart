import 'package:flutter/material.dart';

import 'ui/receive_screen.dart';
import 'ui/send_screen.dart';

void main() => runApp(const LightBeamApp());

class LightBeamApp extends StatelessWidget {
  const LightBeamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LightBeam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Icon(Icons.flare, size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text('LightBeam',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displaySmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  'Send any file from screen to camera.\n'
                  'No internet, Wi-Fi, mobile data or Bluetooth.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 32),
                _ModeCard(
                  icon: Icons.upload_rounded,
                  title: 'Send',
                  subtitle: 'Show the file as a stream of light',
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const SendScreen())),
                ),
                const SizedBox(height: 16),
                _ModeCard(
                  icon: Icons.photo_camera_rounded,
                  title: 'Receive',
                  subtitle: 'Point your camera at the sender',
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const ReceiveScreen())),
                ),
                const SizedBox(height: 32),
                const _HowItWorks(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ModeCard(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(icon, size: 30),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleLarge),
                  Text(subtitle,
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    return const ExpansionTile(
      title: Text('How it works'),
      childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '1. The file is compressed and sealed with its name and a SHA-256 '
          'checksum.\n\n'
          '2. It is cut into blocks and turned into an endless "fountain" of '
          'packets. Each packet is a random XOR mix of blocks (LT codes), so '
          'the receiver can rebuild the file from almost any set of packets, '
          'in any order. Missed frames never need to be resent.\n\n'
          '3. Packets are written in Base45, which fits the QR alphanumeric '
          'alphabet exactly and packs about 30% more data per code than '
          'base64.\n\n'
          '4. The receiver peels the puzzle apart as frames arrive, and '
          'finishes the last pieces with Gaussian elimination, so it needs '
          'only a few percent more frames than the file has blocks.\n\n'
          'Tips: turn screen brightness up, avoid glare, fill the camera view '
          'with the code, and lower the speed if progress stalls.',
        ),
      ],
    );
  }
}
