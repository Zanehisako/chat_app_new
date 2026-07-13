import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

import 'group_call_models.dart';

class GroupCallClient {
  GroupCallClient({required this.gateway, Room Function()? roomFactory})
      : _roomFactory = roomFactory ??
            (() => Room(
                  roomOptions: const RoomOptions(
                    adaptiveStream: true,
                    dynacast: true,
                  ),
                ));

  final GroupCallGateway gateway;
  final Room Function() _roomFactory;
  final StreamController<GroupCallSnapshot?> _snapshots =
      StreamController<GroupCallSnapshot?>.broadcast();
  Room? _room;
  GroupCallCredentials? _credentials;
  GroupCallState _state = GroupCallState.idle;
  String? _errorMessage;
  bool _disposed = false;

  Stream<GroupCallSnapshot?> get snapshots => _snapshots.stream;
  GroupCallSnapshot? get current =>
      _credentials == null ? null : _buildSnapshot();

  Future<void> start({
    required String conversationId,
    required bool isVideo,
  }) async {
    final credentials = await gateway.start(
      conversationId: conversationId,
      isVideo: isVideo,
    );
    await _connect(credentials);
  }

  Future<void> join({required String callId}) async {
    final credentials = await gateway.join(callId: callId);
    await _connect(credentials);
  }

  Future<void> _connect(GroupCallCredentials credentials) async {
    await _disconnectRoom();
    _credentials = credentials;
    _state = GroupCallState.connecting;
    _errorMessage = null;
    _emit();
    final room = _roomFactory();
    _room = room;
    room.addListener(_roomChanged);
    try {
      await room.connect(credentials.serverUrl, credentials.participantToken);
      final local = room.localParticipant;
      if (local == null) {
        throw StateError('LiveKit did not create a local participant');
      }
      await local.setMicrophoneEnabled(true);
      if (credentials.isVideo) await local.setCameraEnabled(true);
      _state = GroupCallState.active;
      _emit();
    } catch (error) {
      _state = GroupCallState.failed;
      _errorMessage = error.toString();
      _emit();
      try {
        await gateway.fail(callId: credentials.callId, reason: _errorMessage);
      } finally {
        await _disconnectRoom();
        _credentials = null;
        _emit(null);
      }
      rethrow;
    }
  }

  Future<void> setMuted(bool muted) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    await local.setMicrophoneEnabled(!muted);
    _emit();
  }

  Future<void> setCameraEnabled(bool enabled) async {
    final local = _room?.localParticipant;
    if (local == null || !(_credentials?.isVideo ?? false)) return;
    await local.setCameraEnabled(enabled);
    _emit();
  }

  Future<void> switchCamera() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final publication = local.videoTrackPublications.firstOrNull;
    final track = publication?.track;
    if (track == null) return;
    await rtc.Helper.switchCamera(track.mediaStreamTrack);
  }

  Future<void> leave() async {
    final credentials = _credentials;
    if (credentials != null) await gateway.leave(callId: credentials.callId);
    await _finish(GroupCallState.ended);
  }

  Future<void> _finish(GroupCallState state) async {
    _state = state;
    _emit();
    await _disconnectRoom();
    _credentials = null;
    _emit(null);
  }

  Future<void> _disconnectRoom() async {
    final room = _room;
    _room = null;
    if (room == null) return;
    room.removeListener(_roomChanged);
    await room.disconnect();
    await room.dispose();
  }

  void _roomChanged() {
    final connectionState = _room?.connectionState;
    if (connectionState == ConnectionState.reconnecting) {
      _state = GroupCallState.reconnecting;
    } else if (connectionState == ConnectionState.disconnected &&
        _state == GroupCallState.active) {
      _state = GroupCallState.ended;
    }
    if (_state == GroupCallState.connecting ||
        _state == GroupCallState.active ||
        _state == GroupCallState.reconnecting ||
        _state == GroupCallState.ended) {
      _emit();
    }
  }

  GroupCallSnapshot _buildSnapshot() {
    final room = _room;
    final participants = <GroupCallParticipant>[];
    if (room?.localParticipant case final local?) {
      participants.add(GroupCallParticipant(participant: local, isLocal: true));
    }
    if (room != null) {
      participants.addAll(
        room.remoteParticipants.values.map(
          (participant) =>
              GroupCallParticipant(participant: participant, isLocal: false),
        ),
      );
    }
    return GroupCallSnapshot(
      credentials: _credentials!,
      state: _state,
      participants: List.unmodifiable(participants),
      errorMessage: _errorMessage,
    );
  }

  void _emit([GroupCallSnapshot? snapshot]) {
    if (!_disposed && !_snapshots.isClosed) _snapshots.add(snapshot ?? current);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _disconnectRoom();
    await _snapshots.close();
  }
}
