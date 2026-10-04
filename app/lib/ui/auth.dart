import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../controller.dart';
import '../core/model.dart';
import 'common.dart';

class AuthPage extends StatefulWidget {
  final AppController app;
  const AuthPage(this.app, {super.key});
  @override
  State<AuthPage> createState() => _AuthState();
}

class _AuthState extends State<AuthPage> {
  final email = TextEditingController(),
      password = TextEditingController(),
      server = TextEditingController();
  final form = GlobalKey<FormState>();
  String mode = 'login', notice = '';
  bool busy = false;
  AppController get app => widget.app;
  @override
  void initState() {
    super.initState();
    server.text = app.api.base;
    final action = Uri.base.queryParameters['action'];
    if (action == 'reset-password') mode = 'reset';
    if (action == 'verify-email') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        verify();
      });
    }
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    server.dispose();
    super.dispose();
  }

  Future<void> verify() async {
    setState(() => busy = true);
    await guard(context, () async {
      await app.api.call(
        'POST',
        '/auth/verify-email',
        body: {'token': Uri.base.queryParameters['token']},
        authenticated: false,
      );
      if (mounted) {
        setState(
          () => notice = 'Az e-mail-címed megerősítve. Most beléphetsz.',
        );
      }
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    await guard(context, () async {
      if (!kIsWeb) await app.configure(server.text);
      if (mode == 'login') {
        await app.login(email.text, password.text);
        return;
      }
      if (mode == 'register') {
        await app.api.call(
          'POST',
          '/auth/register',
          body: {'email': email.text.trim(), 'password': password.text},
          authenticated: false,
        );
        notice =
            'Nézd meg az e-mailjeidet, és erősítsd meg a címedet. Ezután beléphetsz.';
      }
      if (mode == 'forgot') {
        await app.api.call(
          'POST',
          '/auth/forgot-password',
          body: {'email': email.text.trim()},
          authenticated: false,
        );
        notice = 'Ha létezik a fiók, elküldtük a jelszó-visszaállító levelet.';
      }
      if (mode == 'reset') {
        await app.api.call(
          'POST',
          '/auth/reset-password',
          body: {
            'token': Uri.base.queryParameters['token'],
            'new_password': password.text,
          },
          authenticated: false,
        );
        notice = 'A jelszó megváltozott. Lépj be az új jelszóval.';
      }
      if (mounted) setState(() => mode = 'login');
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final title = {
      'login': 'Jó munkát a földeken.',
      'register': 'Hozz létre saját fiókot.',
      'forgot': 'Új jelszó kérése.',
      'reset': 'Válassz új jelszót.',
    }[mode]!;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.landscape_rounded, size: 38, color: green),
                      SizedBox(width: 12),
                      Text(
                        'Talajnyomás',
                        style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w700,
                          color: ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 36),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Két érzékelő. Egy mérés. A földjeid áttekinthető képe.',
                  ),
                  const SizedBox(height: 28),
                  if (app.simulated)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 20),
                      child: Hint(
                        'SZIMULÁTOR · Mesterséges nyomás és helyadatok. Próbáld ki fiók nélkül, vagy jelentkezz be egy service-tesztfiókkal. A teszteszközöket előbb importálni kell a service-be.',
                      ),
                    ),
                  if (notice.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Hint(notice),
                    ),
                  if (app.message != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Hint(app.message!, warning: true),
                    ),
                  Panel(
                    child: Form(
                      key: form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!kIsWeb) ...[
                            TextFormField(
                              controller: server,
                              enabled: !busy,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'Szolgáltatás címe',
                                hintText: 'https://pelda.hu/api/v1',
                              ),
                              validator: (s) => s == null || s.trim().isEmpty
                                  ? 'Add meg a szolgáltatás címét.'
                                  : null,
                            ),
                            const SizedBox(height: 18),
                          ],
                          if (mode != 'reset')
                            TextFormField(
                              controller: email,
                              enabled: !busy,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              decoration: const InputDecoration(
                                labelText: 'E-mail-cím',
                              ),
                              validator: (s) =>
                                  s == null ||
                                      !RegExp(
                                        r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                      ).hasMatch(s.trim())
                                  ? 'Érvényes e-mail-címet adj meg.'
                                  : null,
                            ),
                          if (mode != 'forgot') ...[
                            const SizedBox(height: 18),
                            TextFormField(
                              controller: password,
                              enabled: !busy,
                              obscureText: true,
                              autofillHints: [
                                mode == 'login'
                                    ? AutofillHints.password
                                    : AutofillHints.newPassword,
                              ],
                              decoration: InputDecoration(
                                labelText: mode == 'reset'
                                    ? 'Új jelszó'
                                    : 'Jelszó',
                              ),
                              validator: (s) => s == null || s.isEmpty
                                  ? 'Add meg a jelszót.'
                                  : mode != 'login' && s.length < 12
                                  ? 'Legalább 12 karaktert használj.'
                                  : null,
                              onFieldSubmitted: (_) => busy ? null : submit(),
                            ),
                          ],
                          const SizedBox(height: 24),
                          FilledButton(
                            onPressed: busy ? null : submit,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: busy
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      {
                                        'login': 'Belépés',
                                        'register': 'Regisztráció',
                                        'forgot': 'Levél kérése',
                                        'reset': 'Jelszó mentése',
                                      }[mode]!,
                                    ),
                            ),
                          ),
                          if (mode == 'login')
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => setState(() => mode = 'forgot'),
                              child: const Text('Elfelejtett jelszó'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(
                            () => mode = mode == 'login' ? 'register' : 'login',
                          ),
                    child: Text(
                      mode == 'login'
                          ? 'Még nincs fiókod? Regisztráció'
                          : 'Vissza a belépéshez',
                    ),
                  ),
                  if (mode == 'login')
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => guard(context, () async {
                              if (email.text.trim().isEmpty) {
                                throw const UserError(
                                  'Előbb add meg az e-mail-címedet.',
                                );
                              }
                              if (!kIsWeb) await app.configure(server.text);
                              await app.api.call(
                                'POST',
                                '/auth/resend-verification',
                                body: {'email': email.text.trim()},
                                authenticated: false,
                              );
                              if (mounted) {
                                setState(
                                  () => notice =
                                      'Ha szükséges, új megerősítő levelet küldtünk.',
                                );
                              }
                            }),
                      child: const Text('Megerősítő levél újraküldése'),
                    ),
                  if (!kIsWeb) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => guard(context, app.openLocal),
                      icon: const Icon(Icons.bluetooth),
                      label: const Text('Mérés fiók nélkül, ezen az eszközön'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'A helyi mód adatai ezen az eszközön maradnak, CSV-be exportálhatók. A fiókkal indított mérések automatikusan feltöltődnek.',
                      style: TextStyle(fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
