import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:smart_navigation/services/ai_detection_service.dart';

class DetectionClient extends http.BaseClient {
  DetectionClient(this.reply);
  final Future<http.StreamedResponse> Function(http.BaseRequest request) reply;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    return reply(request);
  }
}

http.StreamedResponse validReply() => http.StreamedResponse(
  Stream.value(
    utf8.encode(
      jsonEncode({
        'success': true,
        'image_width': 100,
        'image_height': 80,
        'objects': [],
      }),
    ),
  ),
  200,
);

void main() {
  late Directory directory;
  late XFile image;
  setUp(() async {
    dotenv.loadFromString(envString: 'AI_SERVER_URL=https://backend.example');
    directory = await Directory.systemTemp.createTemp('detection-test-');
    final file = File('${directory.path}/frame.jpg');
    await file.writeAsBytes([1, 2, 3]);
    image = XFile(file.path);
  });
  tearDown(() async {
    await File(image.path).delete();
    await directory.delete();
  });

  test('valid multipart reply produces a detection result', () async {
    final service = AiDetectionService(
      client: DetectionClient((request) async {
        expect(request.method, 'POST');
        final multipart = request as http.AbortableMultipartRequest;
        expect(multipart.files.single.field, 'image');
        return validReply();
      }),
    );
    addTearDown(service.dispose);
    final result = await service.detect(image);
    expect(result.imageWidth, 100);
    expect(result.imageHeight, 80);
    expect(result.objects, isEmpty);
  });

  test('stalled response body times out and aborts the request', () async {
    final body = StreamController<List<int>>();
    final aborted = Completer<void>();
    final service = AiDetectionService(
      requestTimeout: const Duration(milliseconds: 80),
      client: DetectionClient((request) async {
        final multipart = request as http.AbortableMultipartRequest;
        unawaited(
          multipart.abortTrigger!.then((_) {
            aborted.complete();
            body.addError(http.RequestAbortedException(request.url));
            unawaited(body.close());
          }),
        );
        return http.StreamedResponse(body.stream, 200);
      }),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.detect(image),
      throwsA(
        isA<AiDetectionException>().having(
          (error) => error.message,
          'message',
          contains('quá thời gian'),
        ),
      ),
    );
    await aborted.future;
    await body.done;
  });

  test(
    'header timeout aborts the request and a later request can succeed',
    () async {
      var first = true;
      final aborted = Completer<void>();
      final service = AiDetectionService(
        requestTimeout: const Duration(milliseconds: 80),
        client: DetectionClient((request) async {
          if (!first) return validReply();
          first = false;
          await (request as http.AbortableMultipartRequest).abortTrigger;
          aborted.complete();
          throw http.RequestAbortedException(request.url);
        }),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.detect(image),
        throwsA(isA<AiDetectionException>()),
      );
      await aborted.future;
      expect((await service.detect(image)).imageWidth, 100);
    },
  );

  test('headers and body share one deadline', () async {
    final body = StreamController<List<int>>();
    final service = AiDetectionService(
      requestTimeout: const Duration(milliseconds: 120),
      client: DetectionClient((request) async {
        unawaited(
          (request as http.AbortableMultipartRequest).abortTrigger!.then((_) {
            body.addError(http.RequestAbortedException(request.url));
            unawaited(body.close());
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        // The body arrives within 120ms of the headers, but beyond the total deadline.
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 80), () {
            if (!body.isClosed) {
              body.add(utf8.encode('{"success":true,"objects":[]}'));
              unawaited(body.close());
            }
          }),
        );
        return http.StreamedResponse(body.stream, 200);
      }),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.detect(image),
      throwsA(isA<AiDetectionException>()),
    );
    await body.done;
  });

  test('backend inference errors retain their status message', () async {
    final service = AiDetectionService(
      client: DetectionClient(
        (_) async => http.StreamedResponse(
          Stream.value(utf8.encode('inference failed')),
          500,
        ),
      ),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.detect(image),
      throwsA(
        isA<AiDetectionException>().having(
          (error) => error.message,
          'message',
          contains('500'),
        ),
      ),
    );
  });
}
