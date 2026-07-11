import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _wasOnline = false;

  Future<void> start(Future<void> Function() onConnected) async {
    try {
      final initial = await _connectivity.checkConnectivity();
      _wasOnline = _isOnline(initial);
      if (_wasOnline) {
        unawaited(onConnected());
      }

      _subscription = _connectivity.onConnectivityChanged.listen((results) {
        final isOnline = _isOnline(results);
        final becameOnline = isOnline && !_wasOnline;
        _wasOnline = isOnline;
        if (becameOnline) {
          unawaited(onConnected());
        }
      });
    } catch (error) {
      debugPrint('[Connectivity] Connectivity listener unavailable: $error');
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
  }

  bool _isOnline(List<ConnectivityResult> results) {
    return results.any((result) => result != ConnectivityResult.none);
  }
}
