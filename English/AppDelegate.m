//
//  AppDelegate.m
//  English
//
//  Created by wangshengfeng on 2023/12/7.
//

#import "AppDelegate.h"

#import "MainViewController.h"

@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    [self.window makeKeyAndVisible];
    
    
    MainViewController *main = MainViewController.new;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:main];
    self.window .rootViewController = nav;
    
     
    
    
    
    
    return YES;
}




@end
