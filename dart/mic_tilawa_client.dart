/// Stream microphone audio to the surah checker and print mushaf words.
///
/// Dart port of `../python/mic_tilawa_client.py`. Matched words are looked up in
/// the qurani.ai word-by-word response and written to stdout. The ASR
/// transcript is not printed.
///
/// Microphone (16 kHz mono, via arecord):
///
///     dart run mic_tilawa_client.dart --api-key "$NABR_API_KEY" --surah 1
///
/// Pipe raw s16le 16 kHz mono PCM on stdin:
///
///     arecord -f S16_LE -r 16000 -c 1 -t raw -q \
///         | dart run mic_tilawa_client.dart --api-key "$NABR_API_KEY" --surah 1
///
/// Audio file (anything ffmpeg decodes, or raw s16le .pcm/.raw):
///
///     dart run mic_tilawa_client.dart --api-key "$NABR_API_KEY" --surah 25 --file ../assets/025_gqgDnUW8.mp3
///
/// Play that file locally while streaming it:
///
///     dart run mic_tilawa_client.dart --api-key "$NABR_API_KEY" --surah 25 --file ../assets/025_gqgDnUW8.mp3 --play
///
/// Send 20 ms Opus packets (needs libopus.so.0) instead of WAV chunks:
///
///     dart run mic_tilawa_client.dart --api-key "$NABR_API_KEY" --surah 1 --audio-format opus
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:ffi/ffi.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

const sampleRate = 16000;
const sampleWidth = 2;
const chunkMs = 200;
const chunkBytes = sampleRate * sampleWidth * chunkMs ~/ 1000;
// Server Opus decoder expects one 20 ms packet per message.
const opusFrameSamples = sampleRate * 20 ~/ 1000;
const opusFrameBytes = opusFrameSamples * sampleWidth;

const _success = 6;
const _surahFinished = 8;
const _exitNames = [
  'CHAPTER_NOT_SUPPORTED',
  'VERSE_NOT_FOUND',
  'VERSE_WORD_NOT_FOUND',
  'HAFZ_LEVEL_NOT_SUPPORTED',
  'TAJWEED_LEVEL_NOT_SUPPORTED',
  'UNEXPECTED_PROBLEM',
  'SUCCESS',
  'CHECK_FAILED',
  'SURAH_FINISHED',
];

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

// ---------------------------------------------------------------------------
// Arabic output

/// True when this terminal needs pre-shaped, visually ordered Arabic.
///
/// Terminals that already shape and reorder (GNOME Terminal, Kitty, Konsole)
/// must receive the original logical text or they reverse it again.
bool useVisualArabic(String mode) {
  final env = Platform.environment;
  if (mode == 'auto') mode = (env['NABR_ARABIC'] ?? 'auto').toLowerCase();
  if (mode == 'visual') return true;
  if (mode == 'logical') return false;
  const shapingTerminals = [
    'VTE_VERSION',
    'KITTY_WINDOW_ID',
    'WEZTERM_PANE',
    'KONSOLE_VERSION',
    'GHOSTTY_RESOURCES_DIR',
  ];
  return !shapingTerminals.any((name) => (env[name] ?? '').isNotEmpty);
}

/// Letter -> [isolated, final, initial, medial] presentation forms. A letter
/// with 4 forms joins both sides, 2 joins only the previous letter.
final _arabicForms = () {
  final forms = <int, List<int>>{};
  // Presentation Forms-B lists the letters in order with 1, 2 or 4 forms each.
  var next = 0xfe80;
  void add(int first, String counts) {
    for (var i = 0; i < counts.length; i++) {
      final n = int.parse(counts[i]);
      forms[first + i] = [for (var k = 0; k < n; k++) next + k];
      next += n;
    }
  }

  add(0x0621, '12222424244444222244444444'); // hamza .. ghain
  add(0x0641, '4444444224'); // feh .. yeh
  forms[0x0649] = [0xfeef, 0xfef0, 0xfbe8, 0xfbe9]; // alef maksura
  forms[0x0671] = [0xfb50, 0xfb51]; // alef wasla
  forms[0x0640] = [0x0640, 0x0640, 0x0640, 0x0640]; // tatweel
  return forms;
}();

/// Alef variant -> lam-alef ligature [isolated, final].
const _lamAlef = {
  0x0622: [0xfef5, 0xfef6],
  0x0623: [0xfef7, 0xfef8],
  0x0625: [0xfef9, 0xfefa],
  0x0627: [0xfefb, 0xfefc],
};

/// Same set as python arabic_reshaper's HARAKAT_RE.
bool _isHaraka(int c) =>
    (c >= 0x0610 && c <= 0x061a) ||
    (c >= 0x064b && c <= 0x065f) ||
    c == 0x0670 ||
    (c >= 0x06d6 && c <= 0x06dc) ||
    (c >= 0x06df && c <= 0x06e8) ||
    (c >= 0x06ea && c <= 0x06ed) ||
    (c >= 0x08d4 && c <= 0x08ff && c != 0x08e2);

/// Presentation forms so letters connect, then visual order, with harakat
/// kept after their letter (python arabic_reshaper + get_display).
// ponytail: visual order is a plain reversal, fine for mushaf words; mixed
// LTR text (digits, Latin) would need a real bidi pass.
String toVisualArabic(String logical) {
  final clusters = <List<int>>[];
  for (final c in logical.runes) {
    if (_isHaraka(c) && clusters.isNotEmpty) {
      clusters.last.add(c);
    } else {
      clusters.add([c]);
    }
  }
  int forms(int i) => i >= 0 && i < clusters.length
      ? _arabicForms[clusters[i][0]]?.length ?? 0
      : 0;

  final shaped = <List<int>>[];
  for (var i = 0; i < clusters.length; i++) {
    final cluster = clusters[i];
    final letter = _arabicForms[cluster[0]];
    final joinsPrev = forms(i) >= 2 && forms(i - 1) == 4;
    final ligature = cluster[0] == 0x0644 && i + 1 < clusters.length
        ? _lamAlef[clusters[i + 1][0]]
        : null;
    if (ligature != null) {
      shaped.add([
        ligature[joinsPrev ? 1 : 0],
        ...cluster.skip(1),
        ...clusters[++i].skip(1),
      ]);
      continue;
    }
    final joinsNext = forms(i) == 4 && forms(i + 1) >= 2;
    shaped.add(letter == null
        ? cluster
        : [
            letter[joinsPrev ? (joinsNext ? 3 : 1) : (joinsNext ? 2 : 0)],
            ...cluster.skip(1),
          ]);
  }
  return String.fromCharCodes(shaped.reversed.expand((c) => c));
}

// ---------------------------------------------------------------------------
// qurani.ai

const _surahApi = 'https://api.qurani.ai/gw/qh/v1/surah';
const _ayahsPerPage = 50;

/// Load every ayah of a surah, with per-word Hafs text.
Future<List<dynamic>> fetchWordByWordSurah(int surahNumber) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final ayahs = <dynamic>[];
    while (true) {
      final uri = Uri.parse('$_surahApi/$surahNumber/ar.wordbyword.hafs')
          .replace(queryParameters: {
        'words': 'true',
        'limit': '$_ayahsPerPage',
        'offset': '${ayahs.length}',
      });
      final (status, body) = await () async {
        final response = await (await client.getUrl(uri)).close();
        return (response.statusCode, await utf8.decodeStream(response));
      }()
          .timeout(const Duration(seconds: 30));
      if (status != 200) {
        throw HttpException(
          'qurani.ai API error $status: '
          '${body.substring(0, min(200, body.length))}',
        );
      }
      final page =
          (jsonDecode(body) as Map<String, dynamic>)['data']['ayahs'] as List;
      ayahs.addAll(page);
      if (page.length < _ayahsPerPage) return ayahs;
    }
  } finally {
    client.close();
  }
}

/// 1-based (verse, word) -> Hafs text, skipping verse-end markers.
class MushafWords {
  MushafWords(List<dynamic> verses) {
    for (final verse in verses) {
      final verseNumber = verse['numberInSurah'] as int;
      var wordIndex = 0;
      for (final word in verse['words'] as List) {
        if (word['char_type_name'] != 'word') continue;
        wordIndex++;
        _text[(verseNumber, wordIndex)] = word['text'] as String? ?? '';
      }
    }
  }

  final _text = <(int, int), String>{};

  String? text((int, int) key) => _text[key];
}

/// Print each newly matched mushaf word once, in verse order.
///
/// The current verse is redrawn as words arrive.
class WordEcho {
  WordEcho(this._mushaf, {this.visual = true});

  final MushafWords _mushaf;
  final bool visual;
  final _seen = <(int, int)>{};
  final _currentVerse = <String>[];
  int? _lastVerse;

  void echo(List<dynamic> correctWords) {
    final fresh = <((int, int), String)>[];
    for (final word in correctWords) {
      final key = (word['verse'] as int, word['word'] as int);
      if (!_seen.add(key)) continue;
      final text = _mushaf.text(key);
      if (text == null || text.isEmpty) {
        stderr.writeln('no mushaf text for verse ${key.$1} word ${key.$2}');
        continue;
      }
      fresh.add((key, text));
    }
    fresh.sort((a, b) => a.$1.$1 != b.$1.$1
        ? a.$1.$1.compareTo(b.$1.$1)
        : a.$1.$2.compareTo(b.$1.$2));
    for (final ((verse, _), text) in fresh) {
      if (_lastVerse != null && verse != _lastVerse) {
        stdout.write('\n');
        _currentVerse.clear();
      }
      _currentVerse.add(text);
      _lastVerse = verse;
      final line = _currentVerse.join(' ');
      stdout.write('\r\x1b[K${visual ? toVisualArabic(line) : line}');
    }
  }

  void finish() {
    if (_lastVerse != null) stdout.write('\n');
  }
}

// ---------------------------------------------------------------------------
// Audio

Uint8List pcmS16leToWav(List<int> pcm) {
  final header = ByteData(44)
    ..setUint32(0, 0x52494646) // RIFF
    ..setUint32(4, 36 + pcm.length, Endian.little)
    ..setUint32(8, 0x57415645) // WAVE
    ..setUint32(12, 0x666d7420) // "fmt "
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * sampleWidth, Endian.little)
    ..setUint16(32, sampleWidth, Endian.little)
    ..setUint16(34, sampleWidth * 8, Endian.little)
    ..setUint32(36, 0x64617461) // data
    ..setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}

/// Decode an audio file to 16 kHz mono s16le PCM.
Future<Uint8List> loadAudioPcm(String path) async {
  final lower = path.toLowerCase();
  if (lower.endsWith('.pcm') || lower.endsWith('.raw')) {
    return File(path).readAsBytes();
  }
  final result = await Process.run(
    'ffmpeg',
    [
      '-v',
      'error',
      '-i',
      path,
      '-f',
      's16le',
      '-ar',
      '$sampleRate',
      '-ac',
      '1',
      '-'
    ],
    stdoutEncoding: null,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
        'ffmpeg', [path], '${result.stderr}'.trim(), result.exitCode);
  }
  return Uint8List.fromList(result.stdout as List<int>);
}

/// Push file PCM in realtime-sized chunks so the server does not drop audio.
Stream<List<int>> pacedPcm(Uint8List pcm) async* {
  for (var offset = 0; offset < pcm.length; offset += chunkBytes) {
    yield Uint8List.sublistView(
        pcm, offset, min(offset + chunkBytes, pcm.length));
    await Future<void>.delayed(const Duration(milliseconds: chunkMs));
  }
}

const _alsaPcmArgs = [
  '-f',
  'S16_LE',
  '-r',
  '$sampleRate',
  '-c',
  '1',
  '-t',
  'raw',
  '-q'
];

/// Play 16 kHz mono s16le PCM on the default ALSA device.
Future<Process> openPlayback() async {
  final player = await Process.start('aplay', _alsaPcmArgs);
  // Swallow broken pipes, like the Python client.
  unawaited(player.stdin.done.catchError((_) {}));
  return player;
}

Future<Process> openMicrophone(String device) =>
    Process.start('arecord', ['-D', device, ..._alsaPcmArgs]);

/// libopus via FFI, 16 kHz mono, OPUS_APPLICATION_AUDIO.
class OpusEncoder {
  OpusEncoder() {
    final DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open('libopus.so.0');
    } on ArgumentError {
      throw const OSError('libopus.so.0 not found; install libopus0 or opus');
    }
    final create = lib.lookupFunction<
        Pointer<Void> Function(Int32, Int32, Int32, Pointer<Int32>),
        Pointer<Void> Function(int, int, int, Pointer<Int32>)>(
      'opus_encoder_create',
    );
    _encode = lib.lookupFunction<
        Int32 Function(
            Pointer<Void>, Pointer<Int16>, Int32, Pointer<Uint8>, Int32),
        int Function(Pointer<Void>, Pointer<Int16>, int, Pointer<Uint8>, int)>(
      'opus_encode',
    );
    _encoder = create(sampleRate, 1, 2049, nullptr);
    if (_encoder == nullptr) throw StateError('opus_encoder_create failed');
  }

  late final Pointer<Void> _encoder;
  late final int Function(
      Pointer<Void>, Pointer<Int16>, int, Pointer<Uint8>, int) _encode;
  // Lives for the whole process, never freed.
  final _pcm = malloc<Int16>(opusFrameSamples);
  final _out = malloc<Uint8>(4000);

  /// Encode exactly one 20 ms frame of s16le PCM.
  Uint8List encode(List<int> pcm) {
    _pcm.cast<Uint8>().asTypedList(opusFrameBytes).setAll(0, pcm);
    final n = _encode(_encoder, _pcm, opusFrameSamples, _out, 4000);
    if (n < 0) throw StateError('opus_encode failed: $n');
    return Uint8List.fromList(_out.asTypedList(n));
  }
}

// ---------------------------------------------------------------------------
// Session

String wsUrl(String base, String apiKey, String lang, String audioFormat) {
  final query = Uri(queryParameters: {
    'api_key': apiKey,
    'lang': lang,
    'audio_format': audioFormat,
  }).query;
  return '$base${base.contains('?') ? '&' : '?'}$query';
}

void _complete<T>(Completer<T> c, [T? value]) {
  if (!c.isCompleted) c.complete(value);
}

int _int(ArgResults args, String name) => int.parse(args.option(name)!);

Future<int> run(ArgResults args) async {
  final surah = _int(args, 'surah');
  final audioFormat = args.option('audio-format')!;
  final file = args.option('file');
  final input = args.option('input')!;
  final play = args.flag('play');
  final saveDir = args.option('save-responses');
  if (saveDir != null) await Directory(saveDir).create(recursive: true);
  var saved = 0;

  stderr.writeln('fetching surah $surah word by word...');
  final mushaf = MushafWords(await fetchWordByWordSurah(surah));
  final echo =
      WordEcho(mushaf, visual: useVisualArabic(args.option('arabic')!));
  final useStdin = input == 'stdin' || (input == 'auto' && !stdin.hasTerminal);

  // Sources are not listened to until the session starts; pipes buffer meanwhile.
  Process? mic;
  Process? player;
  final Stream<List<int>> source;
  if (file != null) {
    final pcm = await loadAudioPcm(file);
    final seconds = pcm.length / (sampleRate * sampleWidth);
    stderr.writeln('reading $file (${seconds.toStringAsFixed(1)}s)');
    source = pacedPcm(pcm);
  } else if (useStdin) {
    stderr.writeln('reading 16 kHz s16le mono PCM from stdin');
    source = stdin;
  } else {
    mic = await openMicrophone(args.option('device')!);
    stderr
        .writeln('capturing microphone via arecord (${args.option('device')})');
    source = mic.stdout;
  }
  if (play) {
    player = await openPlayback();
    stderr.writeln('playing audio locally');
  }

  final connected = Completer<void>();
  final started = Completer<int>();
  final finished = Completer<void>();
  final failed = Completer<void>();
  final ended = Completer<void>();
  final encoder = audioFormat == 'opus' ? OpusEncoder() : null;
  final url = wsUrl(args.option('url')!, args.option('api-key')!,
      args.option('lang')!, audioFormat);

  WebSocket? ws;
  Timer? ping;
  StreamSubscription<List<int>>? audio;
  stderr.writeln('connecting to $url');
  try {
    final socket = ws = await WebSocket.connect(url);
    void send(Map<String, Object?> message) =>
        socket.add(msgpack.serialize(message));

    socket.listen(
      (message) {
        if (message is! Uint8List) return;
        final event = msgpack.deserialize(message) as Map;
        if (saveDir != null) {
          File('$saveDir/${++saved}.json').writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert(event));
        }
        switch (event['event']) {
          case 'QRC_CLIENT_CONNECTED':
            _complete(connected);
          case 'TILAWA_SESSION_STARTED':
            _complete(started, event['exit_code'] as int);
          case 'TILAWA_RESULT':
            echo.echo(event['correct_words'] as List? ?? const []);
            if (event['exit_code'] == _surahFinished) _complete(finished);
          case 'QRC_ERROR':
            stderr.writeln('error: ${event['message'] ?? 'unknown error'}');
            _complete(failed);
          case 'TILAWA_SESSION_ENDED':
            _complete(ended);
        }
      },
      onError: (Object e) {
        stderr.writeln('error: $e');
        _complete(failed);
      },
      onDone: () {
        if (ended.isCompleted || failed.isCompleted) return;
        stderr.writeln('error: connection closed (${socket.closeCode})');
        _complete(failed);
      },
    );
    ping = Timer.periodic(const Duration(seconds: 5),
        (_) => send({'method': 'KEEP_ALIVE', 'sent_at': _nowMs()}));

    // Waits for [f], but returns early if the connection fails.
    Future<void> await10s(Future<void> f) =>
        Future.any([f, failed.future]).timeout(const Duration(seconds: 10));

    await await10s(connected.future);
    if (failed.isCompleted) return 1;
    send({
      'method': 'START_TILAWA_SESSION',
      'chapter_index': surah,
      'verse_index': _int(args, 'verse'),
      'word_index': _int(args, 'word'),
      'hafz_level': _int(args, 'hafz-level'),
      'tajweed_level': _int(args, 'tajweed-level'),
    });
    await await10s(started.future);
    if (failed.isCompleted) return 1;
    final exitCode = await started.future;
    if (exitCode != _success) {
      final name = exitCode >= 0 && exitCode < _exitNames.length
          ? _exitNames[exitCode]
          : '$exitCode';
      stderr.writeln('session refused: $name');
      return 1;
    }
    stderr.writeln(
        'session started; matched mushaf words appear after a few seconds of speech');

    final frameBytes = encoder != null ? opusFrameBytes : chunkBytes;
    final pending = <int>[];
    void sendAudio(List<int> pcm) => send({
          'method': 'CHECK_TILAWA_AUDIO',
          'audio': encoder?.encode(pcm) ?? pcmS16leToWav(pcm),
          'client_sent_at_ms': _nowMs(),
        });
    final sourceDone = Completer<void>();
    audio = source.listen(
      (piece) {
        if (player != null) {
          try {
            player.stdin.add(piece);
          } on StateError {
            // aplay went away; keep streaming.
          }
        }
        pending.addAll(piece);
        while (pending.length >= frameBytes) {
          sendAudio(pending.sublist(0, frameBytes));
          pending.removeRange(0, frameBytes);
        }
      },
      onDone: () {
        if (pending.isNotEmpty) {
          if (encoder != null) {
            pending.addAll(List.filled(opusFrameBytes - pending.length, 0));
          }
          sendAudio(pending);
        }
        _complete(sourceDone);
      },
      onError: (Object e) {
        stderr.writeln('error: audio source: $e');
        _complete(sourceDone);
      },
    );

    await Future.any([sourceDone.future, finished.future, failed.future]);
    final sourceEnded = !finished.isCompleted && !failed.isCompleted;
    await audio.cancel();
    if (failed.isCompleted) return 1;
    if (sourceEnded) {
      await finished.future
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    send({'method': 'RESET_TILAWA_SESSION'});
    await ended.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  } finally {
    ping?.cancel();
    await audio?.cancel();
    await ws?.close().timeout(const Duration(seconds: 2), onTimeout: () {});
    echo.finish();
    if (mic != null) {
      mic.kill();
      await mic.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
        mic!.kill(ProcessSignal.sigkill);
        return -1;
      });
    }
    if (player != null) {
      await player.stdin.close().catchError((_) {});
      await player.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
        player!.kill();
        return player.exitCode
            .timeout(const Duration(seconds: 1), onTimeout: () => -1);
      });
    }
  }
  if (finished.isCompleted) stderr.writeln('surah finished');
  return 0;
}

// ---------------------------------------------------------------------------
// CLI

ArgResults parseArgs(List<String> argv) {
  final env = Platform.environment;
  final parser = ArgParser()
    ..addOption('url',
        defaultsTo: env['NABR_WS_URL'] ?? 'wss://api.qurani.ai',
        help: 'WebSocket endpoint, or set NABR_WS_URL')
    ..addOption('api-key',
        defaultsTo: env['NABR_API_KEY'], help: 'API key, or set NABR_API_KEY')
    ..addOption('lang', defaultsTo: 'ar')
    ..addOption('surah', defaultsTo: '1')
    ..addOption('verse', defaultsTo: '1')
    ..addOption('word', defaultsTo: '1')
    ..addOption('hafz-level', defaultsTo: '1')
    ..addOption('tajweed-level', defaultsTo: '1')
    ..addOption('file',
        help: 'Audio file to stream instead of the microphone '
            '(anything ffmpeg decodes, or raw s16le 16 kHz mono .pcm/.raw)')
    ..addOption('input',
        allowed: ['auto', 'mic', 'stdin'],
        defaultsTo: 'auto',
        help: 'auto reads stdin when it is a pipe, otherwise the microphone')
    ..addOption('audio-format',
        allowed: ['wav', 'opus'],
        defaultsTo: 'wav',
        help: 'Format sent to the server '
            '(opus is 20 ms packets, smaller than wav)')
    ..addFlag('play',
        negatable: false,
        help: 'Play the audio locally with aplay while streaming it')
    ..addOption('arabic',
        allowed: ['auto', 'logical', 'visual'],
        defaultsTo: 'auto',
        help: 'How to print Arabic. auto uses logical text in GNOME Terminal, '
            'Kitty, Konsole, WezTerm, and Ghostty, and visual order elsewhere '
            '(including the Cursor terminal). Override with NABR_ARABIC.')
    ..addOption('device',
        defaultsTo: 'default', help: 'ALSA device passed to arecord -D')
    ..addOption('save-responses',
        valueHelp: 'DIR',
        help: 'Write each server event to DIR/1.json, DIR/2.json, ...')
    ..addFlag('help', abbr: 'h', negatable: false);

  Never usage(String message) {
    stderr
      ..writeln('error: $message')
      ..writeln(parser.usage);
    exit(2);
  }

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    usage(e.message);
  }
  if (args.flag('help')) {
    stdout
      ..writeln('Stream microphone PCM to the surah checker and echo mushaf '
          'words from the qurani.ai word-by-word API.\n')
      ..writeln(parser.usage);
    exit(0);
  }
  if ((args.option('api-key') ?? '').isEmpty) {
    usage('--api-key or NABR_API_KEY is required');
  }
  for (final name in [
    'surah',
    'verse',
    'word',
    'hafz-level',
    'tajweed-level'
  ]) {
    if (int.tryParse(args.option(name)!) == null) {
      usage('--$name must be an integer');
    }
  }
  final surah = _int(args, 'surah');
  if (surah < 1 || surah > 114) usage('--surah must be between 1 and 114');
  final file = args.option('file');
  if (file != null) {
    if (args.option('input') != 'auto') {
      usage('--file cannot be combined with --input');
    }
    if (!File(file).existsSync()) usage('file not found: $file');
  }
  return args;
}

Future<void> main(List<String> argv) async {
  final args = parseArgs(argv);
  ProcessSignal.sigint.watch().listen((_) {
    stderr.writeln();
    exit(130);
  });
  int code;
  try {
    code = await run(args);
  } on Exception catch (e) {
    stderr.writeln('error: $e');
    code = 1;
  }
  exit(code);
}
