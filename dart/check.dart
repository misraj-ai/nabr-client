// Self-check: dart run check.dart
// Reference values come from Python wave and arabic_reshaper + get_display.

import 'mic_tilawa_client.dart';

const _wav = '524946462800000057415645666d74201000000001000100803e0000007d0000'
    '02001000646174610400000001020304';

List<int> _hex(String s) => [
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ];

void _check(bool ok, String what) {
  if (!ok) throw StateError('check failed: $what');
}

void main() {
  _check(
    pcmS16leToWav([1, 2, 3, 4]).toString() == _hex(_wav).toString(),
    'wav header',
  );
  _check(
    toVisualArabic('ذَٰلِكَ '
            'ٱلْكِتَـٰبُ '
            'لَا '
            'رَيْبَ '
            'عَلَىٰ') ==
        'ﻰٰﻠَﻋَ '
            'ﺐَﻳْﺭَ '
            'ﻻَ '
            'ﺐُـٰﺘَﻜِﻟْﭐ '
            'ﻚَﻟِﺫَٰ',
    'arabic visual (python arabic_reshaper + get_display)',
  );
  final packet = OpusEncoder().encode(List.filled(opusFrameBytes, 0));
  _check(packet.isNotEmpty, 'opus encode');
  print('ok');
}
