import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_models.dart';
import 'call_signaling.dart';

class CallClient {
  CallClient({
    required this.signaling,
    this.ringingTimeout = const Duration(seconds: 45),
  });

  final CallSignaling signaling;
  final Duration ringingTimeout;
  final _snapshots = StreamController<CallSnapshot?>.broadcast();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  dynamic _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  StreamSubscription<CallSignal>? _signalSubscription;
  final Set<String> _handledSignalIds = {};
  final List<CallSignal> _pendingCandidates = [];
  Timer? _ringingTimer;
  CallSnapshot? _current;
  bool _renderersInitialized = false;
  bool _remoteDescriptionSet = false;

  Stream<CallSnapshot?> get snapshots => _snapshots.stream;

  CallSnapshot? get current => _current;

  Stream<CallInvite> watchIncomingInvites() {
    return signaling.watchIncomingInvites();
  }

  Future<CallSnapshot> startCall({
    required String conversationId,
    required String peerUserId,
    required String peerName,
    required String callerName,
    required bool isVideo,
  }) async {
    await _ensureIdle();
    final invite = await signaling.createInvite(
      conversationId: conversationId,
      calleeId: peerUserId,
      callerName: callerName,
      isVideo: isVideo,
      expiresAt: DateTime.now().toUtc().add(ringingTimeout),
    );

    try {
      await _openPeer(
        callId: invite.id,
        conversationId: conversationId,
        peerUserId: peerUserId,
        peerName: peerName,
        direction: CallDirection.outgoing,
        isVideo: isVideo,
        initialState: CallState.dialing,
      );
      _startRingingTimer(invite.id);

      final offer = await _peerConnection.createOffer();
      await _peerConnection.setLocalDescription(offer);
      await signaling.sendSignal(
        CallSignal(
          callId: invite.id,
          senderId: signaling.localUserId,
          type: CallSignalType.offer,
          sdp: offer.sdp?.toString(),
          sdpType: offer.type?.toString(),
        ),
      );
    } catch (error) {
      await signaling.failCall(invite.id, error.toString());
      await _finish(CallState.failed, notifySignaling: false);
      rethrow;
    }

    _listenForSignals(invite.id, isCaller: true);
    return _current!;
  }

  Future<CallSnapshot> acceptInvite({
    required CallInvite invite,
    required String peerName,
  }) async {
    await _ensureIdle();
    if (invite.isExpired) {
      throw const CallException('That call has already expired.');
    }

    await signaling.acceptInvite(invite.id);
    try {
      await _openPeer(
        callId: invite.id,
        conversationId: invite.conversationId,
        peerUserId: invite.callerId,
        peerName: peerName,
        direction: CallDirection.incoming,
        isVideo: invite.isVideo,
        initialState: CallState.connecting,
      );
    } catch (error) {
      await signaling.failCall(invite.id, error.toString());
      await _finish(CallState.failed, notifySignaling: false);
      rethrow;
    }
    _listenForSignals(invite.id, isCaller: false);
    return _current!;
  }

  Future<void> rejectInvite(CallInvite invite) async {
    await signaling.rejectInvite(invite.id);
  }

  Future<void> hangUp() async {
    final snapshot = _current;
    if (snapshot == null) {
      return;
    }
    await _finish(CallState.ended);
  }

  Future<void> setMuted(bool muted) async {
    final stream = _localStream;
    if (stream == null) {
      return;
    }
    for (final track in stream.getAudioTracks()) {
      track.enabled = !muted;
    }
    _updateMedia((state) => state.copyWith(isMuted: muted));
  }

  Future<void> setCameraEnabled(bool enabled) async {
    final stream = _localStream;
    if (stream == null) {
      return;
    }
    for (final track in stream.getVideoTracks()) {
      track.enabled = enabled;
    }
    _updateMedia((state) => state.copyWith(isCameraEnabled: enabled));
  }

  Future<void> switchCamera() async {
    final stream = _localStream;
    if (stream == null) {
      return;
    }
    for (final track in stream.getVideoTracks()) {
      await Helper.switchCamera(track);
    }
  }

  Future<void> dispose() async {
    await _finish(CallState.ended, notifySignaling: false);
    if (_renderersInitialized) {
      await _localRenderer.dispose();
      await _remoteRenderer.dispose();
      _renderersInitialized = false;
    }
    await _snapshots.close();
  }

  Future<void> _openPeer({
    required String callId,
    required String conversationId,
    required String peerUserId,
    required String peerName,
    required CallDirection direction,
    required bool isVideo,
    required CallState initialState,
  }) async {
    if (!_renderersInitialized) {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      _renderersInitialized = true;
    }

    final iceServers = await signaling.fetchIceServers();
    final peerConnection = await createPeerConnection({
      'iceServers': iceServers.map((server) => server.toJson()).toList(),
      'sdpSemantics': 'unified-plan',
    });
    _peerConnection = peerConnection;

    final localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': isVideo
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            }
          : false,
    });
    _localStream = localStream;
    _localRenderer.srcObject = localStream;

    for (final track in localStream.getTracks()) {
      await peerConnection.addTrack(track, localStream);
    }

    peerConnection.onIceCandidate = (candidate) {
      unawaited(
        signaling.sendSignal(
          CallSignal(
            callId: callId,
            senderId: signaling.localUserId,
            type: CallSignalType.iceCandidate,
            candidate: candidate.candidate?.toString(),
            sdpMid: candidate.sdpMid?.toString(),
            sdpMLineIndex: candidate.sdpMLineIndex,
          ),
        ),
      );
    };

    peerConnection.onTrack = (event) {
      final streams = event.streams as List;
      if (streams.isEmpty) {
        return;
      }
      _remoteStream = streams.first as MediaStream;
      _remoteRenderer.srcObject = _remoteStream;
      _emitState(CallState.active);
    };

    _emit(
      CallSnapshot(
        callId: callId,
        conversationId: conversationId,
        peerUserId: peerUserId,
        peerName: peerName,
        direction: direction,
        state: initialState,
        mediaState: CallMediaState.initial(isVideo: isVideo),
        localRenderer: _localRenderer,
        remoteRenderer: _remoteRenderer,
      ),
    );
  }

  void _listenForSignals(String callId, {required bool isCaller}) {
    _signalSubscription = signaling
        .watchSignals(callId)
        .listen(
          (signal) => _handleSignal(signal, isCaller: isCaller),
          onError: (Object error) => _fail('Call signaling failed.', error),
        );
  }

  Future<void> _handleSignal(
    CallSignal signal, {
    required bool isCaller,
  }) async {
    final signalId = signal.id;
    if (signalId != null &&
        signalId.isNotEmpty &&
        !_handledSignalIds.add(signalId)) {
      return;
    }
    if (signal.senderId == signaling.localUserId) {
      return;
    }

    try {
      switch (signal.type) {
        case CallSignalType.offer:
          if (isCaller) {
            return;
          }
          _emitState(CallState.connecting);
          await _peerConnection.setRemoteDescription(
            RTCSessionDescription(signal.sdp, signal.sdpType ?? 'offer'),
          );
          _remoteDescriptionSet = true;
          await _flushPendingCandidates();
          final answer = await _peerConnection.createAnswer();
          await _peerConnection.setLocalDescription(answer);
          await signaling.sendSignal(
            CallSignal(
              callId: signal.callId,
              senderId: signaling.localUserId,
              type: CallSignalType.answer,
              sdp: answer.sdp?.toString(),
              sdpType: answer.type?.toString(),
            ),
          );
        case CallSignalType.answer:
          if (!isCaller) {
            return;
          }
          _ringingTimer?.cancel();
          _emitState(CallState.connecting);
          await _peerConnection.setRemoteDescription(
            RTCSessionDescription(signal.sdp, signal.sdpType ?? 'answer'),
          );
          _remoteDescriptionSet = true;
          await _flushPendingCandidates();
        case CallSignalType.iceCandidate:
          if (!_remoteDescriptionSet) {
            _pendingCandidates.add(signal);
            return;
          }
          await _addIceCandidate(signal);
        case CallSignalType.hangup:
          await _finish(CallState.ended, notifySignaling: false);
        case CallSignalType.reject:
          await _finish(CallState.rejected, notifySignaling: false);
      }
    } catch (error) {
      await _fail('Could not process call signal.', error);
    }
  }

  void _startRingingTimer(String callId) {
    _ringingTimer?.cancel();
    _ringingTimer = Timer(ringingTimeout, () {
      unawaited(signaling.failCall(callId, 'ring_timeout'));
      unawaited(_finish(CallState.failed, notifySignaling: false));
    });
  }

  Future<void> _flushPendingCandidates() async {
    final candidates = List<CallSignal>.from(_pendingCandidates);
    _pendingCandidates.clear();
    for (final candidate in candidates) {
      await _addIceCandidate(candidate);
    }
  }

  Future<void> _addIceCandidate(CallSignal signal) async {
    final candidate = signal.candidate;
    if (candidate == null || candidate.isEmpty) {
      return;
    }
    await _peerConnection.addCandidate(
      RTCIceCandidate(candidate, signal.sdpMid, signal.sdpMLineIndex),
    );
  }

  Future<void> _ensureIdle() async {
    final current = _current;
    if (current == null || current.isTerminal) {
      return;
    }
    throw const CallException('Another call is already active.');
  }

  Future<void> _fail(String message, Object error) async {
    debugPrint('[Call failed] $message $error');
    final snapshot = _current;
    if (snapshot != null) {
      await signaling.failCall(snapshot.callId, error.toString());
    }
    await _finish(
      CallState.failed,
      errorMessage: '$message ${error.toString()}',
      notifySignaling: false,
    );
  }

  void _updateMedia(CallMediaState Function(CallMediaState state) update) {
    final snapshot = _current;
    if (snapshot == null) {
      return;
    }
    _emit(
      CallSnapshot(
        callId: snapshot.callId,
        conversationId: snapshot.conversationId,
        peerUserId: snapshot.peerUserId,
        peerName: snapshot.peerName,
        direction: snapshot.direction,
        state: snapshot.state,
        mediaState: update(snapshot.mediaState),
        localRenderer: snapshot.localRenderer,
        remoteRenderer: snapshot.remoteRenderer,
        errorMessage: snapshot.errorMessage,
      ),
    );
  }

  void _emitState(CallState state, {String? errorMessage}) {
    final snapshot = _current;
    if (snapshot == null) {
      return;
    }
    _emit(
      CallSnapshot(
        callId: snapshot.callId,
        conversationId: snapshot.conversationId,
        peerUserId: snapshot.peerUserId,
        peerName: snapshot.peerName,
        direction: snapshot.direction,
        state: state,
        mediaState: snapshot.mediaState,
        localRenderer: snapshot.localRenderer,
        remoteRenderer: snapshot.remoteRenderer,
        errorMessage: errorMessage ?? snapshot.errorMessage,
      ),
    );
  }

  Future<void> _finish(
    CallState state, {
    String? errorMessage,
    bool notifySignaling = true,
  }) async {
    final snapshot = _current;
    _ringingTimer?.cancel();
    await _signalSubscription?.cancel();
    _signalSubscription = null;
    _handledSignalIds.clear();
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;

    if (notifySignaling && snapshot != null) {
      await signaling.endCall(snapshot.callId);
    }

    try {
      await _peerConnection?.close();
    } catch (_) {
      // WebRTC cleanup is best-effort after terminal states.
    }
    _peerConnection = null;

    final localStream = _localStream;
    if (localStream != null) {
      for (final track in localStream.getTracks()) {
        await track.stop();
      }
      await localStream.dispose();
    }
    _localStream = null;

    final remoteStream = _remoteStream;
    if (remoteStream != null) {
      for (final track in remoteStream.getTracks()) {
        await track.stop();
      }
      await remoteStream.dispose();
    }
    _remoteStream = null;
    if (_renderersInitialized) {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
    }

    if (snapshot == null) {
      _emit(null);
      return;
    }
    _emitState(state, errorMessage: errorMessage);
  }

  void _emit(CallSnapshot? snapshot) {
    _current = snapshot;
    if (!_snapshots.isClosed) {
      _snapshots.add(snapshot);
    }
  }
}
