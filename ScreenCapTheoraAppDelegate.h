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
	IBOutlet NSButton *startRecording;
	IBOutlet NSButton *stopRecording;
	IBOutlet NSTextField *urlField;
	IBOutlet NSSlider *fpsSlider;
}

@property (assign) IBOutlet NSWindow *window;

- (void)processFrameSynchronized:(id)param;
- (IBAction)startRecording:(id)sender;
- (IBAction)stopRecording:(id)sender;
- (IBAction)changeFPS:(id)sender;
- (IBAction)changeBroadcastURL:(id)sender;
@end
