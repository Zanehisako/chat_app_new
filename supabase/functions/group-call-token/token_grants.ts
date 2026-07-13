import { TrackSource } from "npm:livekit-server-sdk@2.17.0";

export function allowedPublishSources(isVideo: boolean): TrackSource[] {
  return isVideo
    ? [TrackSource.MICROPHONE, TrackSource.CAMERA]
    : [TrackSource.MICROPHONE];
}
