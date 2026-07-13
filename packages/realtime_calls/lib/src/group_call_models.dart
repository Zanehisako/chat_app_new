import 'package:livekit_client/livekit_client.dart';

enum GroupCallState { idle, connecting, active, reconnecting, ended, failed }

class GroupCallCredentials {
  const GroupCallCredentials({
    required this.callId,
    required this.conversationId,
    required this.roomName,
    required this.serverUrl,
    required this.participantToken,
    required this.title,
    required this.participantId,
    required this.participantName,
    required this.isVideo,
  });

  final String callId;
  final String conversationId;
  final String roomName;
  final String serverUrl;
  final String participantToken;
  final String title;
  final String participantId;
  final String participantName;
  final bool isVideo;
}

abstract interface class GroupCallGateway {
  Future<GroupCallCredentials> start({
    required String conversationId,
    required bool isVideo,
  });

  Future<GroupCallCredentials> join({required String callId});

  Future<void> leave({required String callId});

  Future<void> fail({required String callId, String? reason});
}

class GroupCallParticipant {
  const GroupCallParticipant({
    required this.participant,
    required this.isLocal,
  });

  final Participant participant;
  final bool isLocal;

  String get identity => participant.identity;
  String get displayName =>
      participant.name.trim().isEmpty ? participant.identity : participant.name;
  bool get isMuted => participant.isMuted;
  VideoTrack? get videoTrack => participant.videoTrackPublications
      .where((publication) => publication.track != null)
      .map((publication) => publication.track)
      .whereType<VideoTrack>()
      .firstOrNull;
  bool get isCameraEnabled => videoTrack != null && !(videoTrack!.muted);
}

class GroupCallSnapshot {
  const GroupCallSnapshot({
    required this.credentials,
    required this.state,
    required this.participants,
    this.errorMessage,
  });

  final GroupCallCredentials credentials;
  final GroupCallState state;
  final List<GroupCallParticipant> participants;
  final String? errorMessage;

  bool get isTerminal =>
      state == GroupCallState.ended || state == GroupCallState.failed;
}
