# Python client

`mic_tilawa_client.py` is a single, self-contained script. Its dependencies are declared at the top of the file ([PEP 723](https://peps.python.org/pep-0723/)), so [uv](https://docs.astral.sh/uv/) installs them on first run. You can also copy the file anywhere and run it on its own.

The options, output and exit codes are documented in the [main README](../README.md#options).

## Install

1. Install the system packages (Debian or Ubuntu; see the [main README](../README.md#system-packages) for other distributions):

   ```sh
   sudo apt install alsa-utils ffmpeg libopus0
   ```

2. Install uv:

   ```sh
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```

That's all. Python 3.11 or newer is needed; uv downloads one if your system doesn't have it.

### Without uv

Use a virtual environment and pip:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install arabic-reshaper msgspec opuslib pydub python-bidi requests websockets
pip install audioop-lts   # Python 3.13 and newer only
python mic_tilawa_client.py --help
```

## Run

From this folder:

```sh
export NABR_API_KEY="your-api-key"

uv run mic_tilawa_client.py --surah 1
```

Without the environment variable, pass `--api-key` instead. The client connects to `wss://api.qurani.ai` unless you pass `--url` or set `NABR_WS_URL`.

If you run it from inside another uv project (a folder with a `pyproject.toml`), add `--no-project` so uv uses only the script's own dependencies:

```sh
uv run --no-project path/to/mic_tilawa_client.py --surah 1
```

## Examples

Microphone with Opus packets:

```sh
uv run mic_tilawa_client.py --surah 1 --audio-format opus
```

The sample recitation from [`assets/`](../assets/) (Surah al-Furqan), played locally while it streams:

```sh
uv run mic_tilawa_client.py \
  --api-key "$API_KEY" \
  --surah 25 \
  --file ../assets/025_gqgDnUW8.mp3 \
  --play \
  --audio-format opus
```

Start at Ayat al-Kursi:

```sh
uv run mic_tilawa_client.py --surah 2 --verse 255
```

Raw PCM on stdin:

```sh
arecord -f S16_LE -r 16000 -c 1 -t raw -q \
  | uv run mic_tilawa_client.py --surah 1
```

Save only the recited words to a file:

```sh
uv run mic_tilawa_client.py --surah 25 --file ../assets/025_gqgDnUW8.mp3 > words.txt
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `error: --api-key or NABR_API_KEY is required` | Export `NABR_API_KEY` or pass `--api-key`. |
| `Could not find Opus library` | Install `libopus0` (Debian/Ubuntu) or `opus`. |
| `No such file or directory: 'arecord'` | Install `alsa-utils`, or use `--file` / stdin. |
| mp3 or ogg fails to decode | Install `ffmpeg`. |
| `SyntaxWarning: "is not" with a literal` at startup | Harmless warnings from `opuslib` and `pydub` on Python 3.12 and newer. |
| Arabic looks reversed or unjoined | Try `--arabic logical` or `--arabic visual`. |
| `session refused: VERSE_NOT_FOUND` or `VERSE_WORD_NOT_FOUND` | `--verse` or `--word` points to an ayah or word that does not exist in that surah. |
