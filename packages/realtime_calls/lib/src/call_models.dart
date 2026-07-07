import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum CallDirection { incoming, outgoing }

enum CallState {
  idle,
  dialing,
  ringing,
  connecting,
  active,
  ended,
  rejected,
  failed,
}

enum CallSignalType {
  offer('offer'),
  answer('answer'),
  iceCandidate('ice_candidate'),
  hangup('hangup'),
  reject('reject');

  const CallSignalType(this.value);

  final String value;

  static CallSignalType fromValue(String value) {
    return values.firstWhere(
      (type) => type.value == value,
      orElse: () => throw ArgumentError('Unknown call signal type: $value'),
    );
  }
}

class CallException implements Exception {
  const CallException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => details == null ? message : '$message $details';
}

class IceServer {
  const IceServer({required this.urls, this.username, this.credential});

  final List<String> urls;
  final String? username;
  final String? credential;

  Map<String, dynamic> toJson() {
    return {
      'urls': urls.length == 1 ? urls.single : urls,
      if (username != null && username!.isNotEmpty) 'username': username,
      if (credential != null && credential!.isNotEmpty)
        'credential': credential,
    };
  }

  factory IceServer.fromJson(Map<String, dynamic> json) {
    final urls = json['urls'];
    return IceServer(
      urls: urls is List
          ? urls.map((item) => item.toString()).toList()
          : [urls.toString()],
      username: json['username']?.toString(),
      credential: json['credential']?.toString(),
    );
  }
}

class CallInvite {
  const CallInvite({
    required this.id,
    required this.conversationId,
    required this.callerId,
    required this.calleeId,
    required this.callerName,
    required this.isVideo,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String conversationId;
  final String callerId;
  final String calleeId;
  final String callerName;
  final bool isVideo;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());
}

class CallSignal {
  const CallSignal({
    required this.callId,
    required this.senderId,
    required this.type,
    this.id,
    this.sdp,
    this.sdpType,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    this.createdAt,
  });

  final String? id;
  final String callId;
  final String senderId;
  final CallSignalType type;
  final String? sdp;
  final String? sdpType;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
  final DateTime? createdAt;
}

@immutable
class CallMediaState {
  const CallMediaState({
    required this.isMuted,
    required this.isCameraEnabled,
    required this.isSpeakerEnabled,
    required this.isVideoEnabled,
  });

  const CallMediaState.initial({required bool isVideo})
    : isMuted = false,
      isCameraEnabled = isVideo,
      isSpeakerEnabled = true,
      isVideoEnabled = isVideo;

  final bool isMuted;
  final bool isCameraEnabled;
  final bool isSpeakerEnabled;
  final bool isVideoEnabled;

  CallMediaState copyWith({
    bool? isMuted,
    bool? isCameraEnabled,
    bool? isSpeakerEnabled,
    bool? isVideoEnabled,
  }) {
    return CallMediaState(
      isMuted: isMuted ?? this.isMuted,
      isCameraEnabled: isCameraEnabled ?? this.isCameraEnabled,
      isSpeakerEnabled: isSpeakerEnabled ?? this.isSpeakerEnabled,
      isVideoEnabled: isVideoEnabled ?? this.isVideoEnabled,
    );
  }
}

class CallSnapshot {
  const CallSnapshot({
    required this.callId,
    required this.conversationId,
    required this.peerUserId,
    required this.peerName,
    required this.direction,
    required this.state,
    required this.mediaState,
    required this.localRenderer,
    required this.remoteRenderer,
    this.errorMessage,
  });

  final String callId;
  final String conversationId;
  final String peerUserId;
  final String peerName;
  final CallDirection direction;
  final CallState state;
  final CallMediaState mediaState;
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;
  final String? errorMessage;

  bool get isTerminal =>
      state == CallState.ended ||
      state == CallState.rejected ||
      state == CallState.failed;
}
