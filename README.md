This is a really simple attempt by [Atul Varma] to make it easy for [Matt Thompson] and other Mozilla Drumbeat folks to share their screens during [Weekly Drumbeat Meetings].

It should be possible for participants to view the screen-cast without any additional software aside from a modern Web browser, though the screen-caster needs to install native client software.

# The Story So Far

I've already attempted to make the client system stream an Ogg Theora file to an Icecast server, but this doesn't work very well because Ogg Theora apparently wasn't made for streaming. A lot of the time, streaming either wouldn't work at all, or it would be lagging a lot. Also, Firefox is apparently the only major browser that supports Theora streaming; Google Chrome supports static Theora files, but not streamed Theora.

Next steps might involve:

* Chunking the video stream into bite-sized 2-second Theora clips and streaming those, pasting them together into a decent experience on the client-side with HTML5.
* Pushing JPEG snapshots instead of Theora.
* Investigating the possibility of WebM streaming.

Once the basics are working, further improvements might include:

* Annotating the picture/video stream with other metadata, such as keys pressed, position of the mouse cursor, etc. This could allow the client-side to display this metadata however the viewer wants.
* Allowing viewers to annotate the movie live, pointing at parts of the picture and asking questions or making comments about them.

# TODOs

* Refactor concurrency model to use operation queues (`NSOperationQueue`, `NSOperation`, etc); see Apple's [Concurrency Programming Guide] for more on this.
* Once a thumbnail or movie-burst is finished, send it out to a web server using code like this:

<pre>
NSURL *postURL = [NSURL URLWithString:@"http://localhost:8000/update"];
NSURLRequest *postRequest = [NSURLRequest requestWithURL:postURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:postRequest delegate:mSelf];
NSLog(@"Created connection: %@.", connection);
</pre>

* Alternatively, I can use a synchronous request for now:

<pre>
NSURLResponse *response = NULL;
NSError *error = NULL;
[NSURLConnection sendSynchronousRequest:postRequest returningResponse:&response error:&error];
NSLog(@"Connection response: %@   error: %@", response, error);
</pre>

[Atul Varma]: http://www.toolness.com/
[Matt Thompson]: http://twitter.com/#!/openmatt
[Weekly Drumbeat Meetings]: https://wiki.mozilla.org/Drumbeat/WeeklyUpdates
[Concurrency Programming Guide]: http://developer.apple.com/library/mac/#documentation/General/Conceptual/ConcurrencyProgrammingGuide/Introduction/Introduction.html
