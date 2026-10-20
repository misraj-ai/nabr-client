# Dart client

`mic_tilawa_client.dart` is a port of the [Python client](../python/README.md), with the same flags and output. It runs on the Dart VM or compiles to a single native binary. It uses only `dart:io` plus three packages: [`args`](https://pub.dev/packages/args), [`ffi`](https://pub.dev/packages/ffi) and [`msgpack_dart`](https://pub.dev/packages/msgpack_dart).

The options, output and exit codes are documented in the [main README](../README.md#options).

## Install

1. Install the system packages (Debian or Ubuntu; see the [main README](../README.md#system-packages) for other distributions):

   ```sh
   sudo apt install alsa-utils ffmpeg libopus0
   ```

2. Install the [Dart SDK](https://dart.dev/get-dart), 3.5 or newer. Flutter's bundled `dart` works too.

3. Fetch the packages, from this folder:

   ```sh
   dart pub get
   ```

## Run

```sh
export NABR_API_KEY="your-api-key"

dart run mic_tilawa_client.dart --surah 1
```

Without the environment variable, pass `--api-key` instead. The client connects to `wss://api.qurani.ai` unless you pass `--url` or set `NABR_WS_URL`.

## Build a binary

```sh
mkdir -p build
dart compile exe mic_tilawa_client.dart -o build/nabr-mic
./build/nabr-mic --surah 1
```

The binary does not need the Dart SDK. It still needs the system packages above at run time (`libopus0` only for `--audio-format opus`).

## Examples

Microphone with Opus packets:

```sh
dart run mic_tilawa_client.dart --surah 1 --audio-format opus
```

The sample recitation from [`assets/`](../assets/) (Surah al-Furqan), played locally while it streams:

```sh
dart run mic_tilawa_client.dart \
  --api-key "$API_KEY" \
  --surah 25 \
  --file ../assets/025_gqgDnUW8.mp3 \
  --play \
  --audio-format opus
```

Raw PCM on stdin:

```sh
arecord -f S16_LE -r 16000 -c 1 -t raw -q \
  | dart run mic_tilawa_client.dart --surah 1
```

Record every server event for debugging:

```sh
dart run mic_tilawa_client.dart --surah 25 --file ../assets/025_gqgDnUW8.mp3 --save-responses responses
ls responses     # 1.json 2.json 3.json ...
```

Each file holds one event, as received, in pretty-printed JSON. Files are numbered from 1 on every run, so a second run into the same folder overwrites the first.

## How it differs from the Python client

| | Python | Dart |
| --- | --- | --- |
| `--save-responses` | not available | available |
| Decoding `--file` | pydub (WAV natively, other formats through ffmpeg) | ffmpeg for every format except raw `.pcm` / `.raw` |
| Opus | `opuslib` | `libopus.so.0` loaded through `dart:ffi` |
| Arabic shaping (`--arabic visual`) | `arabic-reshaper` + `python-bidi` | Built in. Identical output, except that harakat on a lam-alef ligature stay on the ligature. |

## Self-check

`check.dart` checks the WAV header, the Arabic shaping and an Opus encode against reference values from the Python libraries:

```sh
dart run check.dart   # prints "ok"
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `error: --api-key or NABR_API_KEY is required` | Export `NABR_API_KEY` or pass `--api-key`. |
| `error: OS Error: libopus.so.0 not found…` | Install `libopus0` (Debian/Ubuntu) or `opus`, or use `--audio-format wav`. |
| `ProcessException: … ffmpeg` | Install `ffmpeg`, or pass a raw `.pcm` file. |
| `ProcessException: … arecord` / `aplay` | Install `alsa-utils`, or use `--file` / stdin without `--play`. |
| `Couldn't resolve the package 'args'` | Run `dart pub get` in this folder first. |
| Arabic looks reversed or unjoined | Try `--arabic logical` or `--arabic visual`. |
