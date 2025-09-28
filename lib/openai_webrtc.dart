import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:openai_core/openai_core.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class RealtimeSessionOptions {
  RealtimeSessionOptions({
    this.model,
    this.outputModalities,
    this.audio,
    this.instructions,
    this.initialTools,
    this.toolChoice,
    this.temperature,
    this.maxOutputTokens,
    this.tracing,
  });

  final List<Modality>? outputModalities;
  final RealtimeModel? model;
  final RealtimeSessionAudio? audio;
  final String? instructions;
  final List<RealtimeFunctionToolHandler>? initialTools;
  final ToolChoice? toolChoice;
  final double? temperature;
  final dynamic maxOutputTokens;
  final Tracing? tracing;
}

class RealtimeSessionConnection extends StatefulWidget {
  const RealtimeSessionConnection({
    super.key,
    required this.options,
    required this.builder,
    required this.openai,
    this.constraints = const {},
    this.onReady,
    this.errorBuilder,
  });

  final Map<String, dynamic> constraints;

  final OpenAIClient openai;

  final RealtimeSessionOptions options;

  final void Function(WebRTCSessionController controller)? onReady;

  final Widget Function(
    BuildContext context,
    WebRTCSessionController? controller,
  )
  builder;

  final Widget Function(BuildContext context, Object? error)? errorBuilder;

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
    try {
      // Create a peer connection
      final pc = await createPeerConnection({}, widget.constraints);

      pc.onTrack = (evt) {
        renderer.srcObject = evt.streams[0];
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

      // Set up data channel for sending and receiving events
      final dataChannel = await pc.createDataChannel(
        "oai-events",
        RTCDataChannelInit(),
      );

      Completer<bool> c = Completer();

      dataChannel.onDataChannelState = (state) {
        if (state.name == "RTCDataChannelOpen") {
          c.complete(true);
        }
      };

      // Start the session using the Session Description Protocol (SDP)
      final offer = await await pc.createOffer(widget.constraints);
      await pc.setLocalDescription(offer);

      final session = await widget.openai.createCall(
        sdp: offer.sdp!,
        model: widget.options.model,
        outputModalities: widget.options.outputModalities,
        audio: widget.options.audio,
        instructions: widget.options.instructions,
        toolChoice: widget.options.toolChoice,
        temperature: widget.options.temperature,
        maxOutputTokens: widget.options.maxOutputTokens,
        tracing: widget.options.tracing,
        tools: [
          ...(widget.options.initialTools?.map((t) => t.metadata) ?? const []),
        ],
      );

      final answer = RTCSessionDescription(session.sdpAnswer, "answer");
      await pc.setRemoteDescription(answer);

      final controller = await WebRTCSessionController.create(
        connection: pc,
        initialTools: widget.options.initialTools,
        dataChannel: dataChannel,
      );

      await c.future;

      _controller = controller;
      final onReady = widget.onReady;

      if (onReady != null) {
        onReady(_controller!);
      }

      if (context.mounted) {
        setState(() {
          connected = true;
        });
      }
    } on Exception catch (err) {
      if (context.mounted) {
        setState(() {
          error = err;
        });
      }
    }
  }

  Exception? error;

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
      child: error != null
          ? (widget.errorBuilder != null
                ? widget.errorBuilder!(context, error)
                : Text("$error"))
          : widget.builder(context, _controller),
    );
  }
}

class WebRTCSessionController extends RealtimeSessionController {
  WebRTCSessionController._({
    required this.connection,
    super.initialTools,
    required this.dataChannel,
  });

  final RTCDataChannel dataChannel;

  static Future<WebRTCSessionController> create({
    required RTCPeerConnection connection,
    required RTCDataChannel dataChannel,
    List<RealtimeFunctionToolHandler>? initialTools,
  }) async {
    final c = WebRTCSessionController._(
      connection: connection,
      initialTools: initialTools,
      dataChannel: dataChannel,
    );

    dataChannel.onMessage = (message) {
      c.serverEventsController.add(
        RealtimeEvent.fromJson(jsonDecode(message.text)),
      );
    };

    return c;
  }

  final RTCPeerConnection connection;

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
