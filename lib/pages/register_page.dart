import 'package:flutter/material.dart';
import 'home_page.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _accountController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _passphraseConfirmController = TextEditingController();
  bool _en = true; // language toggle
  bool _isLoading = false;

  Future<void> _completeRegistration() async {
    final account = _accountController.text.trim();
    if (account.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入账号')),
      );
      return;
    }

    if (_usernameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入昵称')),
      );
      return;
    }

    final passphrase = _passphraseController.text.trim();
    final passphrase2 = _passphraseConfirmController.text.trim();
    if (passphrase.isEmpty || passphrase2.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入密码并确认')),
      );
      return;
    }
    if (passphrase != passphrase2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('两次输入的密码不一致')),
      );
      return;
    }

    setState(() => _isLoading = true);

    // TODO(阶段5): 对接后端 API — POST /api/register { username, password, confirmPassword }
    await Future.delayed(const Duration(milliseconds: 300));

    if (mounted) {
      setState(() => _isLoading = false);
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
        (route) => false,
      );
    }
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        style: const TextStyle(
          fontFamily: 'Courier',
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: Colors.black.withOpacity(0.4),
            fontSize: 14,
          ),
          prefixIcon: Icon(icon, color: Colors.black26),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tAccount = _en ? 'Account' : '账号';
    final tNickname = _en ? 'Nickname' : '昵称';
    final tPassword = _en ? 'Password' : '密码';
    final tConfirm = _en ? 'Confirm Password' : '确认密码';
    final tEnter = _en ? 'Register' : '注册';
    final tNewIdentity = _en ? 'New Identity' : '创建身份';

    return Scaffold(
      backgroundColor: const Color(0xFFF9F9F9),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(84),
        child: Container(
          height: 84,
          padding: const EdgeInsets.only(top: 20, left: 16, right: 16),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              const SizedBox(width: 0),
              Text(tNewIdentity, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A), letterSpacing: -0.5, fontFamily: 'Courier')),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _en = !_en),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: Text(
                    _en ? 'EN' : '中',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A)),
                  ),
                ),
              )
            ],
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Create your local Decentralized ID (DID). Keys never leave this device.',
              style: TextStyle(
                fontSize: 14,
                color: Colors.black45,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 30),

            _buildTextField(controller: _accountController, label: '$tAccount (e.g. 123)', icon: Icons.badge_outlined),
            const SizedBox(height: 16),
            _buildTextField(controller: _usernameController, label: tNickname, icon: Icons.person_outline),
            const SizedBox(height: 24),
            _buildTextField(controller: _passphraseController, label: tPassword, icon: Icons.lock_outline, obscureText: true),
            const SizedBox(height: 16),
            _buildTextField(controller: _passphraseConfirmController, label: tConfirm, icon: Icons.lock_outline, obscureText: true),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _completeRegistration,
                child: _isLoading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Theme.of(context).colorScheme.onPrimary,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(tEnter, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
