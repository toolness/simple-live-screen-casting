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

// Whether to write the user's screen to a Theora stream that's sent to a node.js
// server for streaming to other browsers.
#define kEnableTheoraStreaming 1

// Whether any kind of Theora output is enabled at all.
#define kEnableTheora (kEnableTheoraFile || kEnableTheoraStreaming)

// Whether to write snapshots of the user's screen to JPEG files.
#define kEnableJPEG 0

// The number of screen readers in existence at one time.
#define kNumReaderObjects 20

// How often to create keyframes in the Theora stream. For more information, see:
// http://www.theora.org/doc/libtheora-1.0/structth__info.html#693ca4ab11fbc0c3f32594b4bb8766ed
#define kTheoraKeyframeGranuleShift 6

// Number of seconds each movie lasts. When this period is over, a new movie is created.
// Set to -1 if you only want one movie that is arbitrarily long.
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

// A dispatch queue for sending Ogg stream pages to the node.js server.
static dispatch_queue_t mRequestQueue;

static WebMState mWebM;
static TheoraState mTheora;
static NSOpenGLContext *mGLContext;
static NSOpenGLPixelFormat *mGLPixelFormat;
static CVDisplayLinkRef mDisplayLink;
static QueueController *mFrameQueueController;
static NSString *mRecordingMutex;

// Current frames per second of each movie.
static int mFPS;

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

// The number of bytes left to send.
volatile static int mBytesLeft = 0;

// Whether or not any auxiliary threads spawned by the main thread should stop at
// their earliest possible convenience.
BOOL mShouldStop;

static void changeBytesLeftBy(int amount) {
	@synchronized(mRecordingMutex) {
		mBytesLeft += amount;
		[mSelf setBytesLeft:mBytesLeft];
	}
}

static void changeFramesLeftBy(int amount) {
	@synchronized(mRecordingMutex) {
		mFramesLeft += amount;
		[mSelf setFramesLeft:mFramesLeft];
	}
}

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

		changeBytesLeftBy(totalSize);
		
		dispatch_async(mRequestQueue, ^{			
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

			if (mShouldStop) {
				free(buf);
				[kind release];
				[baseURL release];
				changeBytesLeftBy(-totalSize);
				[pool release];
				return;
			}			
			
			NSData *bufData = [NSData dataWithBytes:buf length:totalSize];
			free(buf);
			NSURL *postURL = [NSURL URLWithString:[baseURL stringByAppendingString:@"/update"]];
			NSMutableURLRequest *postRequest = [NSMutableURLRequest requestWithURL:postURL
																	   cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
																   timeoutInterval:1.0];
			[postRequest setHTTPMethod:@"POST"];
			[postRequest setHTTPBody:bufData];
			[postRequest addValue:kind forHTTPHeaderField:@"x-theora-kind"];
			[postRequest addValue:[NSString stringWithFormat:@"%d", kSecondsPerMovie]
			   forHTTPHeaderField:@"x-content-duration"];
			[postRequest addValue:[NSString stringWithFormat:@"%d", currentMovieID]
			   forHTTPHeaderField:@"x-theora-id"];
			NSURLResponse *response = NULL;
			NSError *error = NULL;
			// TODO: Connections to the same host/port are pooled with HTTP keep-alive by OS X,
			// but even still, sending a separate request for each Ogg page isn't necessarily
			// a great idea. The overhead of sending HTTP headers, for instance, should be
			// taken into account.
			[NSURLConnection sendSynchronousRequest:postRequest
								  returningResponse:&response
											  error:&error];
			if (error)
				[mSelf setNetworkErrors:[mSelf networkErrors] + 1];
			
			NSLog(@"Connection response: %@   error: %@   total bytes left: %d", response, error, mBytesLeft);
			[baseURL release];
			[kind release];
			changeBytesLeftBy(-totalSize);
			[pool release];
		});
	}

	NSLog(@"Wrote theora %@ page of size %ld bytes.", kind,
		  mTheora.og.header_len + mTheora.og.body_len);
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
	mTheora.framesWritten = 0;
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
	mTheora.ti.pic_y = mFrameHeight - mScaledHeight;
	mTheora.ti.fps_numerator = mFPS;
	mTheora.ti.fps_denominator = 1;
	
	NSLog(@"Frame size is %dx%d, picture size is %dx%d.", mTheora.ti.frame_width,
		  mTheora.ti.frame_height, mTheora.ti.pic_width, mTheora.ti.pic_height);
	
	double kbps = [[NSUserDefaults standardUserDefaults] doubleForKey:@"Bitrate"];

	/* Are these the right values? */
	mTheora.ti.target_bitrate = kbps * 1000;
	mTheora.ti.colorspace = TH_CS_ITU_REC_470M;
	mTheora.ti.pixel_fmt = TH_PF_420;
	mTheora.ti.keyframe_granule_shift = kTheoraKeyframeGranuleShift;
	
	mTheora.th = th_encode_alloc(&mTheora.ti);
	if (mTheora.th == NULL) {
		NSLog(@"th_encode_alloc() failed.");
	}
	
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
		NSString *filename = [NSString stringWithFormat:@"%@/screencap-%d.ogv",
							  NSHomeDirectory(), mTheora.movieID];
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
	if (freeReader && !mShouldStop) {
		changeFramesLeftBy(1);
		[freeReader setBufferReadTime:time];
		[freeReader readScreenAsyncOnSeparateThread];
		[freeReader release];
	}
    
	FrameReader *filledReader = [mFrameQueueController removeOldestItemFromFilledQ];
	if (filledReader) {
		[NSThread detachNewThreadSelector:@selector(processFrameSynchronized:)
								 toTarget:mSelf
							   withObject:filledReader];
        [filledReader release];
	}
    
	[pool release];
	return kCVReturnSuccess;
}

@implementation ScreenCapTheoraAppDelegate

@synthesize window;
@synthesize framesLeft;
@synthesize bytesLeft;
@synthesize networkErrors;
@synthesize isRecording;

- (void)processFrameSynchronized:(id)param
{   
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    
	@synchronized([ScreenCapTheoraAppDelegate class]) {        
		FrameReader *reader = (FrameReader *)param;
		
		CVPixelBufferRef pixelBuffer = [reader readScreenAsyncFinish];
		if (CVPixelBufferIsPlanar(pixelBuffer))
			NSLog(@"TODO: Support planar pixel buffers!");

		if (mShouldStop) {
			[mFrameQueueController addItemToFreeQ:reader];
			changeFramesLeftBy(-1);
			[pool release];
			return;
		}
		
		CVPixelBufferLockBaseAddress(pixelBuffer, 0);
		void *src = CVPixelBufferGetBaseAddress(pixelBuffer);
		unsigned int width = CVPixelBufferGetWidth(pixelBuffer);
		unsigned int height = CVPixelBufferGetHeight(pixelBuffer);
		size_t bytes_per_row = CVPixelBufferGetBytesPerRow(pixelBuffer);
		size_t target_bytes_per_row = mFrameWidth * 4;

		if (bytes_per_row != width * 4)
			// Not sure why, but this happens fairly often. It might be to
			// align bytes_per_row to 16 bytes, which improves performance
			// according to the "Creating a Bitmap Graphics Context" section
			// of the Quartz 2D Programming Guide.
			//
			// Note that this also happens even when CVPixelBufferGetExtendedPixels()
			// says there are no extra columns on the left or right.
			NSLog(@"Expected bytes per row to be %d but got %lu.", width * 4, bytes_per_row);

		void *cgDest = calloc(target_bytes_per_row * mFrameHeight, 1);
		CGColorSpaceRef myColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
		CGContextRef myContext = CGBitmapContextCreate(cgDest, mFrameWidth, mFrameHeight, 8, target_bytes_per_row,
													   myColorSpace, kCGImageAlphaPremultipliedLast);

		CGDataProviderRef pixelBufferData = CGDataProviderCreateWithData(NULL, src, bytes_per_row * height, NULL);
		CGImageRef cgImage = CGImageCreate(width, height, 8, 32, bytes_per_row, myColorSpace,
										   kCGImageAlphaPremultipliedLast, pixelBufferData, NULL, YES,
										   kCGRenderingIntentDefault);

		CGRect dest;
		dest.origin.x = 0;
		dest.origin.y = 0;
		dest.size.width = mScaledWidth;
		dest.size.height = mScaledHeight;

		CGContextDrawImage(myContext, dest, cgImage);

		if (kEnableJPEG) {
			CGImageRef myContextImage = CGBitmapContextCreateImage(myContext);
			NSString *filename = [NSString stringWithFormat:@"%@/screencap.jpg",
								  NSHomeDirectory()];
			NSURL *imageURL = [NSURL fileURLWithPath:filename];

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
			myOptions = CFDictionaryCreate(NULL, (const void **)myKeys, (const void **)myValues, 3,
										   &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			
			CGImageDestinationRef imageFile = CGImageDestinationCreateWithURL((CFURLRef) imageURL,
																			  kUTTypeJPEG, 1, nil);
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
				[[mWebM.pipe fileHandleForWriting] writeData:[NSData dataWithBytes:v_frame
																			length:v_frame_size]];
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
				}
			}

			free(v_frame);
		}

		free(cgDest);

		NSLog(@"Encoded 1 frame @ %dx%d (%d left in queue).", mFrameWidth, mFrameHeight, mFramesLeft-1);
		
		[mFrameQueueController addItemToFreeQ:reader];			
	}

	changeFramesLeftBy(-1);

	[pool release];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	mSelf = self;
	
	[cropArea setFloatingPanel:YES];
	[cropArea setBecomesKeyOnlyIfNeeded:YES];
	[cropArea setBackgroundColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.1]];
	
	[self setIsRecording:NO];
	[self setFramesLeft:0];

	mRequestQueue = dispatch_queue_create("org.mozilla.echoance.requestqueue", NULL);
	
	mRecordingMutex = [[NSString alloc] initWithString:@"Recording Mutex"];

	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSDictionary *appDefaults = [NSDictionary dictionaryWithObjectsAndKeys:
								 @"http://localhost:8080",@"BroadcastURL",
								 [NSNumber numberWithInt:8],@"FPS",
								 [NSNumber numberWithInt:33],@"ScaleFactor",
								 [NSNumber numberWithInt:128],@"Bitrate",
								 [NSNumber numberWithBool:NO],@"EnableCropping",
								 nil];
	[defaults registerDefaults:appDefaults];

	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"EnableCropping"])
		[cropArea orderFront:nil];

	NSLog(@"Initialized.");
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	if ([self isRecording])
		[self stopRecording:self];

	dispatch_release(mRequestQueue);
	
	[mRecordingMutex release];
	mRecordingMutex = nil;
	
	NSLog(@"Terminating.");
}

- (IBAction)stopRecording:(id)sender
{	
	mShouldStop = YES;

	BOOL isDone = NO;

	while (!isDone) {
		@synchronized(mRecordingMutex) {
			isDone = (mFramesLeft == 0) && (mBytesLeft == 0);
		}
		usleep(10000);
	}

	CVDisplayLinkStop(mDisplayLink);
	CVDisplayLinkRelease(mDisplayLink);
	mDisplayLink = NULL;
	
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
	
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"EnableCropping"])
		[cropArea orderFront:nil];

	[self setIsRecording:NO];
}

- (IBAction)startRecording:(id)sender
{
	mShouldStop = NO;

	[self setNetworkErrors:0];

	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	mFPS = [defaults integerForKey:@"FPS"];

	BOOL enableCropping = [defaults boolForKey:@"EnableCropping"];
	if (enableCropping)
		[cropArea orderOut:nil];
	
	NSLog(@"Preparing to record at %d frames per second.", mFPS);

	if (kEnableTheoraStreaming) {
		NSString *baseURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"BroadcastURL"];
		[baseURL retain];

		changeBytesLeftBy(1);

		dispatch_async(mRequestQueue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			NSURL *postURL = [NSURL URLWithString:[baseURL stringByAppendingString:@"/clear"]];
			NSMutableURLRequest *postRequest = [NSMutableURLRequest requestWithURL:postURL
																	   cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
																   timeoutInterval:2.0];
			[postRequest setHTTPMethod:@"POST"];
			NSURLResponse *response = NULL;
			NSError *error = NULL;
			[NSURLConnection sendSynchronousRequest:postRequest
								  returningResponse:&response
											  error:&error];
			if (error)
				[mSelf setNetworkErrors:[mSelf networkErrors] + 1];

			NSLog(@"Clear connection response: %@   error: %@", response, error);
			[baseURL release];
			changeBytesLeftBy(-1);
			[pool release];
		});
	}
	
    CGDirectDisplayID displayID;
	
	if (enableCropping) {
		NSDictionary *desc = [[cropArea screen] deviceDescription];
		NSNumber *screenNumber = (NSNumber *)[desc valueForKey:@"NSScreenNumber"];
		displayID = [screenNumber intValue];
	} else {
		displayID = CGMainDisplayID();
    }
	
	NSOpenGLPixelFormatAttribute attributes[] = {
		NSOpenGLPFAFullScreen,
		NSOpenGLPFAScreenMask,
		CGDisplayIDToOpenGLDisplayMask(displayID),
		(NSOpenGLPixelFormatAttribute) 0
	};
	
	mGLPixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
	NSAssert(mGLPixelFormat != nil, @"NSOpenGLPixelFormat creation failed.");
	
	mGLContext = [[NSOpenGLContext alloc] initWithFormat:mGLPixelFormat
											shareContext:nil];
	NSAssert(mGLContext != nil, @"NSOpenGLContext creation failed.");
	[mGLContext makeCurrentContext];
	[mGLContext setFullScreen];

	CGRect displayRect;

	if (enableCropping) {
		NSRect contentRect = [cropArea contentRectForFrameRect:[cropArea frame]];
		NSRect screenFrame = [[cropArea screen] frame];
		displayRect.origin.y = contentRect.origin.y - screenFrame.origin.y;
		displayRect.origin.x = contentRect.origin.x - screenFrame.origin.x;
		displayRect.size.width = contentRect.size.width;
		displayRect.size.height = contentRect.size.height;
	} else {
		displayRect = CGDisplayBounds(displayID);
	}

	// TODO: Note that we're doing implicit type-casting here, since NSRect/CGRect
	// bounds are floats and may be in user-space rather than device space. If the
	// NSScreen's userSpaceScaleFactor isn't 1.0, this could mean trouble.
	unsigned int width = displayRect.size.width;
	unsigned int height = displayRect.size.height;
	
	mFrameQueueController = [[QueueController alloc] initWithReaderObjects:kNumReaderObjects
																  aContext:mGLContext
																pixelsWide:width
																pixelsHigh:height
																   xOffset:displayRect.origin.x
																   yOffset:displayRect.origin.y];
	
	double scaleFactor = [[NSUserDefaults standardUserDefaults] doubleForKey:@"ScaleFactor"];

	scaleFactor = scaleFactor / 100.0;

	mScaledWidth = width * scaleFactor;
	mScaledHeight = height * scaleFactor;

	NSLog(@"Native screen size is %dx%d, scaled size is %dx%d.", width, height,
		  mScaledWidth, mScaledHeight);

	unsigned int horizPadding = 0;
	unsigned int vertPadding = 0;
	
	if (kEnableTheora) {
		NSLog(@"Using %s.", th_version_string());
		// Crop up so we're a multiple of 16, which is an easy way of satisfying Theora encoding requirements.
		horizPadding = ((mScaledWidth + 15) & ~0xF) - mScaledWidth;
		vertPadding = ((mScaledHeight + 15) & ~0xF) - mScaledHeight;
	}
	
	mFrameWidth = mScaledWidth + horizPadding;
	mFrameHeight = mScaledHeight + vertPadding;

	mLastTime = [NSDate timeIntervalSinceReferenceDate];
	mFPSInterval = 1.0 / mFPS;
	
	CVDisplayLinkCreateWithCGDisplay(displayID, &mDisplayLink);
	NSAssert(mDisplayLink != NULL, @"Couldn't create display link for the main display.");
	
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
		[args addObject:[NSString stringWithFormat:@"%@/screencap.webm",
						 NSHomeDirectory()]];
		[args addObject:@"-"];
		[args addObjectsFromArray:[NSArray arrayWithObjects:@"--rt", @"--cpu-used=4",
								   @"--end-usage=1", @"--target-bitrate=100", nil]];
		// TODO: Remove this hardcoded file path.
		[mWebM.encoder setLaunchPath:@"/Users/atul/Documents/read-only/libvpx/vpxenc"];
		[mWebM.encoder setArguments:args];
		[mWebM.encoder setStandardInput:mWebM.pipe];
		[mWebM.encoder launch];
	}

	[self setIsRecording:YES];
}

- (void)windowWillClose:(NSNotification *)notification
{
	if ([notification object] == window)
		[[NSApplication sharedApplication] terminate:nil];
}

- (IBAction)toggleCropping:(id)sender
{
	NSButton *checkbox = (NSButton *)sender;
	if ([checkbox state] == NSOnState) {
		[cropArea orderFront:nil];
	} else {
		[cropArea orderOut:nil];
	}
}

@end
