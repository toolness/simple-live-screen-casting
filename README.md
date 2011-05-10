This is a really simple attempt by [Atul Varma] to make it easy for [Matt Thompson] and other Mozilla Drumbeat folks to share their screens during [Weekly Drumbeat Meetings].

It's possible for participants to view the screen-cast without any additional software aside from a modern Web browser, though the screen-caster needs to install native client software.

# The Story So Far

I've already attempted to make the client system stream an Ogg Theora file to an Icecast server, but this doesn't work very well because Ogg Theora apparently wasn't made for streaming. A lot of the time, streaming either wouldn't work at all, or it would be lagging a lot. Also, Firefox is apparently the only major browser that supports Theora streaming; Google Chrome supports static Theora files, but not streamed Theora.

More recently, I tried chunking the video stream into bite-sized 2-second Theora clips and streaming those through a custom node.js server, then stitching them together on the browser-side with JS. This seems to work decently.

# Installation

## Server

The server requires Node v0.3.6 and Socket.io v0.6.8.

Make sure Socket.io is available at the `server/socket.io` directory.

Then, run the server:

    $ cd server
    $ node server.js

Open your browser to http://127.0.0.1:8080 and you should see a page. You can direct your audience to this location, as it's where your broadcast will be displayed once you start recording.

## Client

Download [Echoance-0.1.dmg], open it, and just drag it to your Applications folder like you would with any other OS X application.

Note that this application has only been tested with OS X Snow Leopard 10.6, so your mileage may vary if you're using something else.

Once you double-click on the application, you should see a gray/black window with a text field titled **Broadcast URL** at the top. Change this so it has the URL of your broadcast server on it, without a trailing slash; if you're using the server on your own computer, for instance, this would be:

  http://127.0.0.1:8080

Now, also open this same URL in a Firefox tab.

Now click on **Start Recording**. Hopefully, the Firefox tab should start showing your desktop before too long.

You can also tweak the other settings:

* **Frames Per Second** changes how fluid the video appears. Increasing it by moving the slider to the right will increase the strain on your CPU and your network, though.

* **Image Scaling** makes the broadcast image smaller as you move it to the left. Putting the slider all the way to the right makes the broadcast image appear just as it does on your screen--but the bigger the image size, the more strain you'll put on your network and CPU.

* **Bitrate** increases the quality of each frame in the broadcast image, but puts more strain on your network. If you're broadcasting video to viewers with slower internet connections, you'll want to set this relatively low.

* Enabling **Crop** will open a new window that allows you to define a part of your screen to broadcast. Just resize the window labeled "Crop Area" so that its translucent center covers the area you want to broadcast. This is particularly useful if you want to show people only a part of your screen at (or near) its true size, without wasting CPU and network resources on transmitting parts of the screen that others don't need to see.

Once you've clicked Start Recording, you'll see three meters. You generally want all of those to stay as close to empty as possible. In particular, the more CPU or Network strain you have, the more likely it is that your viewers will be seeing a more "laggy" version of what's on your screen.

# Other Notes, Dreams, etc.

I also tried piping raw I420 frames to `vpxenc`, the [VP8 Encoder] built as part of the [VP8 SDK], to generate WebM output. This worked, but I could only output WebM movie files directly; I couldn't stream WebM content to a server because `vpxenc` uses `fseek()` to fix-up blocks it's previously written. We might be able to hack `vpxenc` to not do that, if the fixing-up it's doing is non-essential.

Other things to try:

* Pushing JPEG snapshots instead of Theora.
* Creating a VNC/[RFB] client using HTML5.

Further improvements might include:

* Annotating the picture/video stream with other metadata, such as keys pressed, position of the mouse cursor, etc. This could allow the client-side to display this metadata however the viewer wants, rather than hard-coding it into the movie itself as [ScreenFlow] and other apps do.
* Allowing viewers to annotate the movie live, pointing at parts of the picture and asking questions or making comments about them.
* Add some basic recording and content editing functionality to the server-side. This would decouple teacher from movie-maker, allowing someone to teach others how to do something, while another person can take the raw footage and turn it into a more polished screencast.
* Porting the app to other platforms like Windows and Linux.

# TODOs

* Refactor concurrency model to use operation queues (`NSOperationQueue`, `NSOperation`, etc); see Apple's [Concurrency Programming Guide] for more on this.
* Figure out how efficiently the video content is being streamed from the broadcaster to the server, and potentially improve it. The separate `NSURLConnection` objects we create are actually pooled using HTTP keep-alive by the underlying OS, but the size of HTTP headers compared to payload data might still make them really inefficient.
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
[Echoance-0.1.dmg]: http://toolness.github.com/simple-live-screen-casting/Echoance-0.1.dmg
