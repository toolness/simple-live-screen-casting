//
//  ScreenCapTheoraAppDelegate.h
//  ScreenCapTheora
//
//  Created by Atul Varma on 1/22/11.
//  Copyright 2011 Mozilla. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface ScreenCapTheoraAppDelegate : NSObject <NSApplicationDelegate> {
    NSWindow *window;
}

@property (assign) IBOutlet NSWindow *window;

- (void)processFrameSynchronized:(id)param;

@end
