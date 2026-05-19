import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  runApp(const VizitoObmenApp());
}

// ==================== КОНСТАНТЫ ====================
class AppConstants {
  static const String appName = 'Визито-Обмен';
  static const String apiBaseUrl = 'https://визито-обмен.фильмонлайн.рф/api.php';
  static const String siteUrl = 'https://визито-обмен.фильмонлайн.рф';
  static const String oplataUrl = 'https://визито-обмен.фильмонлайн.рф/oplata.php';
  static const int viewDuration = 300;
  static const int coinsPerView = 5;
  static const int coinsPerViewCost = 5; // Стоимость 1 показа
  
  static const Color primaryColor = Color(0xFF3B82F6);
  static const Color primaryDark = Color(0xFF2563EB);
  static const Color backgroundColor = Color(0xFF0D1117);
  static const Color cardColor = Color(0xFF1A202C);
  static const Color accentColor = Color(0xFF60A5FA);
  static const Color successColor = Color(0xFF10B981);
  static const Color warningColor = Color(0xFFEAB308);
  static const Color warningOrange = Color(0xFFF97316);
  static const Color errorColor = Color(0xFFEF4444);
  static const Color textPrimary = Color(0xFFF9FAFB);
  static const Color textSecondary = Color(0xFF9CA3AF);
}

// ==================== УВЕДОМЛЕНИЯ ====================
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications = 
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _notifications.initialize(settings);
  }

  static Future<void> showNotification({required String title, required String body}) async {
    const androidDetails = AndroidNotificationDetails(
      'vizito_channel', 'Визито-Обмен',
      importance: Importance.high, 
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _notifications.show(0, title, body, details);
  }
}

// ==================== МОДЕЛИ ====================
class UserData {
  final String id;
  final double balance;
  final double earned;
  final int referrals;
  final double referralEarned;
  final String authCode;

  UserData({
    required this.id, 
    required this.balance, 
    required this.earned, 
    required this.referrals, 
    required this.referralEarned, 
    required this.authCode
  });

  factory UserData.fromJson(Map<String, dynamic> json) => UserData(
    id: json['id'] ?? '',
    balance: (json['balance'] ?? 0).toDouble(),
    earned: (json['earned'] ?? 0).toDouble(),
    referrals: json['referrals'] ?? 0,
    referralEarned: (json['referral_earned'] ?? 0).toDouble(),
    authCode: json['auth_code'] ?? '',
  );

  String get refLink => '${AppConstants.siteUrl}?ref=$id';
}

class TopUser {
  final String id;
  final double earned;
  final double balance;
  
  TopUser({required this.id, required this.earned, required this.balance});
  
  factory TopUser.fromJson(Map<String, dynamic> json) => 
      TopUser(
        id: json['id'] ?? '', 
        earned: (json['earned'] ?? 0).toDouble(), 
        balance: (json['balance'] ?? 0).toDouble()
      );
}

// ==================== API ====================
class ApiService {
  Future<Map<String, dynamic>> _post(String action, {Map<String, dynamic>? params}) async {
    try {
      final uri = Uri.parse(AppConstants.apiBaseUrl);
      final body = <String, String>{
        'action': action,
        if (params != null) ...params.map((k, v) => MapEntry(k, v.toString())),
      };
      final response = await http.post(uri, body: body).timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return {'status': 'error', 'message': 'Ошибка сервера: ${response.statusCode}'};
    } catch (e) {
      return {'status': 'error', 'message': 'Ошибка: $e'};
    }
  }

  Future<UserData?> getUserData() async {
    final result = await _post('get_user_data');
    if (result['status'] == 'success' && result['data'] != null) {
      final authResult = await _post('get_auth_code');
      final data = result['data'] as Map<String, dynamic>;
      data['auth_code'] = authResult['code'] ?? '';
      return UserData.fromJson(data);
    }
    return null;
  }

  Future<Map<String, dynamic>> loginByCode(String code) => _post('login_by_code', params: {'code': code});
  Future<Map<String, dynamic>> logout() => _post('logout');
  Future<Map<String, dynamic>> addSite(String url, int views) => _post('add_site', params: {'url': url, 'views': views});
  Future<Map<String, dynamic>> startView() => _post('start_view');
  Future<Map<String, dynamic>> completeView() => _post('complete_view');
  
  Future<List<TopUser>> getTopUsers() async {
    final result = await _post('get_top');
    if (result['status'] == 'success' && result['top'] != null) {
      return (result['top'] as List).map((j) => TopUser.fromJson(j as Map<String, dynamic>)).toList();
    }
    return [];
  }
}

// ==================== STATE ====================
class AppState extends ChangeNotifier {
  final ApiService _api = ApiService();
  UserData? userData;
  bool isLoading = false;
  String? error;
  bool isViewing = false;
  int viewTimeLeft = AppConstants.viewDuration;
  String? currentViewUrl;
  Timer? _timer;
  bool _isPaused = false;
  bool _showCompletionDialog = false;
  bool _isWaitingForConfirmation = false;

  double get progress => viewTimeLeft / AppConstants.viewDuration;
  bool get showCompletionDialog => _showCompletionDialog;
  bool get isPaused => _isPaused;

  void pauseTimer() {
    if (_timer != null && !_isPaused && isViewing) {
      _timer?.cancel();
      _isPaused = true;
      notifyListeners();
    }
  }

  void resumeTimer() {
    if (_isPaused && isViewing) {
      _isPaused = false;
      _startTimer();
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      userData = await _api.getUserData();
      if (userData == null) error = 'Не удалось загрузить данные';
    } catch (e) {
      error = e.toString();
    }
    isLoading = false;
    notifyListeners();
  }

  Future<bool> loginByCode(String code) async {
    isLoading = true;
    notifyListeners();
    final result = await _api.loginByCode(code);
    isLoading = false;
    notifyListeners();
    if (result['status'] == 'success') {
      await refresh();
      return true;
    }
    error = result['message']?.toString();
    return false;
  }

  Future<void> logout() async {
    await _api.logout();
    userData = null;
    notifyListeners();
  }

  Future<bool> addSite(String url, int views) async {
    isLoading = true;
    notifyListeners();
    final result = await _api.addSite(url, views);
    isLoading = false;
    notifyListeners();
    if (result['status'] == 'success') {
      await refresh();
      return true;
    }
    error = result['message']?.toString();
    return false;
  }

  Future<void> startViewing() async {
    final result = await _api.startView();
    if (result['status'] == 'success') {
      currentViewUrl = result['url']?.toString();
      viewTimeLeft = AppConstants.viewDuration;
      isViewing = true;
      _isPaused = false;
      _showCompletionDialog = false;
      _isWaitingForConfirmation = false;
      notifyListeners();
      _startTimer();
    } else {
      error = result['message']?.toString();
      notifyListeners();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_isPaused || _isWaitingForConfirmation) return;
      
      if (viewTimeLeft > 0) {
        viewTimeLeft--;
        notifyListeners();
      } else {
        _showCompletionDialog = true;
        _isWaitingForConfirmation = true;
        _timer?.cancel();
        notifyListeners();
      }
    });
  }

  Future<void> confirmView(BuildContext context) async {
    _showCompletionDialog = false;
    notifyListeners();
    
    final result = await _api.completeView();
    if (result['status'] == 'success') {
      await NotificationService.showNotification(
        title: '+${AppConstants.coinsPerView} Монет!',
        body: 'Просмотр завершён, награда начислена',
      );
      await refresh();
      _isWaitingForConfirmation = false;
      startViewing();
    } else {
      error = result['message']?.toString();
      stopViewing();
      notifyListeners();
    }
  }

  void cancelView() {
    _showCompletionDialog = false;
    _isWaitingForConfirmation = false;
    stopViewing();
  }

  void stopViewing() {
    _timer?.cancel();
    isViewing = false;
    viewTimeLeft = AppConstants.viewDuration;
    currentViewUrl = null;
    _isPaused = false;
    _showCompletionDialog = false;
    _isWaitingForConfirmation = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ==================== ПРИЛОЖЕНИЕ ====================
class VizitoObmenApp extends StatelessWidget {
  const VizitoObmenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        primaryColor: AppConstants.primaryColor,
        scaffoldBackgroundColor: AppConstants.backgroundColor,
        colorScheme: const ColorScheme.dark(
          primary: AppConstants.primaryColor,
          secondary: AppConstants.accentColor,
          surface: AppConstants.cardColor,
        ),
        cardTheme: CardThemeData(
          color: AppConstants.cardColor,
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppConstants.cardColor, 
          elevation: 0, 
          centerTitle: true
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppConstants.primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.black.withValues(alpha: 0.4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), 
            borderSide: BorderSide.none
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), 
            borderSide: const BorderSide(color: AppConstants.primaryColor)
          ),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// ==================== ГЛАВНЫЙ ЭКРАН ====================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final AppState _appState = AppState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appState.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _appState.pauseTimer();
    } else if (state == AppLifecycleState.resumed) {
      _appState.resumeTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _appState,
      builder: (context, _) => Scaffold(
        appBar: _buildAppBar(),
        body: _appState.isLoading && _appState.userData == null
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(8), 
          decoration: BoxDecoration(
            color: AppConstants.primaryColor, 
            borderRadius: BorderRadius.circular(8)
          ),
          child: const Icon(Icons.sync, size: 20)
        ),
        const SizedBox(width: 8),
        const Text.rich(TextSpan(children: [
          TextSpan(text: 'ВИЗИТО ', style: TextStyle(fontWeight: FontWeight.bold)),
          TextSpan(text: 'ОБМЕН', style: TextStyle(color: AppConstants.accentColor, fontWeight: FontWeight.bold)),
        ])),
      ]),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center, 
            crossAxisAlignment: CrossAxisAlignment.end, 
            children: [
              const Text('Мой Баланс', style: TextStyle(fontSize: 10, color: AppConstants.textSecondary)),
              Text(
                '${_appState.userData?.balance.toStringAsFixed(2) ?? '0.00'} Монет',
                style: const TextStyle(fontSize: 14, color: AppConstants.accentColor, fontWeight: FontWeight.bold)
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.person, size: 28),
          onPressed: () => _showProfileModal(),
        ),
      ],
    );
  }

  Widget _buildBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // Главный блок "Начать Обмен Трафиком"
          _buildMainBlock(),
          const SizedBox(height: 12),
          
          // Блок функций
          _buildFunctionsBlock(),
          const SizedBox(height: 12),
          
          // ID пользователя
          _buildIdBlock(),
          const SizedBox(height: 12),
          
          // Блок покупки монет
          _buildBuyCoinsBlock(),
          const SizedBox(height: 12),
          
          // Описание
          _buildDescriptionBlock(),
        ],
      ),
    );
  }

  Widget _buildMainBlock() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppConstants.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: [
          Container(
            height: 4,
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
              color: AppConstants.primaryColor,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Icon(Icons.rocket_launch, size: 48, color: AppConstants.primaryColor),
                const SizedBox(height: 12),
                const Text(
                  'Начать Обмен Трафиком', 
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Просматривайте сайты других пользователей в течение 300 секунд и мгновенно получайте 5 Монет на свой баланс.',
                  textAlign: TextAlign.center, 
                  style: TextStyle(color: AppConstants.textSecondary, fontSize: 13)
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _appState.isViewing ? null : () => _startSurfing(),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('ЗАРАБОТАТЬ МОНЕТЫ', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFunctionsBlock() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppConstants.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.widgets, color: AppConstants.primaryColor, size: 20),
              SizedBox(width: 8),
              Text('Функции', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          _buildFunctionButton(Icons.add_circle_outline, 'Рекламировать сайт', () => _showAddSiteModal()),
          _buildFunctionButton(Icons.people_outline, 'Партнерская программа 20%', () => _showRefModal()),
          _buildFunctionButton(Icons.emoji_events_outlined, 'Топ 10 участников', () => _showTopModal()),
          _buildFunctionButton(Icons.login, 'Войти по коду', () => _showLoginModal()),
        ],
      ),
    );
  }

  Widget _buildFunctionButton(IconData icon, String title, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppConstants.primaryColor, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title, 
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIdBlock() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppConstants.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppConstants.primaryColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Ваш ID:', style: TextStyle(color: AppConstants.textSecondary, fontSize: 13)),
          SelectableText(
            _appState.userData?.id ?? '...', 
            style: const TextStyle(color: AppConstants.accentColor, fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.bold)
          ),
        ],
      ),
    );
  }

  Widget _buildBuyCoinsBlock() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppConstants.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: [
          Container(
            height: 4,
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
              gradient: LinearGradient(colors: [AppConstants.warningColor, AppConstants.warningOrange, AppConstants.errorColor]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Icon(Icons.monetization_on, size: 48, color: AppConstants.warningColor),
                const SizedBox(height: 8),
                const Text('Купить Монеты', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text(
                  'Быстрое пополнение баланса для продвижения ваших сайтов', 
                  textAlign: TextAlign.center, 
                  style: TextStyle(color: AppConstants.textSecondary, fontSize: 12)
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final uri = Uri.parse('https://yoomoney.ru/to/410014896664722');
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
                    icon: const Icon(Icons.bolt),
                    label: const Text('500 МОНЕТ — 100 РУБ', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppConstants.warningColor,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OplataScreen())),
                    icon: const Icon(Icons.mark_email_read, color: AppConstants.successColor),
                    label: const Text('СООБЩИТЬ ОБ ОПЛАТЕ', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppConstants.textPrimary,
                      side: const BorderSide(color: AppConstants.successColor, width: 2),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.shield, size: 14, color: AppConstants.textSecondary),
                    SizedBox(width: 4),
                    Text('Безопасная оплата через ЮMoney', style: TextStyle(color: AppConstants.textSecondary, fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDescriptionBlock() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppConstants.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: [
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: '«', style: TextStyle(fontFamily: 'serif')),
                const TextSpan(text: 'Визито-Обмен', style: TextStyle(fontFamily: 'serif', fontWeight: FontWeight.bold)),
                const TextSpan(text: '»', style: TextStyle(fontFamily: 'serif')),
                const TextSpan(text: ' — это инновационная автоматическая система обмена трафиком, созданная для взаимного продвижения сайтов и заработка в интернете.', style: TextStyle(fontFamily: 'serif')),
              ],
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppConstants.textSecondary, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 12),
          const Text('Как это работает?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Вы просматриваете сайты других участников в течение 300 секунд и получаете 5 Монет на баланс. Эти Монеты можно потратить на размещение своего сайта в ротации — всего за 5 Монет ваш ресурс увидит один новый посетитель в течение 300 секунд.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppConstants.textSecondary, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 12),
          const Text('Преимущества «Визито-Обмен»:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _buildAdvantageItem('Живой трафик — это реальные посетители сайта, пришедшие через iframe.'),
          _buildAdvantageItem('Бесплатный старт — 20 Монет в подарок при регистрации.'),
          _buildAdvantageItem('Авторегистрация — вам не нужно регистрироваться на сайте.'),
          _buildAdvantageItem('Код авторизации — используйте код из профиля для входа с любого устройства.'),
          _buildAdvantageItem('Партнёрская программа — приглашайте друзей и получайте 20% от их дохода пожизненно.'),
          _buildAdvantageItem('Безопасность — пул сайтов очищается после использования показов.'),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Присоединяйтесь к ', style: TextStyle(color: AppConstants.textSecondary, fontSize: 13)),
                const TextSpan(text: '«Визито-Обмен»', style: TextStyle(color: AppConstants.textSecondary, fontSize: 13, fontWeight: FontWeight.bold)),
                const TextSpan(text: ' уже сегодня и начните получать первых посетителей и стабильный доход! 🚀', style: TextStyle(color: AppConstants.textSecondary, fontSize: 13)),
              ],
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildAdvantageItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check, color: AppConstants.successColor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(color: AppConstants.textSecondary, fontSize: 12, height: 1.4)),
          ),
        ],
      ),
    );
  }

  // ==================== МОДАЛЬНЫЕ ОКНА ====================

  void _startSurfing() async {
    await _appState.startViewing();
    if (_appState.isViewing) {
      _showSurfingModal();
    } else if (_appState.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_appState.error!)),
      );
    }
  }

  void _showSurfingModal() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: AppConstants.backgroundColor,
            insetPadding: EdgeInsets.zero,
            child: ListenableBuilder(
              listenable: _appState,
              builder: (context, _) {
                // Показываем диалог завершения
                if (_appState.showCompletionDialog) {
                  return _buildCompletionDialog(dialogContext);
                }
                
                return Column(
                  children: [
                    // Верхняя панель
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppConstants.cardColor,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: Row(
                        children: [
                          // Таймер
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: AppConstants.primaryColor, width: 3),
                            ),
                            child: Center(
                              child: Text(
                                '${_appState.viewTimeLeft}',
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppConstants.accentColor),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Информация о сайте
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('ИДЕТ ПРОСМОТР САЙТА:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                Text(
                                  _appState.currentViewUrl ?? '',
                                  style: const TextStyle(fontSize: 10, color: AppConstants.accentColor),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Статус
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppConstants.successColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppConstants.successColor),
                            ),
                            child: const Text('+5 Монет', style: TextStyle(fontSize: 10, color: AppConstants.successColor, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 8),
                          // Кнопка прервать
                          TextButton(
                            onPressed: () {
                              _appState.stopViewing();
                              Navigator.of(dialogContext).pop();
                            },
                            style: TextButton.styleFrom(
                              backgroundColor: AppConstants.errorColor,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            child: const Text('Прервать', style: TextStyle(color: Colors.white, fontSize: 11)),
                          ),
                        ],
                      ),
                    ),
                    // WebView
                    Expanded(
                      child: WebViewWidget(
                        controller: WebViewController()
                          ..setJavaScriptMode(JavaScriptMode.unrestricted)
                          ..loadRequest(Uri.parse(_appState.currentViewUrl ?? AppConstants.siteUrl)),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildCompletionDialog(BuildContext dialogContext) {
    return AlertDialog(
      backgroundColor: AppConstants.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppConstants.successColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle, size: 48, color: AppConstants.successColor),
          ),
          const SizedBox(height: 16),
          const Text('Просмотр завершён!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Вы заработали +${AppConstants.coinsPerView} Монет',
            style: const TextStyle(fontSize: 16, color: AppConstants.successColor, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('Нажмите ОК для начисления монет и перехода к следующему сайту', style: TextStyle(color: AppConstants.textSecondary, fontSize: 12)),
        ],
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _appState.confirmView(context);
              // Показываем следующий сайт
              if (_appState.isViewing) {
                Future.delayed(const Duration(milliseconds: 500), () => _showSurfingModal());
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppConstants.successColor,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('ОК', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  void _showAddSiteModal() {
    final urlController = TextEditingController();
    int selectedViews = 5;
    final viewOptions = [
      {'views': 5, 'cost': 25},
      {'views': 10, 'cost': 50},
      {'views': 25, 'cost': 125},
      {'views': 50, 'cost': 250},
      {'views': 100, 'cost': 500},
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppConstants.cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Рекламировать сайт', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                const Text('Ссылка на ваш ресурс', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: urlController,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: 'https://mysite.com',
                    contentPadding: EdgeInsets.all(14),
                  ),
                ),
                const SizedBox(height: 8),
                const Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Если рекламируете видео вставляйте ссылку из кода ', style: TextStyle(color: AppConstants.textSecondary, fontSize: 11)),
                      TextSpan(text: 'iframe', style: TextStyle(color: AppConstants.accentColor, fontSize: 11)),
                      TextSpan(text: ' по кнопке поделиться под видео!', style: TextStyle(color: AppConstants.textSecondary, fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Количество показов', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: selectedViews,
                      isExpanded: true,
                      dropdownColor: AppConstants.cardColor,
                      items: viewOptions.map((opt) => DropdownMenuItem(
                        value: opt['views'] as int,
                        child: Text('${opt['views']} показов (${opt['cost']} Монет)', style: const TextStyle(fontSize: 14)),
                      )).toList(),
                      onChanged: (val) => setState(() => selectedViews = val ?? 5),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Стоимость: ', style: TextStyle(color: AppConstants.textSecondary, fontSize: 12)),
                      TextSpan(text: '5 Монет за 1 показ 300 секунд.', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                      TextSpan(text: ' Средства списываются сразу при добавлении.', style: TextStyle(color: AppConstants.textSecondary, fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (urlController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Введите ссылку')));
                        return;
                      }
                      Navigator.pop(context);
                      final success = await _appState.addSite(urlController.text.trim(), selectedViews);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(success ? 'Сайт успешно добавлен!' : (_appState.error ?? 'Ошибка'))),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('ОПЛАТИТЬ И ДОБАВИТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Отмена', style: TextStyle(color: AppConstants.textSecondary)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showRefModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppConstants.cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Партнерская программа', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text(
                'Присоединяйтесь к нашей реферальной программе! Приглашайте друзей, коллег и единомышленников в наше сообщество и получайте пассивный доход. За каждого приглашенного друга вы получаете 20% от каждого его заработка в Монетах. Это пожизненное вознаграждение!',
                style: TextStyle(color: AppConstants.textSecondary, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ВАША РЕФ-ССЫЛКА', style: TextStyle(fontSize: 10, color: AppConstants.primaryColor, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _appState.userData?.refLink ?? '',
                            style: const TextStyle(fontSize: 12, color: AppConstants.accentColor),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, color: AppConstants.primaryColor, size: 20),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _appState.userData?.refLink ?? ''));
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано!')));
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'Не забудьте сохранить ', style: TextStyle(color: AppConstants.textSecondary, fontSize: 12)),
                    TextSpan(text: 'код авторизации', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                    TextSpan(text: ' который находится в вашем профиле для входа в этот аккаунт!', style: TextStyle(color: AppConstants.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Text('${_appState.userData?.referrals ?? 0}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                          const Text('Рефералов', style: TextStyle(color: AppConstants.textSecondary, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Text('${_appState.userData?.referralEarned.toStringAsFixed(1) ?? '0'}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppConstants.accentColor)),
                          const Text('Монет получено', style: TextStyle(color: AppConstants.textSecondary, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: Colors.white24),
                  ),
                  child: const Text('ЗАКРЫТЬ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTopModal() async {
    final api = ApiService();
    final topUsers = await api.getTopUsers();
    
    if (!mounted) return;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppConstants.cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.emoji_events, color: AppConstants.warningColor),
                SizedBox(width: 8),
                Text('Топ 10 участников', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: topUsers.length,
                itemBuilder: (context, index) {
                  final user = topUsers[index];
                  final isCurrentUser = user.id == _appState.userData?.id;
                  
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isCurrentUser 
                          ? AppConstants.primaryColor.withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isCurrentUser ? AppConstants.primaryColor : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      children: [
                        // Место
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: index == 0 
                                ? AppConstants.warningColor 
                                : index == 1 
                                    ? Colors.grey 
                                    : index == 2 
                                        ? AppConstants.warningOrange 
                                        : AppConstants.cardColor,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: index < 3 ? Colors.black : Colors.white,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // ID
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('ID: ${user.id}', style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
                              if (isCurrentUser)
                                const Text('Это вы!', style: TextStyle(color: AppConstants.accentColor, fontSize: 10)),
                            ],
                          ),
                        ),
                        // Заработано
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('${user.earned.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, color: AppConstants.successColor, fontSize: 16)),
                            const Text('Монет', style: TextStyle(color: AppConstants.textSecondary, fontSize: 10)),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Colors.white24),
                ),
                child: const Text('ЗАКРЫТЬ', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLoginModal() {
    final codeController = TextEditingController();
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppConstants.cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Вход по коду', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text('Введите код авторизации из профиля в который нужно войти:', style: TextStyle(color: AppConstants.textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: codeController,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                hintText: 'Например: f09e4094',
                contentPadding: EdgeInsets.all(14),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final success = await _appState.loginByCode(codeController.text.trim());
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(success ? 'Вход выполнен!' : (_appState.error ?? 'Ошибка'))),
                  );
                },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('ВОЙТИ', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена', style: TextStyle(color: AppConstants.textSecondary)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showProfileModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppConstants.cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Мой профиль', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            _buildProfileRow('ID:', _appState.userData?.id ?? '...'),
            _buildProfileRow('Баланс:', '${_appState.userData?.balance.toStringAsFixed(2) ?? '0.00'} Монет', valueColor: AppConstants.accentColor),
            _buildProfileRow('Рефералов:', '${_appState.userData?.referrals ?? 0}'),
            _buildProfileRow('Реферальный бонус:', '${_appState.userData?.referralEarned.toStringAsFixed(1) ?? '0'} Монет'),
            const SizedBox(height: 12),
            const Text('Код авторизации:', style: TextStyle(color: AppConstants.textSecondary, fontSize: 13)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      _appState.userData?.authCode ?? '...',
                      style: const TextStyle(fontSize: 18, color: AppConstants.accentColor, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, color: AppConstants.primaryColor),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _appState.userData?.authCode ?? ''));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код скопирован!')));
                    },
                  ),
                ],
              ),
            ),
            const Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'Используйте этот код для входа в этот аккаунт с любого устройства. ', style: TextStyle(color: AppConstants.textSecondary, fontSize: 11)),
                  TextSpan(text: 'Сохранить обязательно!', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      await _appState.logout();
                      Navigator.pop(context);
                      _appState.refresh();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppConstants.errorColor,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Выйти'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Закрыть'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: AppConstants.textSecondary, fontSize: 13)),
          const SizedBox(width: 8),
          Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: valueColor ?? Colors.white)),
        ],
      ),
    );
  }
}

// ==================== ЭКРАН ОПЛАТЫ ====================
class OplataScreen extends StatefulWidget {
  const OplataScreen({super.key});

  @override
  State<OplataScreen> createState() => _OplataScreenState();
}

class _OplataScreenState extends State<OplataScreen> {
  late final WebViewController _controller;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => isLoading = true),
        onPageFinished: (_) => setState(() => isLoading = false),
      ))
      ..loadRequest(Uri.parse(AppConstants.oplataUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mark_email_read, color: AppConstants.successColor),
            SizedBox(width: 8),
            Text('Сообщить об оплате'),
          ],
        ),
        backgroundColor: AppConstants.cardColor,
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (isLoading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
