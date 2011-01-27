This is a really simple attempt by [Atul Varma] to make it easy for [Matt Thompson] and other Mozilla Drumbeat folks to share their screens during [Weekly Drumbeat Meetings].

It should be possible for participants to view the screen-cast without any additional software aside from a modern Web browser, though the screen-caster needs to install native client software.

# The Story So Far

I've already attempted to make the client system stream an Ogg Theora file to an Icecast server, but this doesn't work very well because Ogg Theora apparently wasn't made for streaming. A lot of the time, streaming either wouldn't work at all, or it would be lagging a lot. Also, Firefox is apparently the only major browser that supports Theora streaming; Google Chrome supports static Theora files, but not streamed Theora.

More recently, I tried chunking the video stream into bite-sized 2-second Theora clips and streaming those, stitching them together on the client-side with JS. This seems to work decently.

Other things to try:

* Pushing JPEG snapshots instead of Theora.
* Investigating the possibility of WebM streaming.
* Creating a VNC/[RFB] client using HTML5.

Once the basics are working, further improvements might include:

* Making it possible to only stream a certain part of the user's screen.
* Annotating the picture/video stream with other metadata, such as keys pressed, position of the mouse cursor, etc. This could allow the client-side to display this metadata however the viewer wants.
* Allowing viewers to annotate the movie live, pointing at parts of the picture and asking questions or making comments about them.

# TODOs

* Refactor concurrency model to use operation queues (`NSOperationQueue`, `NSOperation`, etc); see Apple's [Concurrency Programming Guide] for more on this.

[RFB]: http://en.wikipedia.org/wiki/RFB_protocol
[Atul Varma]: http://www.toolness.com/
[Matt Thompson]: http://twitter.com/#!/openmatt
[Weekly Drumbeat Meetings]: https://wiki.mozilla.org/Drumbeat/WeeklyUpdates
[Concurrency Programming Guide]: http://developer.apple.com/library/mac/#documentation/General/Conceptual/ConcurrencyProgrammingGuide/Introduction/Introduction.html
