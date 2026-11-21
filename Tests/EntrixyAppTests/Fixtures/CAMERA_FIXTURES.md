These tiny, synthetic, non-personal video resources are decoder regression inputs,
not app screenshots or accepted camera interoperability results. They are copied
only into EntrixyAppTests, never the Release app or widget. Both use FFmpeg's
built-in testsrc2 pattern; no external media or user artwork was used.

Reproduce with Debian FFmpeg (the system /usr/bin/ffmpeg supports libvpx):

    ffmpeg -f lavfi -i testsrc2=size=64x48:rate=5 -t 4 -c:v libvpx -b:v 30k -an camera-decoder.webm
    ffmpeg -f lavfi -i testsrc2=size=64x48:rate=5 -t 4 -c:v libx264 -pix_fmt yuv420p -g 5 -sc_threshold 0 -an -f dash -seg_duration 1 -use_template 1 -use_timeline 1 -init_seg_name 'dash-init-$RepresentationID$.m4s' -media_seg_name 'dash-seg-$RepresentationID$-$Number%05d$.m4s' camera-decoder.mpd

The tests require real decoded video output through the production authenticated
loopback bridge. Merely creating a player or receiving HTTP200 does not pass.
