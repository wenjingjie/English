//
//  MainModel.m
//  English
//
//  Created by wangshengfeng on 2023/12/7.
//

#import "MainModel.h"

#import <MJExtension.h>

@implementation MainModel


+(NSDictionary *)mj_objectClassInArray
{
    return @{
        @"data":MainDataModel.class,
    };
}


@end

@implementation MainDataModel

@end
