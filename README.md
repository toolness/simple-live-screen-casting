This is a really simple attempt by [Atul Varma] to make it easy for [Matt Thompson] and other Mozilla Drumbeat folks to share their screens during [Weekly Drumbeat Meetings].

It should be possible for participants to view the screen-cast without any additional software aside from a modern Web browser, though the screen-caster needs to install native client software.

# The Story So Far

I've already attempted to make the client system stream an Ogg Theora file to an Icecast server, but this doesn't work very well because Ogg Theora apparently wasn't made for streaming. A lot of the time, streaming either wouldn't work at all, or it would be lagging a lot. Also, Firefox is apparently the only major browser that supports Theora streaming; Google Chrome supports static Theora files, but not streamed Theora.

More recently, I tried chunking the video stream into bite-sized 2-second Theora clips and streaming those through a custom node.js server, then stitching them together on the browser-side with JS. This seems to work decently.

I also tried piping raw I420 frames to `vpxenc`, the [VP8 Encoder] built as part of the [VP8 SDK], to generate WebM output. This worked, but I could only output WebM movie files directly; I couldn't stream WebM content to a server because `vpxenc` uses `fseek()` to fix-up blocks it's previously written. We might be able to hack `vpxenc` to not do that, if the fixing-up it's doing is non-essential.

Other things to try:

* Pushing JPEG snapshots instead of Theora.
* Creating a VNC/[RFB] client using HTML5.

Once the basics are working, further improvements might include:

* Making it possible to only stream a certain part of the user's screen.
* Annotating the picture/video stream with other metadata, such as keys pressed, position of the mouse cursor, etc. This could allow the client-side to display this metadata however the viewer wants, rather than hard-coding it into the movie itself as [ScreenFlow] and other apps do.
* Allowing viewers to annotate the movie live, pointing at parts of the picture and asking questions or making comments about them.

# TODOs

* Refactor concurrency model to use operation queues (`NSOperationQueue`, `NSOperation`, etc); see Apple's [Concurrency Programming Guide] for more on this.
* Rebuild `libogg` and `libtheora` to be 64-bit on OS X instead of 32-bit. Right now they're 32-bit because they were taken from the Mozilla Labs [Rainbow] project, which uses 32-bit libraries because `libvidcap` only works on 32-bit architectures.
* Add controls to allow user to specify options at run-time that are currently hard-coded at build time. For instance, the URL of the server to connect to, the movie's bitrate, etc.
* Figure out how efficiently the video content is being streamed from the broadcaster to the server, and potentially improve it. Right now we're creating separate `NSURLConnection` objects for every page of the Ogg stream, which I did solely for the sake of expediency (I just wanted to get the full solution working end-to-end, even if it was slow). I'm not sure if separate `NSURLConnection` objects actually pool connections and use HTTP keep-alive; if they don't, then this mechanism is probably pathetically inefficient.
* Add support for the streaming server to serve many different channels of video, rather than just one.

[Rainbow]: https://github.com/mozilla/rainbow
[ScreenFlow]: http://www.telestream.net/screen-flow/overview.htm
[VP8 Encoder]: http://www.webmproject.org/tools/encoder-parameters/
[VP8 SDK]: http://www.webmproject.org/tools/vp8-sdk/
[RFB]: http://en.wikipedia.org/wiki/RFB_protocol
[Atul Varma]: http://www.toolness.com/
[Matt Thompson]: http://twitter.com/#!/openmatt
[Weekly Drumbeat Meetings]: https://wiki.mozilla.org/Drumbeat/WeeklyUpdates
[Concurrency Programming Guide]: http://developer.apple.com/library/mac/#documentation/General/Conceptual/ConcurrencyProgrammingGuide/Introduction/Introduction.html
