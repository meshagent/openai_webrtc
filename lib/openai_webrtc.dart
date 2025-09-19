import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:openai_core/openai_core.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class RealtimeSessionOptions {
  RealtimeSessionOptions({
    this.voice = SpeechVoice.alloy,
    required this.model,
    this.instructions,
    this.inputAudioFormat = AudioFormat.pcm16,
    this.outputAudioFormat = AudioFormat.pcm16,
    this.inputAudioTranscription,
    this.inputAudioNoiseReduction,
    this.turnDetection,
    this.initialTools,
    this.temperature,
    this.maxResponseOutputTokens,
    this.speed,
    this.tracing,
    this.clientSecretAnchor,
    this.clientSecretSeconds,
    this.toolChoice,
  });

  final RealtimeModel model;
  final List<Modality> modalities = const [Modality.audio, Modality.text];
  final String? instructions;
  final SpeechVoice? voice;
  final AudioFormat inputAudioFormat;
  final AudioFormat outputAudioFormat;
  final InputAudioTranscription? inputAudioTranscription;
  final NoiseReduction? inputAudioNoiseReduction;
  final TurnDetection? turnDetection;
  final List<RealtimeFunctionToolHandler>? initialTools;
  final ToolChoice? toolChoice;
  final num? temperature;
  final int? maxResponseOutputTokens;
  final num? speed;
  final Tracing? tracing;
  final String? clientSecretAnchor;
  final int? clientSecretSeconds;
}

class RealtimeSessionConnection extends StatefulWidget {
  const RealtimeSessionConnection({
    super.key,
    required this.options,
    required this.builder,
    required this.openai,
    this.onReady,
  });

  final OpenAIClient openai;

  final RealtimeSessionOptions options;

  final void Function(WebRTCSessionController controller)? onReady;

  final Widget Function(
    BuildContext context,
    WebRTCSessionController? controller,
  )
  builder;

  @override
  State createState() => _RealtimeSessionConnectionState();
}

class _RealtimeSessionConnectionState extends State<RealtimeSessionConnection> {
  @override
  void initState() {
    super.initState();
    connect();
    renderer.initialize();
  }

  WebRTCSessionController? _controller;

  bool connected = false;

  Future<void> connect() async {
    // Get an ephemeral key from your server - see server code below
    final session = await widget.openai.createRealtimeSession(
      model: widget.options.model,
      voice: widget.options.voice,
      instructions: widget.options.instructions,
      inputAudioFormat: widget.options.inputAudioFormat,
      outputAudioFormat: widget.options.outputAudioFormat,
      inputAudioTranscription: widget.options.inputAudioTranscription,
      inputAudioNoiseReduction: widget.options.inputAudioNoiseReduction,
      turnDetection: widget.options.turnDetection,
      temperature: widget.options.temperature,
      maxResponseOutputTokens: widget.options.maxResponseOutputTokens,
      speed: widget.options.speed,
      tracing: widget.options.tracing,
      clientSecretAnchor: widget.options.clientSecretAnchor,
      clientSecretSeconds: widget.options.clientSecretSeconds,
      toolChoice: widget.options.toolChoice,
      tools: [
        ...(widget.options.initialTools?.map((t) => t.metadata) ?? const []),
      ],
    );
    final ephemeralKey = session.clientSecret!.value;

    // Create a peer connection
    final pc = await createPeerConnection({});

    WebRTCSessionController.create(
      connection: pc,
      initialTools: widget.options.initialTools,
    ).then((controller) {
      _controller = controller;
      final onReady = widget.onReady;

      if (onReady != null) {
        onReady(_controller!);

        if (context.mounted) {
          setState(() {
            connected = true;
          });
        }
      }
    });

    pc.onTrack = (evt) {
      print("on track ${evt.track}");

      renderer.srcObject = evt.streams[0];
    };

    pc.onAddStream = (stream) {
      print("added stream");
    };
    pc.onAddTrack = (stream, track) {
      print("Added track");
    };

    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
    );

    // Set up to play remote audio from the model
    // Add local audio track for microphone input in the browser
    final ms = await navigator.mediaDevices.getUserMedia({"audio": true});

    stream = ms;

    final tracks = ms.getTracks();
    await pc.addTrack(tracks[0], ms);

    // Start the session using the Session Description Protocol (SDP)
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    final sdpResponse = await widget.openai.getRealtimeSDP(
      model: widget.options.model,
      sdp: offer.sdp!,
      ephemeralKey: ephemeralKey,
    );

    final answer = RTCSessionDescription(sdpResponse, "answer");
    await pc.setRemoteDescription(answer);
  }

  MediaStream? stream;

  final renderer = RTCVideoRenderer();

  @override
  void dispose() {
    if (stream != null) {
      for (final t in stream!.getAudioTracks()) {
        t.stop();
      }
      stream?.dispose();
    }
    super.dispose();
    _controller?.dispose();
  }

  final portalController = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: portalController,
      overlayChildBuilder: (context) => (connected)
          ? SizedBox(width: 0, height: 0, child: RTCVideoView(renderer))
          : SizedBox(width: 0, height: 0),
      child: widget.builder(context, _controller),
    );
  }
}

class WebRTCSessionController extends RealtimeSessionController {
  WebRTCSessionController._({required this.connection, super.initialTools});

  Future<void> _init() async {
    // Set up data channel for sending and receiving events
    dataChannel = await connection.createDataChannel(
      "oai-events",
      RTCDataChannelInit(),
    );

    Completer<bool> c = Completer();

    dataChannel.onDataChannelState = (state) {
      if (state.name == "RTCDataChannelOpen") {
        c.complete(true);
      }
    };

    await c.future;

    dataChannel.onMessage = (message) {
      serverEventsController.add(
        RealtimeEvent.fromJson(jsonDecode(message.text)),
      );
    };
  }

  static Future<WebRTCSessionController> create({
    required RTCPeerConnection connection,
    List<RealtimeFunctionToolHandler>? initialTools,
  }) async {
    final c = WebRTCSessionController._(
      connection: connection,
      initialTools: initialTools,
    );
    await c._init();
    return c;
  }

  final RTCPeerConnection connection;
  late final RTCDataChannel dataChannel;

  @override
  Future<void> send(RealtimeEvent event) async {
    await dataChannel.send(RTCDataChannelMessage(jsonEncode(event.toJson())));
  }

  @override
  void dispose() {
    connection.close();
    connection.dispose();

    super.dispose();
  }
}
