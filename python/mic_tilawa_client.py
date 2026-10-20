#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "arabic-reshaper>=3",
#   "audioop-lts>=0.2; python_version >= '3.13'",
#   "msgspec>=0.18",
#   "opuslib>=3",
#   "pydub>=0.25",
#   "python-bidi>=0.6",
#   "requests>=2",
#   "websockets>=12",
# ]
# ///
"""Stream microphone audio to the surah checker and print mushaf words.

Matched words are looked up in the qurani.ai word-by-word response and written
to stdout. The ASR transcript is not printed.

Microphone (16 kHz mono):

    uv run mic_tilawa_client.py --api-key "$NABR_API_KEY" --surah 1

Pipe raw s16le 16 kHz mono PCM on stdin:

    arecord -f S16_LE -r 16000 -c 1 -t raw -q \\
        | uv run mic_tilawa_client.py --api-key "$NABR_API_KEY" --surah 1

Audio file (wav, mp3, ogg, flac, or raw s16le):

    uv run mic_tilawa_client.py --api-key "$NABR_API_KEY" --surah 25 --file ../assets/025_gqgDnUW8.mp3

Play that file locally while streaming it:

    uv run mic_tilawa_client.py --api-key "$NABR_API_KEY" --surah 25 --file ../assets/025_gqgDnUW8.mp3 --play

Send 20 ms Opus packets instead of WAV chunks:

    uv run mic_tilawa_client.py --api-key "$NABR_API_KEY" --surah 1 --audio-format opus
"""

import argparse
import asyncio
import contextlib
import io
import os
import queue
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path
from typing import Optional
from urllib.parse import urlencode

import arabic_reshaper
import msgspec
import opuslib
import requests
import websockets
from bidi.algorithm import get_display
from pydub import AudioSegment


def _method_tag(class_name: str) -> str:
    return {
        '_ClientMessage': 'BASE_METHOD',
        'StartTilawaSession': 'START_TILAWA_SESSION',
        'CheckTilawaAudio': 'CHECK_TILAWA_AUDIO',
        'ResetTilawaSession': 'RESET_TILAWA_SESSION',
        'KeepAlive': 'KEEP_ALIVE',
    }[class_name]


class _ClientMessage(msgspec.Struct, tag_field='method', tag=_method_tag):
    pass


class StartTilawaSession(_ClientMessage):
    chapter_index: int
    verse_index: int
    word_index: int
    hafz_level: int
    tajweed_level: int


class CheckTilawaAudio(_ClientMessage):
    audio: bytes
    client_sent_at_ms: Optional[int] = None


class ResetTilawaSession(_ClientMessage):
    pass


class KeepAlive(_ClientMessage):
    sent_at: int


SURAH_URL = 'https://api.qurani.ai/gw/qh/v1/surah/{surah}/ar.wordbyword.hafs'
AYAHS_PER_PAGE = 50
SAMPLE_RATE = 16_000
SAMPLE_WIDTH = 2
CHUNK_MS = 200
CHUNK_BYTES = SAMPLE_RATE * SAMPLE_WIDTH * CHUNK_MS // 1000
# Server Opus decoder expects one 20 ms packet per message.
OPUS_FRAME_SAMPLES = SAMPLE_RATE * 20 // 1000
OPUS_FRAME_BYTES = OPUS_FRAME_SAMPLES * SAMPLE_WIDTH

_SUCCESS = 6
_SURAH_FINISHED = 8
_EXIT_NAMES = {
    0: 'CHAPTER_NOT_SUPPORTED',
    1: 'VERSE_NOT_FOUND',
    2: 'VERSE_WORD_NOT_FOUND',
    3: 'HAFZ_LEVEL_NOT_SUPPORTED',
    4: 'TAJWEED_LEVEL_NOT_SUPPORTED',
    5: 'UNEXPECTED_PROBLEM',
    6: 'SUCCESS',
    7: 'CHECK_FAILED',
    8: 'SURAH_FINISHED',
}

# Presentation forms so letters connect, then visual order for a terminal that
# does not shape or reorder Arabic. Harakat are shifted because get_display
# reverses the string. Terminals that already do both (GNOME Terminal, Kitty,
# Konsole) must receive the original logical text or they reverse it again.
_arabic_reshaper = arabic_reshaper.ArabicReshaper(
    configuration={
        'delete_harakat': False,
        'shift_harakat_position': True,
    }
)


def _use_visual_arabic(mode: str) -> bool:
    """True when this terminal needs pre-shaped, visually ordered Arabic."""
    if mode == 'auto':
        mode = os.environ.get('NABR_ARABIC', 'auto').lower()
    if mode == 'visual':
        return True
    if mode == 'logical':
        return False
    shapes_arabic = any(
        os.environ.get(name)
        for name in (
            'VTE_VERSION',
            'KITTY_WINDOW_ID',
            'WEZTERM_PANE',
            'KONSOLE_VERSION',
            'GHOSTTY_RESOURCES_DIR',
        )
    )
    return not shapes_arabic


def fetch_word_by_word_surah(surah_number: int) -> list[dict]:
    """Load every ayah of a surah, with per-word Hafs text."""
    url = SURAH_URL.format(surah=surah_number)
    ayahs: list[dict] = []
    while True:
        params = {
            'words': 'true',
            'limit': AYAHS_PER_PAGE,
            'offset': len(ayahs),
        }
        response = requests.get(url, params=params, timeout=30)
        if response.status_code != 200:
            raise RuntimeError(
                f'qurani.ai API error {response.status_code}: {response.text[:200]}'
            )
        page = response.json()['data']['ayahs']
        ayahs.extend(page)
        if len(page) < AYAHS_PER_PAGE:
            return ayahs


class MushafWords:
    """1-based (verse, word) -> Hafs text, skipping verse-end markers."""

    def __init__(self, ayahs: list[dict]):
        self._text: dict[tuple[int, int], str] = {}
        for ayah in ayahs:
            verse_number = int(ayah['numberInSurah'])
            word_index = 0
            for word in ayah['words']:
                if word.get('char_type_name') != 'word':
                    continue
                word_index += 1
                self._text[(verse_number, word_index)] = word.get('text') or ''

    def text(self, verse: int, word: int) -> Optional[str]:
        return self._text.get((verse, word))


class WordEcho:
    """Print each newly matched mushaf word once, in verse order.

    The current verse is redrawn as words arrive. Terminals that do not shape
    Arabic get connected glyphs in visual order. Terminals that already do
    get the original logical text.
    """

    def __init__(self, mushaf: MushafWords, out=None, visual: bool = True):
        self._mushaf = mushaf
        self._out = out or sys.stdout
        self._visual = visual
        self._seen: set[tuple[int, int]] = set()
        self._current_verse: list[str] = []
        self._last_verse: Optional[int] = None

    def echo(self, correct_words: list) -> None:
        fresh = []
        for word in correct_words:
            key = (int(word['verse']), int(word['word']))
            if key in self._seen:
                continue
            text = self._mushaf.text(*key)
            if not text:
                print(
                    f'no mushaf text for verse {key[0]} word {key[1]}',
                    file=sys.stderr,
                )
                self._seen.add(key)
                continue
            self._seen.add(key)
            fresh.append((key, text))
        fresh.sort()
        for (verse, _word), text in fresh:
            if self._last_verse is not None and verse != self._last_verse:
                self._out.write('\n')
                self._current_verse = []
            self._current_verse.append(text)
            self._last_verse = verse
            self._redraw_current_line()

    def _redraw_current_line(self) -> None:
        logical = ' '.join(self._current_verse)
        if self._visual:
            logical = get_display(_arabic_reshaper.reshape(logical))
        self._out.write('\r\033[K' + logical)
        self._out.flush()

    def finish(self) -> None:
        if self._last_verse is not None:
            self._out.write('\n')
            self._out.flush()


def pcm_s16le_to_wav(pcm: bytes, sample_rate: int = SAMPLE_RATE) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(SAMPLE_WIDTH)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return buf.getvalue()


def load_audio_pcm(path: Path) -> bytes:
    """Decode an audio file to 16 kHz mono s16le PCM."""
    if path.suffix.lower() in {'.pcm', '.raw'}:
        return path.read_bytes()
    segment = AudioSegment.from_file(path)
    segment = (
        segment.set_frame_rate(SAMPLE_RATE)
        .set_channels(1)
        .set_sample_width(SAMPLE_WIDTH)
    )
    return segment.raw_data


def _play(player: Optional[subprocess.Popen], data: bytes) -> None:
    if player is None or player.stdin is None:
        return
    try:
        player.stdin.write(data)
        player.stdin.flush()
    except (BrokenPipeError, OSError):
        pass


def _read_pcm(
    stream,
    out: queue.Queue,
    stop: threading.Event,
    player: Optional[subprocess.Popen] = None,
) -> None:
    try:
        while not stop.is_set():
            data = stream.read(CHUNK_BYTES)
            if not data:
                break
            out.put(data)
            _play(player, data)
    finally:
        out.put(None)


def _feed_pcm(
    pcm: bytes,
    out: queue.Queue,
    stop: threading.Event,
    player: Optional[subprocess.Popen] = None,
) -> None:
    """Push file PCM in realtime-sized chunks so the server does not drop audio."""
    try:
        offset = 0
        chunk_s = CHUNK_MS / 1000
        while offset < len(pcm) and not stop.is_set():
            chunk = pcm[offset : offset + CHUNK_BYTES]
            out.put(chunk)
            _play(player, chunk)
            offset += CHUNK_BYTES
            time.sleep(chunk_s)
    finally:
        out.put(None)


def open_playback() -> subprocess.Popen:
    """Play 16 kHz mono s16le PCM on the default ALSA device."""
    return subprocess.Popen(
        [
            'aplay',
            '-f',
            'S16_LE',
            '-r',
            str(SAMPLE_RATE),
            '-c',
            '1',
            '-t',
            'raw',
            '-q',
        ],
        stdin=subprocess.PIPE,
    )


def open_microphone(device: str) -> tuple[object, subprocess.Popen]:
    proc = subprocess.Popen(
        [
            'arecord',
            '-D',
            device,
            '-f',
            'S16_LE',
            '-r',
            str(SAMPLE_RATE),
            '-c',
            '1',
            '-t',
            'raw',
            '-q',
        ],
        stdout=subprocess.PIPE,
    )
    if proc.stdout is None:
        raise RuntimeError('arecord did not provide a stdout pipe')
    return proc.stdout, proc


def _ws_url(base: str, api_key: str, lang: str, audio_format: str) -> str:
    query = urlencode(
        {
            'api_key': api_key,
            'lang': lang,
            'audio_format': audio_format,
        }
    )
    separator = '&' if '?' in base else '?'
    return f'{base}{separator}{query}'


async def _send(ws, payload, lock: asyncio.Lock) -> None:
    async with lock:
        await ws.send(msgspec.msgpack.encode(payload))


async def _recv_loop(ws, echo: WordEcho, state: dict) -> None:
    async for message in ws:
        if not isinstance(message, (bytes, bytearray)):
            continue
        event = msgspec.msgpack.decode(message)
        name = event.get('event')
        if name == 'QRC_CLIENT_CONNECTED':
            state['connected'].set()
        elif name == 'TILAWA_SESSION_STARTED':
            state['start_exit'] = int(event['exit_code'])
            state['started'].set()
        elif name == 'TILAWA_RESULT':
            echo.echo(event.get('correct_words') or [])
            if int(event.get('exit_code', -1)) == _SURAH_FINISHED:
                state['finished'].set()
        elif name == 'QRC_ERROR':
            state['error'] = event.get('message') or 'unknown error'
            print(f'error: {state["error"]}', file=sys.stderr)
            state['failed'].set()
        elif name == 'TILAWA_SESSION_ENDED':
            state['ended'].set()


async def _keepalive(ws, lock: asyncio.Lock, stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            await asyncio.wait_for(stop.wait(), timeout=5)
            return
        except asyncio.TimeoutError:
            await _send(ws, KeepAlive(sent_at=int(time.time() * 1000)), lock)


def _audio_payload(pcm: bytes, audio_format: str, encoder) -> bytes:
    if audio_format == 'opus':
        return encoder.encode(pcm, OPUS_FRAME_SAMPLES)
    return pcm_s16le_to_wav(pcm)


async def _stream_audio(
    ws,
    pcm_queue: queue.Queue,
    lock: asyncio.Lock,
    stop: asyncio.Event,
    audio_format: str,
    encoder,
) -> None:
    frame_bytes = OPUS_FRAME_BYTES if audio_format == 'opus' else CHUNK_BYTES
    pending = bytearray()
    while not stop.is_set():
        try:
            piece = await asyncio.to_thread(pcm_queue.get, True, 0.2)
        except queue.Empty:
            continue
        if piece is None:
            break
        pending.extend(piece)
        while len(pending) >= frame_bytes and not stop.is_set():
            pcm = bytes(pending[:frame_bytes])
            del pending[:frame_bytes]
            await _send(
                ws,
                CheckTilawaAudio(
                    audio=_audio_payload(pcm, audio_format, encoder),
                    client_sent_at_ms=int(time.time() * 1000),
                ),
                lock,
            )
    if pending and not stop.is_set():
        pcm = bytes(pending)
        if audio_format == 'opus':
            pcm = pcm.ljust(OPUS_FRAME_BYTES, b'\x00')
        await _send(
            ws,
            CheckTilawaAudio(
                audio=_audio_payload(pcm, audio_format, encoder),
                client_sent_at_ms=int(time.time() * 1000),
            ),
            lock,
        )


async def run(args: argparse.Namespace) -> int:
    print(f'fetching surah {args.surah} word by word...', file=sys.stderr)
    mushaf = MushafWords(fetch_word_by_word_surah(args.surah))
    echo = WordEcho(mushaf, visual=_use_visual_arabic(args.arabic))
    use_stdin = args.input == 'stdin' or (
        args.input == 'auto' and not sys.stdin.isatty()
    )
    proc = None
    player = None
    pcm_queue: queue.Queue = queue.Queue(maxsize=50)
    stop_read = threading.Event()
    if args.file is not None:
        pcm = load_audio_pcm(args.file)
        seconds = len(pcm) / (SAMPLE_RATE * SAMPLE_WIDTH)
        print(f'reading {args.file} ({seconds:.1f}s)', file=sys.stderr)
        if args.play:
            player = open_playback()
        reader = threading.Thread(
            target=_feed_pcm,
            args=(pcm, pcm_queue, stop_read, player),
            daemon=True,
        )
    elif use_stdin:
        print('reading 16 kHz s16le mono PCM from stdin', file=sys.stderr)
        if args.play:
            player = open_playback()
        reader = threading.Thread(
            target=_read_pcm,
            args=(sys.stdin.buffer, pcm_queue, stop_read, player),
            daemon=True,
        )
    else:
        stream, proc = open_microphone(args.device)
        print(f'capturing microphone via arecord ({args.device})', file=sys.stderr)
        if args.play:
            player = open_playback()
        reader = threading.Thread(
            target=_read_pcm,
            args=(stream, pcm_queue, stop_read, player),
            daemon=True,
        )
    if player is not None:
        print('playing audio locally', file=sys.stderr)
    if not args.play:
        reader.start()

    state = {
        'connected': asyncio.Event(),
        'started': asyncio.Event(),
        'finished': asyncio.Event(),
        'failed': asyncio.Event(),
        'ended': asyncio.Event(),
        'start_exit': None,
        'error': None,
    }
    stop = asyncio.Event()
    lock = asyncio.Lock()
    url = _ws_url(args.url, args.api_key, args.lang, args.audio_format)
    encoder = None
    if args.audio_format == 'opus':
        encoder = opuslib.Encoder(SAMPLE_RATE, 1, opuslib.APPLICATION_AUDIO)
    print(f'connecting to {url}', file=sys.stderr)
    try:
        async with websockets.connect(url, max_size=26 * 1024 * 1024) as ws:
            recv = asyncio.create_task(_recv_loop(ws, echo, state))
            ping = asyncio.create_task(_keepalive(ws, lock, stop))
            try:
                await asyncio.wait_for(state['connected'].wait(), timeout=10)
                await _send(
                    ws,
                    StartTilawaSession(
                        chapter_index=args.surah,
                        verse_index=args.verse,
                        word_index=args.word,
                        hafz_level=args.hafz_level,
                        tajweed_level=args.tajweed_level,
                    ),
                    lock,
                )
                await asyncio.wait_for(state['started'].wait(), timeout=10)
                exit_code = state['start_exit']
                if exit_code != _SUCCESS:
                    name = _EXIT_NAMES.get(exit_code, str(exit_code))
                    print(f'session refused: {name}', file=sys.stderr)
                    return 1
                print(
                    'session started; matched mushaf words appear after a few seconds of speech',
                    file=sys.stderr,
                )
                if args.play and not reader.is_alive():
                    reader.start()
                stream_task = asyncio.create_task(
                    _stream_audio(ws, pcm_queue, lock, stop, args.audio_format, encoder)
                )
                finished_task = asyncio.create_task(state['finished'].wait())
                failed_task = asyncio.create_task(state['failed'].wait())
                source_ended = False
                try:
                    done, _pending = await asyncio.wait(
                        {stream_task, finished_task, failed_task},
                        return_when=asyncio.FIRST_COMPLETED,
                    )
                    source_ended = (
                        stream_task in done
                        and not state['finished'].is_set()
                        and not state['failed'].is_set()
                    )
                finally:
                    stop.set()
                    for task in (stream_task, finished_task, failed_task):
                        task.cancel()
                    for task in (stream_task, finished_task, failed_task):
                        with contextlib.suppress(asyncio.CancelledError):
                            await task
                if state['failed'].is_set():
                    return 1
                if source_ended:
                    with contextlib.suppress(asyncio.TimeoutError):
                        await asyncio.wait_for(state['finished'].wait(), timeout=5)
                await _send(ws, ResetTilawaSession(), lock)
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(state['ended'].wait(), timeout=5)
            finally:
                stop.set()
                ping.cancel()
                recv.cancel()
                for task in (ping, recv):
                    with contextlib.suppress(asyncio.CancelledError):
                        await task
    finally:
        stop_read.set()
        echo.finish()
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        if player is not None:
            if player.stdin is not None:
                with contextlib.suppress(OSError):
                    player.stdin.close()
            try:
                player.wait(timeout=2)
            except subprocess.TimeoutExpired:
                player.terminate()
                player.wait(timeout=1)
    if state['finished'].is_set():
        print('surah finished', file=sys.stderr)
    return 0


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            'Stream microphone PCM to the surah checker and echo mushaf words '
            'from the qurani.ai word-by-word API.'
        )
    )
    parser.add_argument(
        '--url',
        default=os.environ.get('NABR_WS_URL', 'wss://api.qurani.ai'),
        help='WebSocket endpoint, or set NABR_WS_URL (default: wss://api.qurani.ai)',
    )
    parser.add_argument(
        '--api-key',
        default=os.environ.get('NABR_API_KEY'),
        help='API key, or set NABR_API_KEY',
    )
    parser.add_argument('--lang', default='ar')
    parser.add_argument('--surah', type=int, default=1)
    parser.add_argument('--verse', type=int, default=1)
    parser.add_argument('--word', type=int, default=1)
    parser.add_argument('--hafz-level', type=int, default=1)
    parser.add_argument('--tajweed-level', type=int, default=1)
    parser.add_argument(
        '--file',
        type=Path,
        help=(
            'Audio file to stream instead of the microphone '
            '(wav, mp3, ogg, flac, or raw s16le 16 kHz mono .pcm/.raw)'
        ),
    )
    parser.add_argument(
        '--input',
        choices=('auto', 'mic', 'stdin'),
        default='auto',
        help='auto reads stdin when it is a pipe, otherwise the microphone',
    )
    parser.add_argument(
        '--audio-format',
        choices=('wav', 'opus'),
        default='wav',
        help='Format sent to the server (opus is 20 ms packets, smaller than wav)',
    )
    parser.add_argument(
        '--play',
        action='store_true',
        help='Play the audio locally with aplay while streaming it',
    )
    parser.add_argument(
        '--arabic',
        choices=('auto', 'logical', 'visual'),
        default='auto',
        help=(
            'How to print Arabic. auto uses logical text in GNOME Terminal, '
            'Kitty, Konsole, WezTerm, and Ghostty, and visual order elsewhere '
            '(including the Cursor terminal). Override with NABR_ARABIC.'
        ),
    )
    parser.add_argument(
        '--device',
        default='default',
        help='ALSA device passed to arecord -D (default: default)',
    )
    args = parser.parse_args(argv)
    if not args.api_key:
        parser.error('--api-key or NABR_API_KEY is required')
    if not 1 <= args.surah <= 114:
        parser.error('--surah must be between 1 and 114')
    if args.file is not None:
        if args.input != 'auto':
            parser.error('--file cannot be combined with --input')
        if not args.file.is_file():
            parser.error(f'file not found: {args.file}')
    return args


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        print(file=sys.stderr)
        return 130
    except (
        RuntimeError,
        requests.RequestException,
        OSError,
        websockets.exceptions.WebSocketException,
    ) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
