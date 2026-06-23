import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'admin/admin_dashboard.dart';
import 'officer/officer_dashboard.dart';
import 'tsp/tsp_dashboard.dart';
import '../models/user.dart';
import '../models/user_role.dart';
import '../models/tsp_provider.dart';
import '../providers/app_state.dart';
import '../services/api_service.dart';



// ─── Login Screen ─────────────────────────────────────────────────────────────
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  String _selectedRole = 'Admin'; // dropdown value
  String? _selectedTsp;
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _serverWakingUp = false; // shows when cold-start takes >3 seconds
  String? _errorMessage;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }



  // ── Role changed: clear fields & error ──────────────────────────────────────
  void _onRoleChanged(String? value) {
    if (value == null) return;
    setState(() {
      _selectedRole = value;
      _emailController.clear();
      _passwordController.clear();
      _errorMessage = null;
      if (_selectedRole == 'TSP') {
        _selectedTsp = 'Airtel';
      } else {
        _selectedTsp = null;
      }
    });
  }


  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _serverWakingUp = false;
      _errorMessage = null;
    });

    // After 3 seconds, show a "Server waking up" banner for cold-start UX
    final wakeUpTimer = Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _isLoading) {
        setState(() => _serverWakingUp = true);
      }
    });

    final username = _emailController.text.trim();
    final password = _passwordController.text;

    // 1. Try backend API login first
    bool apiSuccess = false;
    String? apiError;
    try {
      final appState = Provider.of<AppState>(context, listen: false);
      apiSuccess = await appState.login(username, password);
      
      if (!apiSuccess) {
        apiError = 'Server rejected credentials. Check username/password.';
      }
    } catch (e) {
      apiError = 'Cannot connect to server: $e';
      // ignore: avoid_print
      print('[LOGIN ERROR] $e');
    }

    // ignore the wakeUpTimer future result
    wakeUpTimer.ignore();

    if (apiSuccess) {
      if (!mounted) return;
      final appState = Provider.of<AppState>(context, listen: false);
      final currentUser = appState.currentUser;
      if (currentUser != null) {
        // Redirect based on the authenticated user's actual role
        Widget dashboard;
        if (currentUser.role == UserRole.ADMIN) {
          dashboard = const AdminDashboard();
        } else if (currentUser.role == UserRole.OFFICER) {
          dashboard = const OfficerDashboard();
        } else {
          dashboard = const TSPDashboard();
        }
        Navigator.pushReplacement(
          context,
          _buildRoute(dashboard),
        );
        return;
      }
    }

    setState(() {
      _isLoading = false;
      _serverWakingUp = false;
      _errorMessage = apiError ?? 'Invalid username or password for $_selectedRole portal. Please try again.';
    });
  }

  PageRoute _buildRoute(Widget screen) => PageRouteBuilder(
        pageBuilder: (_, __, ___) => screen,
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: anim,
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 400),
      );

  // ─────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 800;

    return Scaffold(
      body: Stack(
        children: [
          // ── Background glows ────────────────────────────────────────────────
          Positioned(
            top: -120,
            right: -120,
            child: _glow(320, const Color(0xFF6366F1), 0.18),
          ),
          Positioned(
            bottom: -80,
            left: -80,
            child: _glow(280, const Color(0xFFEC4899), 0.13),
          ),
          Positioned(
            top: size.height * 0.4,
            left: size.width * 0.3,
            child: _glow(200, const Color(0xFF06B6D4), 0.07),
          ),



          // ── Card ────────────────────────────────────────────────────────────
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: FadeTransition(
                opacity: _fadeAnim,
                child: SlideTransition(
                  position: _slideAnim,
                  child: Container(
                    width: isDesktop ? 460 : double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 30, vertical: 38),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B).withOpacity(0.88),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.09),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.35),
                          blurRadius: 40,
                          offset: const Offset(0, 20),
                        ),
                        BoxShadow(
                          color: const Color(0xFF6366F1).withOpacity(0.06),
                          blurRadius: 60,
                          offset: const Offset(0, -5),
                        ),
                      ],
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // ── Logo ────────────────────────────────────────────
                          Center(
                            child: Container(
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFF6366F1),
                                    Color(0xFF4F46E5)
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF6366F1)
                                        .withOpacity(0.45),
                                    blurRadius: 20,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.security_update_good_rounded,
                                size: 42,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 22),

                          // ── Title ────────────────────────────────────────────
                          const Text(
                            'Secure SMS Portal',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'TSP Information Management System',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[400],
                              letterSpacing: 0.4,
                            ),
                          ),
                          const SizedBox(height: 32),

                          // ── Role Dropdown ─────────────────────────────────────
                          _buildLabel('Login as'),
                          const SizedBox(height: 8),
                          _buildRoleDropdown(),
                          const SizedBox(height: 20),

                          // ── TSP Dropdown (conditionally visible) ──────────────
                          if (_selectedRole == 'TSP') ...[
                            _buildLabel('Select TSP'),
                            const SizedBox(height: 8),
                            _buildTspDropdown(),
                            const SizedBox(height: 20),
                          ],

                          // ── Username Field ───────────────────────────────────────
                          _buildLabel('Username'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.text,
                            style: const TextStyle(color: Colors.white),
                            decoration: _inputDecoration(
                              hint: _getUsernameHint(),
                              icon: Icons.person_outline_rounded,
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return 'Please enter your username';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 18),

                          // ── Password Field ────────────────────────────────────
                          _buildLabel('Password'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            style: const TextStyle(color: Colors.white),
                            decoration: _inputDecoration(
                              hint: '••••••••••',
                              icon: Icons.lock_outline,
                              suffix: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: Colors.grey[500],
                                  size: 20,
                                ),
                                onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword),
                              ),
                            ),
                            validator: (v) {
                              if (v == null || v.isEmpty) {
                                return 'Please enter your password';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 10),


                          // ── Server waking up notice ────────────────────────
                          if (_isLoading && _serverWakingUp) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.amber.shade900.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: Colors.amber.shade700.withOpacity(0.4)),
                              ),
                              child: const Row(
                                children: [
                                  SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(Colors.amber),
                                    ),
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Server is waking up... This may take up to 60 seconds on first login.',
                                      style: TextStyle(color: Colors.amber, fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],

                          // ── Error ─────────────────────────────────────────────
                          if (_errorMessage != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.red.shade900.withOpacity(0.35),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color:
                                        Colors.red.shade700.withOpacity(0.4)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error_outline,
                                      color: Colors.redAccent, size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _errorMessage!,
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 12.5),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],

                          // ── Login Button ──────────────────────────────────────
                          const SizedBox(height: 8),
                          _buildLoginButton(),


                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Widgets ──────────────────────────────────────────────────────────────────

  Widget _glow(double size, Color color, double opacity) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withOpacity(opacity),
        ),
      );

  Widget _buildLabel(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: Colors.grey[400],
          letterSpacing: 0.5,
        ),
      );

  Widget _buildRoleDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: ['Admin', 'Officer'].contains(_selectedRole)
              ? _selectedRole
              : 'Admin',
          dropdownColor: const Color(0xFF1E293B),
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down_rounded,
              color: Color(0xFF6366F1)),
          style: const TextStyle(color: Colors.white, fontSize: 15),
          items: const [
            DropdownMenuItem(
              value: 'Admin',
              child: Row(
                children: [
                  Icon(Icons.admin_panel_settings_outlined,
                      color: Color(0xFF6366F1), size: 20),
                  SizedBox(width: 10),
                  Text('Admin'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'Officer',
              child: Row(
                children: [
                  Icon(Icons.location_searching,
                      color: Color(0xFFEC4899), size: 20),
                  SizedBox(width: 10),
                  Text('Field Officer'),
                ],
              ),
            ),
          ],
          onChanged: _onRoleChanged,
        ),
      ),
    );
  }

  Widget _buildTspDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedTsp,
          dropdownColor: const Color(0xFF1E293B),
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down_rounded,
              color: Color(0xFF6366F1)),
          style: const TextStyle(color: Colors.white, fontSize: 15),
          items: const [
            DropdownMenuItem(
              value: 'Airtel',
              child: Row(
                children: [
                  Icon(Icons.cell_tower, color: Color(0xFF6366F1), size: 20),
                  SizedBox(width: 10),
                  Text('Airtel'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'Jio',
              child: Row(
                children: [
                  Icon(Icons.cell_tower, color: Color(0xFF6366F1), size: 20),
                  SizedBox(width: 10),
                  Text('Jio'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'Vodafone Idea (Vi)',
              child: Row(
                children: [
                  Icon(Icons.cell_tower, color: Color(0xFF6366F1), size: 20),
                  SizedBox(width: 10),
                  Text('Vodafone Idea (Vi)'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'BSNL',
              child: Row(
                children: [
                  Icon(Icons.cell_tower, color: Color(0xFF6366F1), size: 20),
                  SizedBox(width: 10),
                  Text('BSNL'),
                ],
              ),
            ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _selectedTsp = value;
              _emailController.clear();
              _passwordController.clear();
              _errorMessage = null;
            });
          },
        ),
      ),
    );
  }

  String _getUsernameHint() {
    if (_selectedRole == 'Admin') return 'admin@smstsp.com';
    if (_selectedRole == 'Officer') return 'officer@smstsp.com';
    if (_selectedTsp == 'Airtel') return 'rep_airtel';
    if (_selectedTsp == 'Jio') return 'rep_jio';
    if (_selectedTsp == 'Vodafone Idea (Vi)') return 'rep_vi';
    return 'rep_bsnl';
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
      prefixIcon: Icon(icon, color: const Color(0xFF6366F1), size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: const Color(0xFF0F172A).withOpacity(0.5),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.red.shade600),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.red.shade600, width: 2),
      ),
    );
  }

  Widget _buildLoginButton() {
    final isAdmin = _selectedRole == 'Admin';
    final isTsp = _selectedRole == 'TSP';
    final List<Color> colors;
    if (isTsp) {
      colors = const [Color(0xFF6366F1), Color(0xFF4F46E5)];
    } else if (isAdmin) {
      colors = const [Color(0xFF6366F1), Color(0xFF4F46E5)];
    } else {
      colors = const [Color(0xFFEC4899), Color(0xFFBE185D)];
    }
    return Container(
      height: 54,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          colors: colors,
        ),
        boxShadow: [
          BoxShadow(
            color: (isAdmin || isTsp
                    ? const Color(0xFF6366F1)
                    : const Color(0xFFEC4899))
                .withOpacity(0.35),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isTsp
                        ? Icons.cell_tower
                        : (isAdmin
                            ? Icons.admin_panel_settings_outlined
                            : Icons.location_searching),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isTsp
                        ? 'Login to TSP Portal'
                        : (isAdmin
                            ? 'Login to Admin Portal'
                            : 'Login to Officer Portal'),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
