// 正常会话与页面调试共用同一套阶段页面。
import 'package:flutter/material.dart';
import '../app/controller.dart';
import 'auth_pages.dart';
import 'home.dart';
import 'lock.dart';
import 'pin_setup.dart';
import 'recovery_pages.dart';

Widget stagePage(AppController c) => switch (c.stage) {
  Stage.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
  Stage.connect => ConnectPage(c: c),
  Stage.signedOut => SignInPage(c: c),
  Stage.verifyEmail => VerifyEmailPage(c: c),
  Stage.setPin => SetPinPage(c: c),
  Stage.setup => SetupPage(c: c),
  Stage.unpaired => UnpairedPage(c: c),
  Stage.pairing => PairingWaitPage(c: c),
  Stage.locked => LockPage(c: c),
  Stage.rotation => RotationPage(c: c, forced: true),
  Stage.home => HomePage(c: c),
};
