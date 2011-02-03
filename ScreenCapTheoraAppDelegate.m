//
//  ScreenCapTheoraAppDelegate.m
//  ScreenCapTheora
//
//  Created by Atul Varma on 1/22/11.
//  Copyright 2011 Mozilla. All rights reserved.
//

// Much of the Theora-related code in this file was originally taken
// from the Mozilla Rainbow project: https://github.com/mozilla/rainbow

#include <sys/stat.h>
#include <ogg/ogg.h>
#include <theora/theoraenc.h>
#include "Convert.h"

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import "ScreenCapTheoraAppDelegate.h"
#import "QueueController.h"
#import "FrameReader.h"

// Whether to write the user's screen to a WebM file.
#define kEnableWebM 0

// Whether to write the user's screen to a Theora file.
#define kEnableTheoraFile 0

// Whether to write the user's screen to a Theora stream that's sent to a node.js server for streaming to other browsers.
#define kEnableTheoraStreaming 1

// Whether any kind of Theora output is enabled at all.
#define kEnableTheora (kEnableTheoraFile || kEnableTheoraStreaming)

// Whether to write snapshots of the user's screen to JPEG files.
#define kEnableJPEG 0

// The number of screen readers in existence at one time.
#define kNumReaderObjects 20

// Amount to scale the user's screen.
#define kImageScaling 0.33

// Bitrate of the Theora stream.
#define kTheoraBitrate 128000

// How often to create keyframes in the Theora stream. For more information, see:
// http://www.theora.org/doc/libtheora-1.0/structth__info.html#693ca4ab11fbc0c3f32594b4bb8766ed
#define kTheoraKeyframeGranuleShift 6

// Number of seconds each movie lasts. When this period is over, a new movie is created. Set to -1 if you only want one movie that is arbitrarily long.
#define kSecondsPerMovie 2

typedef struct {
	// File descriptor to use for writing to a Theora file, if kEnableTheoraFile is set.
	int fd;
	// Keeps track of the number of frames we've written to the current movie.
	int framesWritten;
	// An application-lifetime unique ID for the current movie being recorded
	int movieID;
	
	// These are Theora and Ogg-specific data structures.
	th_info ti;
	th_enc_ctx *th;
	th_comment tc;
	ogg_packet op;
	ogg_stream_state os;
	ogg_page og;
} TheoraState;

typedef struct {
	// The vpxenc (VP8 encoder) process.
	NSTask *encoder;
	
	// Pipe to send a raw I420 stream of frames to vpxenc.
	NSPipe *pipe;
} WebMState;

// Whether or not we're currently recording.
static BOOL mIsRecording = NO;

// A dispatch queue for sending Ogg stream pages to the node.js server.
static dispatch_queue_t mRequestQueue;

static WebMState mWebM;
static TheoraState mTheora;
static NSOpenGLContext *mGLContext;
static NSOpenGLPixelFormat *mGLPixelFormat;
static CVDisplayLinkRef mDisplayLink;
static QueueController *mFrameQueueController;

// Current frames per second of each movie.
static int mFPS;

// The actual size of the user's screen.
static CGRect mDisplayRect;

// Singleton instance of our app delegate.
static ScreenCapTheoraAppDelegate *mSelf;

// These variables are used to keep track of the frame rate.
static NSTimeInterval mLastTime;
static NSTimeInterval mFPSInterval;

// The width of each movie frame's picture, after scaling factors are applied.
static unsigned int mScaledWidth;

// The height of each movie frame's picture, after scaling factors are applied.
static unsigned int mScaledHeight;

// The width of each movie frame, including padding to make it a multiple of 16.
static unsigned int mFrameWidth;

// The height of each movie frame, including padding to make it a multiple of 16.
static unsigned int mFrameHeight;

// The number of frames left to be encoded.
volatile static int mFramesLeft = 0;

// Whether or not any auxiliary threads spawned by the main thread should stop at their earliest possible convenience.
BOOL mShouldStop;

static void writeTheoraPage(NSString *kind) {
	if (kEnableTheoraFile) {
		write(mTheora.fd, mTheora.og.header, mTheora.og.header_len);
		write(mTheora.fd, mTheora.og.body, mTheora.og.body_len);
		fsync(mTheora.fd);
	}

	if (kEnableTheoraStreaming) {
		size_t totalSize = mTheora.og.header_len + mTheora.og.body_len;
		char *buf = malloc(totalSize);
		memcpy(buf, mTheora.og.header, mTheora.og.header_len);
		memcpy(buf+mTheora.og.header_len, mTheora.og.body, mTheora.og.body_len);

		NSString *baseURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"BroadcastURL"];
		[baseURL retain];

		int currentMovieID = mTheora.movieID;
		[kind retain];
		
		dispatch_async(mRequestQueue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			NSData *bufData = [NSData dataWithBytes:buf length:totalSize];
			free(buf);
			NSURL *postURL = [NSURL URLWithString:[baseURL stringByAppendingString:@"/update"]];
			NSMutableURLRequest *postRequest = [NSMutableURLRequest requestWithURL:postURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.0];
			[postRequest setHTTPMethod:@"POST"];
			[postRequest setHTTPBody:bufData];
			[postRequest addValue:kind forHTTPHeaderField:@"x-theora-kind"];
			[postRequest addValue:[NSString stringWithFormat:@"%d", kSecondsPerMovie] forHTTPHeaderField:@"x-content-duration"];
			[postRequest addValue:[NSString stringWithFormat:@"%d", currentMovieID] forHTTPHeaderField:@"x-theora-id"];
			NSURLResponse *response = NULL;
			NSError *error = NULL;
			// TODO: Not sure whether NSURLConnection objects are pooled/pipelined/etc by OS X, but if they're not, initiating a new socket connection for each Ogg page isn't very efficient.
			[NSURLConnection sendSynchronousRequest:postRequest returningResponse:&response error:&error];
			NSLog(@"Connection response: %@   error: %@", response, error);
			[baseURL release];
			[kind release];
			[pool release];
		});
	}

	NSLog(@"Wrote theora %@ page of size %d bytes.", kind, mTheora.og.header_len + mTheora.og.body_len);
}

static void closeTheoraFile()
{
	th_encode_free(mTheora.th);
	
	if (ogg_stream_flush(&mTheora.os, &mTheora.og))
		writeTheoraPage(@"end");
	ogg_stream_clear(&mTheora.os);
	
	if (kEnableTheoraFile)
		close(mTheora.fd);
	
	mTheora.th = NULL;	
}

static void createTheoraFile()
{
	if (ogg_stream_init(&mTheora.os, rand()))
		NSLog(@"ogg_stream_init() failed.");
	th_info_init(&mTheora.ti);

	/* Must be multiples of 16 */
	mTheora.ti.frame_width = mFrameWidth;
	mTheora.ti.frame_height = mFrameHeight;
	mTheora.ti.pic_width = mScaledWidth;
	mTheora.ti.pic_height = mScaledHeight;
	mTheora.ti.pic_x = 0;
	mTheora.ti.pic_y = 0;
	mTheora.ti.fps_numerator = mFPS;
	mTheora.ti.fps_denominator = 1;
	
	NSLog(@"Frame size is %dx%d, picture size is %dx%d.", mTheora.ti.frame_width, mTheora.ti.frame_height, mTheora.ti.pic_width, mTheora.ti.pic_height);
	
	/* Are these the right values? */
	mTheora.ti.target_bitrate = kTheoraBitrate;
	mTheora.ti.colorspace = TH_CS_ITU_REC_470M;
	mTheora.ti.pixel_fmt = TH_PF_420;
	mTheora.ti.keyframe_granule_shift = kTheoraKeyframeGranuleShift;
	
	mTheora.th = th_encode_alloc(&mTheora.ti);
	th_info_clear(&mTheora.ti);
	
	th_comment_init(&mTheora.tc);
	th_comment_add_tag(&mTheora.tc, (char *)"ENCODER", (char *)"SCT");
	if (th_encode_flushheader(mTheora.th, &mTheora.tc, &mTheora.op) <= 0)
		NSLog(@"th_encode_flushheader() failed.");
	th_comment_clear(&mTheora.tc);
	
	ogg_stream_packetin(&mTheora.os, &mTheora.op);
	if (ogg_stream_pageout(&mTheora.os, &mTheora.og) != 1)
		NSLog(@"ogg_stream_pageout() failed.");

	mTheora.movieID++;
	if (kEnableTheoraFile) {
		// TODO: Don't hardcode this filename.
		NSString *filename = [NSString stringWithFormat:@"/Users/atul/screencap-%d.ogv", mTheora.movieID];
		mTheora.fd = open([filename UTF8String], O_WRONLY | O_CREAT | O_TRUNC | O_SYNC);		
		if (mTheora.fd < 0)
			NSLog(@"open() failed.");
		
		fchmod(mTheora.fd, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
	}

	writeTheoraPage(@"start");
	
	int ret;
	
	for (;;) {
		ret = th_encode_flushheader(mTheora.th, &mTheora.tc, &mTheora.op);
		if (ret < 0) {
			NSLog(@"th_encode_flushheader() failed.");
			return;
		}
		if (ret == 0)
			break;
		ogg_stream_packetin(&mTheora.os, &mTheora.op);
	}
	for (;;) {
		ret = ogg_stream_flush(&mTheora.os, &mTheora.og);
		if (ret < 0) {
			NSLog(@"ogg_stream_flush() failed.");
			return;
		}
		if (ret == 0) {
			break;
		}
		writeTheoraPage(@"header");
	}	
}

static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink,
									const CVTimeStamp *inNow,
									const CVTimeStamp *inOutputTime,
									CVOptionFlags flagsIn,
									CVOptionFlags *flagsOut,
									void *displayLinkContext)
{
	NSTimeInterval time = [NSDate timeIntervalSinceReferenceDate];
	if (time - mLastTime < mFPSInterval)
		return kCVReturnSuccess;

	mLastTime = time;

	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	
	FrameReader *freeReader = [mFrameQueueController removeOldestItemFromFreeQ];
	[freeReader setBufferReadTime:time];
	[freeReader readScreenAsyncOnSeparateThread];

	FrameReader *filledReader = [mFrameQueueController removeOldestItemFromFilledQ];
	if (filledReader) {
		mFramesLeft++;
		[NSThread detachNewThreadSelector:@selector(processFrameSynchronized:) toTarget:mSelf withObject:filledReader];
	}

	[pool release];
	return kCVReturnSuccess;
}

@implementation ScreenCapTheoraAppDelegate

@synthesize window;

- (void)processFrameSynchronized:(id)param
{
	NSAutoreleasePool *pool = [NSAutoreleasePool new];

	@synchronized([ScreenCapTheoraAppDelegate class]) {
		if (mShouldStop) {
			mFramesLeft--;
			return;
			//[pool release];
		}

		FrameReader *reader = (FrameReader *)param;
		
		CVPixelBufferRef pixelBuffer = [reader readScreenAsyncFinish];
		if (CVPixelBufferIsPlanar(pixelBuffer))
			NSLog(@"TODO: Support planar pixel buffers!");
		
		CVPixelBufferLockBaseAddress(pixelBuffer, 0);
		void *src = CVPixelBufferGetBaseAddress(pixelBuffer);
		unsigned int width = CVPixelBufferGetWidth(pixelBuffer);
		unsigned int height = CVPixelBufferGetHeight(pixelBuffer);
		size_t bytes_per_row = CVPixelBufferGetBytesPerRow(pixelBuffer);
		size_t target_bytes_per_row = mFrameWidth * 4;

		if (bytes_per_row != width * 4)
			NSLog(@"Expected bytes per row to be %d but got %d.", width * 4, bytes_per_row);
		
		void *cgDest = calloc(target_bytes_per_row * mFrameHeight, 1);
		CGColorSpaceRef myColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
		CGContextRef myContext = CGBitmapContextCreate(cgDest, mFrameWidth, mFrameHeight, 8, target_bytes_per_row, myColorSpace, kCGImageAlphaPremultipliedLast);

		CGDataProviderRef pixelBufferData = CGDataProviderCreateWithData(NULL, src, bytes_per_row * height, NULL);
		CGImageRef cgImage = CGImageCreate(width, height, 8, 32, bytes_per_row, myColorSpace, kCGImageAlphaPremultipliedLast, pixelBufferData, NULL, YES, kCGRenderingIntentDefault);

		CGRect dest;
		dest.origin.x = 0;
		dest.origin.y = 0;
		dest.size.width = mScaledWidth;
		dest.size.height = mScaledHeight;

		CGContextDrawImage(myContext, dest, cgImage);

		if (kEnableJPEG) {
			CGImageRef myContextImage = CGBitmapContextCreateImage(myContext);
			NSURL *imageURL = [NSURL URLWithString:@"file:///Users/atul/Desktop/screencap.jpg"];

			float compression = 0.1;
			int orientation = 1;
			CFStringRef myKeys[3];
			CFTypeRef   myValues[3];
			CFDictionaryRef myOptions = NULL;
			myKeys[0] = kCGImagePropertyOrientation;
			myValues[0] = CFNumberCreate(NULL, kCFNumberIntType, &orientation);
			myKeys[1] = kCGImagePropertyHasAlpha;
			myValues[1] = kCFBooleanTrue;
			myKeys[2] = kCGImageDestinationLossyCompressionQuality;
			myValues[2] = CFNumberCreate(NULL, kCFNumberFloatType, &compression);
			myOptions = CFDictionaryCreate( NULL, (const void **)myKeys, (const void **)myValues, 3,
										   &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			
			CGImageDestinationRef imageFile = CGImageDestinationCreateWithURL((CFURLRef) imageURL, kUTTypeJPEG, 1, nil);
			CGImageDestinationAddImage(imageFile, myContextImage, myOptions);
			CGImageDestinationFinalize(imageFile);
			CFRelease(imageFile);
			CFRelease(myOptions);
			CFRelease(myValues[0]);
			CFRelease(myValues[2]);
			CGImageRelease(myContextImage);
		}
		
		CGImageRelease(cgImage);
		CGDataProviderRelease(pixelBufferData);

		CGContextRelease(myContext);
		CGColorSpaceRelease(myColorSpace);

		CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

		if (kEnableTheora || kEnableWebM) {			
			/* i420 is 3/2 bytes per pixel */
			int v_frame_size = mFrameWidth * mFrameHeight * 3 / 2;
			void *v_frame = calloc(v_frame_size, 1);
			if (v_frame == NULL)
				NSLog(@"calloc() failed.");

			BGR32toI420(mFrameWidth, mFrameHeight, cgDest, v_frame);

			if (kEnableWebM) {
				[[mWebM.pipe fileHandleForWriting] writeData:[NSData dataWithBytes:v_frame length:v_frame_size]];
			}

			if (kEnableTheora) {
				if (mTheora.framesWritten == 0) {
					createTheoraFile();
				}
				
				th_ycbcr_buffer v_buffer;

				/* Convert i420 to YCbCr */
				v_buffer[0].width = mFrameWidth;
				v_buffer[0].stride = mFrameWidth;
				v_buffer[0].height = mFrameHeight;
				
				v_buffer[1].width = (v_buffer[0].width >> 1);
				v_buffer[1].height = (v_buffer[0].height >> 1);
				v_buffer[1].stride = v_buffer[1].width;
				
				v_buffer[2].width = v_buffer[1].width;
				v_buffer[2].height = v_buffer[1].height;
				v_buffer[2].stride = v_buffer[1].stride;
				
				v_buffer[0].data = v_frame;
				v_buffer[1].data = v_frame + v_buffer[0].width * v_buffer[0].height;
				v_buffer[2].data = v_buffer[1].data + v_buffer[0].width * v_buffer[0].height / 4;

				switch (th_encode_ycbcr_in(mTheora.th, v_buffer)) {
					case TH_EFAULT:
						NSLog(@"th_encode_ycbcr_in() returned TH_EFAULT.");
						break;
					case TH_EINVAL:
						NSLog(@"th_encode_ycbcr_in() returned TH_EINVAL.");
						break;
					case 0:
						// Success!
						break;
					default:
						NSLog(@"th_encode_ycbcr_in() returned an invalid response.");
				}
				
				mTheora.framesWritten++;

				int isLastPacket = 0;
				int framesPerMovie = kSecondsPerMovie * mFPS;

				if (mTheora.framesWritten == framesPerMovie)
					isLastPacket = 1;
				
				if (!th_encode_packetout(mTheora.th, isLastPacket, &mTheora.op))
					NSLog(@"th_encode_packetout() failed.");
				
				ogg_stream_packetin(&mTheora.os, &mTheora.op);
				while (ogg_stream_pageout(&mTheora.os, &mTheora.og)) {
					writeTheoraPage(@"page");
				}

				if (mTheora.framesWritten == framesPerMovie) {
					closeTheoraFile();
					mTheora.framesWritten = 0;
				}
			}

			free(v_frame);
		}

		free(cgDest);

		// TODO: Why does CVPixelBufferRelease(pixelBuffer) crash us?

		NSLog(@"Encoded 1 frame @ %dx%d (%d left in queue).", mFrameWidth, mFrameHeight, mFramesLeft-1);
		
		[mFrameQueueController addItemToFreeQ:reader];			
	}

	mFramesLeft--;

	[pool release];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	mSelf = self;

	mRequestQueue = dispatch_queue_create("com.toolness.requestQueue", NULL);
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSDictionary *appDefaults = [NSDictionary dictionaryWithObjectsAndKeys:
								 @"http://localhost:8080",@"BroadcastURL",
								 [NSNumber numberWithInt:8],@"FPS",
								 nil];
	[defaults registerDefaults:appDefaults];

	NSString *broadcastURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"BroadcastURL"];
	[urlField setStringValue:broadcastURL];
	
	NSInteger fps = [[NSUserDefaults standardUserDefaults] integerForKey:@"FPS"];
	[fpsSlider setIntegerValue:fps];

	NSLog(@"Initialized.");
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	if (mIsRecording)
		[self stopRecording:self];

	dispatch_release(mRequestQueue);
	
	NSLog(@"Terminating.");
}

- (IBAction)stopRecording:(id)sender
{
	CVDisplayLinkStop(mDisplayLink);
	CVDisplayLinkRelease(mDisplayLink);
	mDisplayLink = NULL;
	
	mShouldStop = YES;
	
	while (mFramesLeft) {}
	
	if (kEnableTheora)
		closeTheoraFile();
	
	if (kEnableWebM) {
		[[mWebM.pipe fileHandleForWriting] closeFile];
		[mWebM.pipe release];
		[mWebM.encoder release];
	}
	
	[mFrameQueueController release];
	mFrameQueueController = nil;
	
	[mGLContext release];
	mGLContext = nil;
	
	[mGLPixelFormat release];
	mGLPixelFormat = nil;
	
	mIsRecording = NO;
	[startRecording setEnabled:YES];
	[urlField setEnabled:YES];
	[fpsSlider setEnabled:YES];
	[stopRecording setEnabled:NO];
}

- (IBAction)startRecording:(id)sender
{
	mShouldStop = NO;
	
	mFPS = [[NSUserDefaults standardUserDefaults] integerForKey:@"FPS"];
	
	NSLog(@"Preparing to record at %d frames per second.", mFPS);

	NSString *baseURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"BroadcastURL"];
	[baseURL retain];

	dispatch_async(mRequestQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSURL *postURL = [NSURL URLWithString:[baseURL stringByAppendingString:@"/clear"]];
		NSMutableURLRequest *postRequest = [NSMutableURLRequest requestWithURL:postURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2.0];
		[postRequest setHTTPMethod:@"POST"];
		NSURLResponse *response = NULL;
		NSError *error = NULL;
		[NSURLConnection sendSynchronousRequest:postRequest returningResponse:&response error:&error];
		NSLog(@"Clear connection response: %@   error: %@", response, error);
		[baseURL release];
		[pool release];
	});
	
	// Insert code here to initialize your application 
	NSOpenGLPixelFormatAttribute attributes[] = {
		NSOpenGLPFAFullScreen,
		NSOpenGLPFAScreenMask,
		CGDisplayIDToOpenGLDisplayMask(kCGDirectMainDisplay),
		(NSOpenGLPixelFormatAttribute) 0
	};
	
	mGLPixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
	NSAssert(mGLPixelFormat != nil, @"NSOpenGLPixelFormat creation failed.");
	
	mGLContext = [[NSOpenGLContext alloc] initWithFormat:mGLPixelFormat shareContext:nil];
	NSAssert(mGLContext != nil, @"NSOpenGLContext creation failed.");
	[mGLContext makeCurrentContext];
	[mGLContext setFullScreen];
	
	CGDirectDisplayID displayID = CGMainDisplayID();
	mDisplayRect = CGDisplayBounds(displayID);
	
	unsigned int width = mDisplayRect.size.width;
	unsigned int height = mDisplayRect.size.height;
	
	mFrameQueueController = [[QueueController alloc] initWithReaderObjects:kNumReaderObjects
																  aContext:mGLContext pixelsWide:width pixelsHigh:height
																   xOffset:0 yOffset:0];
	
	mScaledWidth = width * kImageScaling;
	mScaledHeight = height * kImageScaling;

	NSLog(@"Native screen size is %dx%d, scaled size is %dx%d.", width, height, mScaledWidth, mScaledHeight);

	unsigned int horizPadding = 0;
	unsigned int vertPadding = 0;
	
	if (kEnableWebM || kEnableTheora) {
		NSLog(@"Using %s.", th_version_string());
		// Crop up so we're a multiple of 16, which is an easy way of satisfying Theora encoding requirements.
		horizPadding = ((mScaledWidth + 15) & ~0xF) - mScaledWidth;
		vertPadding = ((mScaledHeight + 15) & ~0xF) - mScaledHeight;
	}
	
	mFrameWidth = mScaledWidth + horizPadding;
	mFrameHeight = mScaledHeight + vertPadding;

	mLastTime = [NSDate timeIntervalSinceReferenceDate];
	mFPSInterval = 1.0 / mFPS;
	
	CVDisplayLinkCreateWithCGDisplay(kCGDirectMainDisplay, &mDisplayLink);
	NSAssert(mDisplayLink != NULL, @"Couldn't create display link for the main display.");
	CVDisplayLinkSetCurrentCGDisplay(mDisplayLink, kCGDirectMainDisplay);
	CVDisplayLinkSetOutputCallback(mDisplayLink, displayLinkCallback, NULL);
	CVDisplayLinkStart(mDisplayLink);
	
	if (kEnableWebM) {
		mWebM.pipe = [[NSPipe alloc] init];
		mWebM.encoder = [[NSTask alloc] init];
		NSMutableArray *args = [NSMutableArray array];
		
		[args addObject:[NSString stringWithFormat:@"--width=%d", mScaledWidth]];
		[args addObject:[NSString stringWithFormat:@"--height=%d", mScaledHeight]];
		[args addObject:[NSString stringWithFormat:@"--fps=%d/1", mFPS]];
		[args addObject:@"-p"];
		[args addObject:@"1"];
		[args addObject:@"-t"];
		[args addObject:@"4"];
		[args addObject:@"-o"];
		[args addObject:@"/Users/atul/screencap.webm"];
		[args addObject:@"-"];
		[args addObjectsFromArray:[NSArray arrayWithObjects:@"--rt", @"--cpu-used=4", @"--end-usage=1", @"--target-bitrate=100", nil]];
		[mWebM.encoder setLaunchPath:@"/Users/atul/Documents/read-only/libvpx/vpxenc"];
		[mWebM.encoder setArguments:args];
		[mWebM.encoder setStandardInput:mWebM.pipe];
		[mWebM.encoder launch];
	}

	mIsRecording = YES;
	[startRecording setEnabled:NO];
	[urlField setEnabled:NO];
	[fpsSlider setEnabled:NO];
	[stopRecording setEnabled:YES];
}

- (IBAction)changeBroadcastURL:(id)sender
{
	[[NSUserDefaults standardUserDefaults] setObject:[urlField stringValue] forKey:@"BroadcastURL"];
}

- (IBAction)changeFPS:(id)sender
{
	[[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithInt:[fpsSlider intValue]] forKey:@"FPS"];
}

@end
