//
//  WISTSampleAppDelegate.m
//  WISTSample
//
//  Created by Nobuhisa Okamura on 11/05/19.
//  Copyright 2011 KORG INC. All rights reserved.
//

#import "WISTSampleAppDelegate.h"
#import "WISTSampleViewController.h"

@implementation WISTSampleAppDelegate

@synthesize window;
@synthesize viewController;

//  ---------------------------------------------------------------------------
//      dealloc
//  ---------------------------------------------------------------------------
- (void)dealloc
{
    [viewController release];
    [window release];
    [super dealloc];
}

#pragma mark -
//  ---------------------------------------------------------------------------
//      application:didFinishLaunchingWithOptions
//  ---------------------------------------------------------------------------
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.viewController = [[WISTSampleViewController alloc] initWithNibName:@"WISTSampleViewController" bundle:nil];
    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];
    return YES;
}

//  ---------------------------------------------------------------------------
//      applicationWillTerminate
//  ---------------------------------------------------------------------------
- (void)applicationWillTerminate:(UIApplication *)application
{
    [viewController disconnectWist];
}



@end
