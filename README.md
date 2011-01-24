# TODOs

* Refactor concurrency model to use operation queues (`NSOperationQueue`, `NSOperation`, etc); see Apple's Concurrency Programming Guide for more on this.
* Once a thumbnail is finished, send it out to a web server using code like this:

    NSURL *postURL = [NSURL URLWithString:@"http://localhost:8000/update"];
    NSURLRequest *postRequest = [NSURLRequest requestWithURL:postURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:postRequest delegate:mSelf];
    NSLog(@"Created connection: %@.", connection);

