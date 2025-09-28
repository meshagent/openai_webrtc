# openai_webrtc

Flutter widgets and helpers to connect to OpenAI's Realtime API over WebRTC. It wraps `flutter_webrtc` and `openai_core` so you can capture microphone audio, play back the model’s audio, exchange realtime events over a data channel, and use tool calling — all with a simple widget.

Repository: https://github.com/meshagent/openai_webrtc


## Features
- Simple widget: `RealtimeSessionConnection` manages the full WebRTC session lifecycle.
- Controller API: `WebRTCSessionController` (extends `RealtimeSessionController`) to send events and observe server events.
- Audio in/out: captures mic input and plays remote audio from the model.
- Tool calling: provide `RealtimeFunctionToolHandler` instances via `initialTools`.
- Flexible options: `RealtimeSessionOptions` maps directly to Realtime session configuration (model, voice, formats, tool choice, etc.).


## Requirements
- Dart `>=3.8.0`
- Flutter (stable channel recommended)
- Platforms supported by `flutter_webrtc` (Android, iOS, macOS, web, desktop)

Platform notes for microphone/audio:
- iOS: Add `NSMicrophoneUsageDescription` to `ios/Runner/Info.plist`.
- Android: Add `<uses-permission android:name="android.permission.RECORD_AUDIO" />` in `android/app/src/main/AndroidManifest.xml`.
- Web: Serve over HTTPS (or `localhost`) for `getUserMedia` to work and grant microphone permission.


## Installation
Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  openai_webrtc: ^0.5.0
```

Then fetch packages:

```bash
flutter pub get
```


## Quickstart
Minimal example showing how to connect, listen for events, and send a message.

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:openai_core/openai_core.dart';
import 'package:openai_webrtc/openai_webrtc.dart';

class GetTimeTool extends RealtimeFunctionToolHandler {
  GetTimeTool()
      : super(
          metadata: RealtimeFunctionTool(
            name: 'get_current_time',
            parameters: {
              'type': 'object',
              'additionalProperties': false,
              'required': [],
              'properties': {},
            },
          ),
        );

  @override
  Future<String> execute(controller, arguments) async {
    return DateTime.now().toString();
  }
}

class RealtimeDemo extends StatelessWidget {
  const RealtimeDemo({super.key});

  @override
  Widget build(BuildContext context) {
    final openai = OpenAIClient(apiKey: 'YOUR_OPENAI_API_KEY');

    return RealtimeSessionConnection(
      openai: openai,
      options: RealtimeSessionOptions(
        model: RealtimeModel.gpt4oRealtimePreview,
        initialTools: [GetTimeTool()],
        // voice: SpeechVoice.alloy, // optional
      ),
      onReady: (controller) {
        // Observe events from the server
        controller.serverEvents
            .map((e) => jsonEncode(e.toJson()))
            .listen(debugPrint);

        // Send a simple text input as a response creation event
        controller.send(
          RealtimeResponseCreateEvent(
            response: RealtimeResponse(
              input: [
                RealtimeMessageItem(
                  role: 'user',
                  content: [RealtimeInputText('hello there!')],
                  status: null,
                ),
              ],
            ),
          ),
        );
      },
      builder: (context, controller) {
        if (controller == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return const Center(child: Text('Connected to Realtime API'));
      },
    );
  }
}
```

See a full runnable sample in `example/`.


## Widgets and APIs
- `RealtimeSessionConnection`:
  - Props: `openai` (`OpenAIClient`), `options` (`RealtimeSessionOptions`), `onReady`, and `builder`.
  - Behavior: establishes a WebRTC peer connection, opens a data channel (`oai-events`), captures mic input, plays remote audio, and exposes a `WebRTCSessionController` to your UI.
  - UI: renders nothing by default; your `builder` decides the UI.

- `RealtimeSessionOptions` (selected fields):
  - `model`: `RealtimeModel` (required)
  - `voice`: `SpeechVoice` (default `alloy`)
  - `instructions`: optional system prompt
  - `inputAudioFormat` / `outputAudioFormat`: default `pcm16`
  - `inputAudioTranscription`, `inputAudioNoiseReduction`, `turnDetection`
  - `initialTools`: `List<RealtimeFunctionToolHandler>`
  - `toolChoice`, `temperature`, `maxResponseOutputTokens`, `speed`, `tracing`
  - `clientSecretAnchor`, `clientSecretSeconds`

- `WebRTCSessionController` (extends `RealtimeSessionController`):
  - `send(RealtimeEvent event)`: send an event over the data channel
  - `serverEvents`: stream of `RealtimeEvent` from the model


## How it works
1. Creates a Realtime session via `openai_core`.
2. Uses `flutter_webrtc` to create a peer connection and data channel.
3. Publishes the local microphone track and plays remote audio.
4. Sends and receives Realtime events as JSON over the data channel.


## Security note (production)
The example passes your API key directly to the client to create the Realtime session. For production apps, do not ship your API key. Instead, expose a server endpoint that creates the session on your behalf and return an ephemeral client secret.

Example (Node/Express):

```js
app.get('/realtime-session', async (req, res) => {
  const r = await fetch('https://api.openai.com/v1/realtime/sessions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'gpt-4o-realtime-preview',
      voice: 'alloy',
    }),
  });
  res.status(r.status).json(await r.json());
});
```

Your Flutter app can then call your endpoint to fetch the ephemeral `client_secret.value` and use it to complete the SDP exchange. The `example/` app demonstrates a direct client-side flow for simplicity.


## Troubleshooting
- Microphone permission denied: ensure platform permissions are added and granted.
- Web requires HTTPS (or `localhost`) for audio capture to work.
- No audio playback: check system output device and that remote track is attached (the package uses an offscreen `RTCVideoRenderer`).
- ICE/connection failures: verify network conditions and STUN/TURN configuration if you customize the peer connection.


## License
MIT — see `LICENSE`.
