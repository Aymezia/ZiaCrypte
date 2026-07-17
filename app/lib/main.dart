import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: ZiaCrypteApp()));
}

class ZiaCrypteApp extends StatelessWidget {
  const ZiaCrypteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'ZiaCrypte',
      home: Scaffold(
        body: Center(child: Text('ZiaCrypte — scaffolding Phase 5')),
      ),
    );
  }
}
