import 'package:flutter/material.dart';
import 'dart:ui';
import '../pages/home_page.dart';

class FloatingDock extends StatelessWidget {
  final List<Chat> chats;

  const FloatingDock({
    super.key,
    required this.chats,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 8,
      right: 8,
      bottom: 24,
      child: SafeArea(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              height: 104,
              padding: const EdgeInsets.symmetric(horizontal: 2), // 极致张力边缘
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.12), // 极度通透
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.15), width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween, // 横向张力布局
                children: List.generate(4, (index) {
                  return Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.12),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.asset(
                        'assets/avatars/girl${(index % 9) + 1}.png',
                        width: 58,
                        height: 58,
                        fit: BoxFit.cover,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
