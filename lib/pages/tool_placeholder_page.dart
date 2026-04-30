import 'package:flutter/material.dart';

class ToolPlaceholderPage extends StatelessWidget {
  final String title;

  const ToolPlaceholderPage({
    super.key,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F9F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, color: Colors.black, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          title,
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 17),
        ),
        centerTitle: true,
      ),
      body: Center(
        child: Text(
          '$title（占位）',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: Colors.black.withOpacity(0.45),
          ),
        ),
      ),
    );
  }
}

