//
//  LCCaptcha.m
//  LeanCloud
//
//  Created by Tang Tianyong on 03/05/2017.
//  Copyright © 2017 LeanCloud Inc. All rights reserved.
//

#import "LCCaptcha.h"
#import "LCDynamicObject_Internal.h"
#import "NSDictionary+LeanCloud.h"
#import "LCPaasClient.h"
#import "LCUtils.h"

@implementation LCCaptchaDigest

@dynamic nonce;
@dynamic URLString;

@end

@implementation LCCaptchaRequestOptions

@dynamic width;
@dynamic height;

@end

@implementation LCCaptcha

+ (void)requestCaptchaWithOptions:(LCCaptchaRequestOptions *)options
                         callback:(LCCaptchaRequestCallback)callback
{
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];

    parameters[@"width"]  = options[@"width"];
    parameters[@"height"] = options[@"height"];

    [[LCPaasClient sharedInstance] getObject:@"requestCaptcha" withParameters:parameters block:^(id object, NSError *error) {
        if (error) {
            [LCUtils callIdResultBlock:callback object:nil error:error];
            return;
        }

        NSDictionary *dictionary = [object lc_selectEntriesWithKeyMappings:@{
            @"captcha_token" : @"nonce",
            @"captcha_url"   : @"URLString"
        }];

        LCCaptchaDigest *captchaDigest = [[LCCaptchaDigest alloc] initWithDictionary:dictionary];

        [LCUtils callIdResultBlock:callback object:captchaDigest error:nil];
    }];
}

+ (void)verifyCaptchaCode:(NSString *)captchaCode
         forCaptchaDigest:(LCCaptchaDigest *)captchaDigest
                 callback:(LCCaptchaVerificationCallback)callback
{
    NSParameterAssert(captchaCode);
    NSParameterAssert(captchaDigest);

    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];

    parameters[@"captcha_code"]  = captchaCode;
    parameters[@"captcha_token"] = captchaDigest.nonce;

    [[LCPaasClient sharedInstance] postObject:@"verifyCaptcha" withParameters:parameters block:^(id object, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(nil, error);
            });
            return;
        }
        NSString *validationToken = object[@"validate_token"];
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(validationToken, nil);
        });
    }];
}

@end
