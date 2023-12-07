//
//  LCScheduler.h
//  paas
//
//  Created by Summer on 13-8-22.
//  Copyright (c) 2013年 LeanCloud. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface LCScheduler : NSObject

@property (nonatomic, assign) NSInteger queryCacheExpiredDays;
@property (nonatomic, assign) NSInteger fileCacheExpiredDays;

+ (LCScheduler *)sharedInstance;

@end
