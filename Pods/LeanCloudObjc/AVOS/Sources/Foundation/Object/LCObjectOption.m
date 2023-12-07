//
//  LCSaveOption.m
//  LeanCloud
//
//  Created by Tang Tianyong on 1/12/16.
//  Copyright © 2016 LeanCloud Inc. All rights reserved.
//

#import "LCObjectOption.h"
#import "LCObjectOption_Internal.h"
#import "LCQuery.h"
#import "LCQuery_Internal.h"

@implementation LCSaveOption

- (NSDictionary *)dictionary {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    if (self.fetchWhenSave)
        result[@"fetchWhenSave"] = @(YES);

    if (self.query)
        result[@"where"] = [self.query whereJSONDictionary];

    return result;
}

@end

@implementation LCObjectFetchOption

@end
