//
//  ScreenCapTheoraAppDelegate.m
//  ScreenCapTheora
//
//  Created by Atul Varma on 1/22/11.
//  Copyright 2011 Mozilla. All rights reserved.
//

#include <sys/stat.h>
#include <ogg/ogg.h>
#include <theora/theoraenc.h>
#include "Convert.h"

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import "ScreenCapTheoraAppDelegate.h"
#import "QueueController.h"
#import "FrameReader.h"

#define kEnableTheora 1
#define kEnableJPEG 0
#define kNumReaderObjects 20
#define kFPS 10
#define kImageScaling 0.25
#define kTheoraQuality 32
#define kTheoraKeyframeGranuleShift 6

typedef struct {
	int fd;
	th_info ti;
	th_enc_ctx *th;
	th_comment tc;
	ogg_packet op;
	ogg_stream_state os;
	ogg_page og;
} TheoraState;

static TheoraState mTheora;
static NSOpenGLContext *mGLContext;
static NSOpenGLPixelFormat *mGLPixelFormat;
static CVDisplayLinkRef mDisplayLink;
static CGRect mDisplayRect;
static QueueController *mFrameQueueController;
static ScreenCapTheoraAppDelegate *mSelf;
static NSTimeInterval mLastTime;
static NSTimeInterval mFPSInterval;
static unsigned int mScaledWidth;
static unsigned int mScaledHeight;
volatile static int mFramesLeft = 0;
BOOL mShouldStop;

static void writeTheoraPage() {
	write(mTheora.fd, mTheora.og.header, mTheora.og.header_len);
	write(mTheora.fd, mTheora.og.body, mTheora.og.body_len);
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
		unsigned int targetWidth = mScaledWidth;
		unsigned int targetHeight = mScaledHeight;
		size_t bytes_per_row = CVPixelBufferGetBytesPerRow(pixelBuffer);
		size_t target_bytes_per_row = targetWidth * 4;

		if (bytes_per_row != width * 4)
			NSLog(@"Expected bytes per row to be %d but got %d.", width * 4, bytes_per_row);
		
		void *cgDest = calloc(target_bytes_per_row * targetHeight, 1);
		CGColorSpaceRef myColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
		CGContextRef myContext = CGBitmapContextCreate(cgDest, targetWidth, targetHeight, 8, target_bytes_per_row, myColorSpace, kCGImageAlphaPremultipliedLast);

		CGDataProviderRef pixelBufferData = CGDataProviderCreateWithData(NULL, src, bytes_per_row * height, NULL);
		CGImageRef cgImage = CGImageCreate(width, height, 8, 32, bytes_per_row, myColorSpace, kCGImageAlphaPremultipliedLast, pixelBufferData, NULL, YES, kCGRenderingIntentDefault);

		CGRect dest;
		dest.origin.x = 0;
		dest.origin.y = 0;
		dest.size.width = targetWidth;
		dest.size.height = targetHeight;

		CGContextDrawImage(myContext, dest, cgImage);

		if (kEnableJPEG) {
			CGImageRef myContextImage = CGBitmapContextCreateImage(myContext);
			NSURL *imageURL = [NSURL URLWithString:@"file:///Users/avarma/Desktop/screencap.jpg"];

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

		if (kEnableTheora) {
			/* i420 is 3/2 bytes per pixel */
			int v_frame_size = targetWidth * targetHeight * 3 / 2;
			void *v_frame = calloc(v_frame_size, 1);
			if (v_frame == NULL)
				NSLog(@"calloc() failed.");

			BGR32toI420(targetWidth, targetHeight, cgDest, v_frame);

			th_ycbcr_buffer v_buffer;

			/* Convert i420 to YCbCr */
			v_buffer[0].width = targetWidth;
			v_buffer[0].stride = targetWidth;
			v_buffer[0].height = targetHeight;
			
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

			if (!th_encode_packetout(mTheora.th, 0, &mTheora.op))
				NSLog(@"th_encode_packetout() failed.");
			
			ogg_stream_packetin(&mTheora.os, &mTheora.op);
			while (ogg_stream_pageout(&mTheora.os, &mTheora.og)) {
				writeTheoraPage();
			}

			free(v_frame);
		}

		free(cgDest);

		// TODO: Why does CVPixelBufferRelease(pixelBuffer) crash us?

		NSLog(@"Encoded 1 frame @ %dx%d.", targetWidth, targetHeight);
		
		[mFrameQueueController addItemToFreeQ:reader];			
	}

	mFramesLeft--;

	[pool release];
}

static void closeTheoraFile()
{
	th_encode_free(mTheora.th);
	
	if (ogg_stream_flush(&mTheora.os, &mTheora.og))
		writeTheoraPage();
	ogg_stream_clear(&mTheora.os);
	
	close(mTheora.fd);
	
	mTheora.th = NULL;	
}

static void createTheoraFile()
{
	if (ogg_stream_init(&mTheora.os, rand()))
		NSLog(@"ogg_stream_init() failed.");
	th_info_init(&mTheora.ti);
	
	NSLog(@"Picture size is %dx%d.", mScaledWidth, mScaledHeight);
	
	/* Must be multiples of 16 */
	mTheora.ti.frame_width = mScaledWidth;
	mTheora.ti.frame_height = mScaledHeight;
	mTheora.ti.pic_width = mScaledWidth;
	mTheora.ti.pic_height = mScaledHeight;
	mTheora.ti.pic_x = 0;
	mTheora.ti.pic_y = 0;
	mTheora.ti.fps_numerator = kFPS;
	mTheora.ti.fps_denominator = 1;
	
	NSLog(@"Frame size is %dx%d, with the picture offset at (%d, %d).", mTheora.ti.frame_width, mTheora.ti.frame_height, mTheora.ti.pic_x, mTheora.ti.pic_y);
	
	/* Are these the right values? */
	mTheora.ti.quality = kTheoraQuality;
	//mTheora.ti.target_bitrate = 128000;
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
	
	// TODO: Don't hardcode this filename.
	mTheora.fd = open("/Users/avarma/Desktop/screencap.ogv", O_WRONLY | O_CREAT | O_TRUNC | O_SYNC);		
	if (mTheora.fd < 0)
		NSLog(@"open() failed.");
	
	fchmod(mTheora.fd, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
	
	writeTheoraPage();
	
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
		writeTheoraPage();
	}	
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	mSelf = self;

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

	if (kEnableTheora) {
		// Crop down so we're a multiple of 16, which is an easy way of satisfying Theora encoding requirements.
		// TODO: Crop *up* instead, or make this better somehow?
		mScaledWidth = ((mScaledWidth - 15) & ~0xF) + 16;
		mScaledHeight = ((mScaledHeight - 15) & ~0xF) + 16;
		
		createTheoraFile();
	}

	mLastTime = [NSDate timeIntervalSinceReferenceDate];
	mFPSInterval = 1.0 / kFPS;

	CVDisplayLinkCreateWithCGDisplay(kCGDirectMainDisplay, &mDisplayLink);
	NSAssert(mDisplayLink != NULL, @"Couldn't create display link for the main display.");
	CVDisplayLinkSetCurrentCGDisplay(mDisplayLink, kCGDirectMainDisplay);
	CVDisplayLinkSetOutputCallback(mDisplayLink, displayLinkCallback, NULL);
	CVDisplayLinkStart(mDisplayLink);

	NSLog(@"Initialized.");
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	CVDisplayLinkStop(mDisplayLink);
	CVDisplayLinkRelease(mDisplayLink);
	mDisplayLink = NULL;

	mShouldStop = YES;
	
	while (mFramesLeft) {}

	if (kEnableTheora)
		closeTheoraFile();
	
	[mFrameQueueController release];
	mFrameQueueController = nil;
		
	[mGLContext release];
	mGLContext = nil;
	
	[mGLPixelFormat release];
	mGLPixelFormat = nil;
	
	NSLog(@"Terminating.");
}

@end
