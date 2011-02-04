//
//  ScreenCapTheoraAppDelegate.h
//  ScreenCapTheora
//
//  Created by Atul Varma on 1/22/11.
//  Copyright 2011 Mozilla. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface ScreenCapTheoraAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate> {
    NSWindow *window;
}

@property (assign) IBOutlet NSWindow *window;
@property (assign) NSInteger framesLeft;
@property (assign) NSInteger bytesLeft;
@property (assign) NSInteger networkErrors;
@property (assign) BOOL isRecording;

- (void)processFrameSynchronized:(id)param;
- (IBAction)startRecording:(id)sender;
- (IBAction)stopRecording:(id)sender;
@end
