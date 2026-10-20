# nabr-client

Command-line clients for the Nabr surah checker. They stream a recitation to the surah-checker WebSocket and print the mushaf words the server matched, live, one ayah per line.

There are two clients with the same flags and behaviour:

| Client | Folder | Runtime | Good for |
| --- | --- | --- | --- |
| Python | [`python/`](python/README.md) | Python 3.11+ with [uv](https://docs.astral.sh/uv/) | Quick runs with no install step |
| Dart | [`dart/`](dart/README.md) | Dart SDK 3.5+ | A single compiled binary, and a reference for Flutter apps |

Each client is a single file. Audio can come from the microphone, an audio file, or raw PCM piped on stdin.

## Quick start

You need an API key. Both clients read it from the environment:

```sh
export NABR_API_KEY="your-api-key"
```

They connect to `wss://api.qurani.ai` by default. To use another server, such as a local one, pass `--url` or set `NABR_WS_URL`:

```sh
export NABR_WS_URL="ws://127.0.0.1:8000"
```

Install the system packages (Debian or Ubuntu):

```sh
sudo apt install alsa-utils ffmpeg libopus0
```

Python:

```sh
uv run python/mic_tilawa_client.py --surah 1
```

Dart:

```sh
cd dart
dart pub get
dart run mic_tilawa_client.dart --surah 1
```

Start reciting. The first words show up after a few seconds of speech. Press Ctrl+C to stop.

## System packages

| Needed for | Debian / Ubuntu | Fedora | Arch |
| --- | --- | --- | --- |
| Microphone (`arecord`) and `--play` (`aplay`) | `alsa-utils` | `alsa-utils` | `alsa-utils` |
| `--file` with mp3, ogg, flac (Dart: every format except raw PCM) | `ffmpeg` | `ffmpeg-free` | `ffmpeg` |
| `--audio-format opus` | `libopus0` | `opus` | `opus` |

The clients are built and tested on Linux. Microphone capture and `--play` call the ALSA tools, so they work only on Linux. On other systems, use `--file` or pipe PCM on stdin.

## Examples

These use the Python command, run from the repository root. For Dart, run from `dart/`, replace `uv run python/mic_tilawa_client.py` with `dart run mic_tilawa_client.dart`, and write the sample as `../assets/025_gqgDnUW8.mp3`.

[`assets/025_gqgDnUW8.mp3`](assets/025_gqgDnUW8.mp3) is a sample recitation of Surah al-Furqan (25), about 17½ minutes long. Use it to try the clients without a microphone.

Microphone, sending Opus packets (much smaller than WAV):

```sh
uv run python/mic_tilawa_client.py --surah 1 --audio-format opus
```

Start from a specific ayah and word:

```sh
uv run python/mic_tilawa_client.py --surah 2 --verse 255 --word 1
```

Stream the bundled sample recitation in real time, and hear it while it streams:

```sh
uv run python/mic_tilawa_client.py \
  --surah 25 \
  --file assets/025_gqgDnUW8.mp3 \
  --play \
  --audio-format opus
```

Pipe raw 16 kHz mono s16le PCM from another program:

```sh
arecord -f S16_LE -r 16000 -c 1 -t raw -q \
  | uv run python/mic_tilawa_client.py --surah 1
```

Use a different microphone (list devices with `arecord -L`):

```sh
uv run python/mic_tilawa_client.py --surah 1 --device plughw:1,0
```

## Options

| Option | Default | Description |
| --- | --- | --- |
| `--url` | `wss://api.qurani.ai` | Surah-checker WebSocket endpoint. Can be set with `NABR_WS_URL`. |
| `--api-key` | `NABR_API_KEY` | API key. Required. |
| `--lang` | `ar` | Language for server messages: `ar`, `en`, `es`, `tr`, `id`, or `ur`. |
| `--surah` | `1` | Surah number, 1 to 114. |
| `--verse` | `1` | Ayah to start from. |
| `--word` | `1` | Word in that ayah to start from. |
| `--hafz-level` | `1` | Hafz level, 1 to 3. |
| `--tajweed-level` | `1` | Tajweed level, 1 to 5. |
| `--file` | | Audio file to stream instead of the microphone: wav, mp3, ogg, flac, or raw `.pcm` / `.raw` (16 kHz mono s16le). It is sent at real-time speed. |
| `--input` | `auto` | `auto` reads stdin when it is a pipe, otherwise the microphone. Force it with `mic` or `stdin`. Cannot be combined with `--file`. |
| `--audio-format` | `wav` | `wav` sends 200 ms WAV chunks. `opus` sends 20 ms Opus packets. |
| `--play` | off | Play the audio locally with `aplay` while streaming it. With a microphone, use headphones so the playback is not recorded again. |
| `--arabic` | `auto` | How Arabic is printed. See [Arabic in the terminal](#arabic-in-the-terminal). Can be set with `NABR_ARABIC`. |
| `--device` | `default` | ALSA capture device, passed to `arecord -D`. |
| `--save-responses DIR` | | Dart only. Write every server event to `DIR/1.json`, `DIR/2.json`, and so on. |
| `-h`, `--help` | | Show the options and exit. |

## Output

- **stdout:** the matched mushaf words. The current ayah is redrawn on one line as words arrive, and each new ayah starts a new line.
- **stderr:** status lines (`fetching surah…`, `session started…`, `surah finished`) and errors.

So `> words.txt` keeps only the recited text.

The word text comes from the qurani.ai Hafs word-by-word edition (`https://api.qurani.ai/gw/qh/v1/surah/{n}/ar.wordbyword.hafs`), fetched once at startup. The server sends ayah and word numbers, and the client looks up their text there. The speech-to-text transcript is never printed.

### Exit status

| Code | Meaning |
| --- | --- |
| `0` | The audio ended or the surah was finished. |
| `1` | The connection failed, the server sent an error, or it refused the session (for example `VERSE_NOT_FOUND`). |
| `2` | Bad command-line options. |
| `130` | Stopped with Ctrl+C. |

### Arabic in the terminal

Some terminals shape and order Arabic themselves; others print the letters unjoined and left to right.

| Mode | When to use |
| --- | --- |
| `logical` | GNOME Terminal, Kitty, Konsole, WezTerm, Ghostty: terminals that shape Arabic. |
| `visual` | Terminals that do not, such as the VS Code and Cursor terminals. The client joins the letters and reverses the line itself. |
| `auto` | Picks `logical` when it detects one of the terminals above, otherwise `visual`. |

If a line looks reversed or the letters do not join, try the other mode.

## Protocol

To write your own client, follow the full API documentation at [Qurani.ai](https://qurani.ai/docs/2-advanced-tools/qrc).