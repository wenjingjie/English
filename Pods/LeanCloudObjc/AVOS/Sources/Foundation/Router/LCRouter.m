//
//  LCRouter.m
//  LeanCloud
//
//  Created by Tang Tianyong on 5/9/16.
//  Copyright © 2016 LeanCloud Inc. All rights reserved.
//

#import "LCRouter_Internal.h"
#import "LCApplication_Internal.h"
#import "LCUtils.h"
#import "LCErrorUtils.h"
#import "LCPaasClient.h"
#import "LCPersistenceUtils.h"
#import "LCLogger.h"

RouterCacheKey const RouterCacheKeyApp = @"RouterCacheDataApp";
RouterCacheKey const RouterCacheKeyRTM = @"RouterCacheDataRTM";
static RouterCacheKey RouterCacheKeyData = @"data";
static RouterCacheKey RouterCacheKeyTimestamp = @"timestamp";

static NSString *serverURLString;
/// { 'module key' : 'URL' }
static NSMutableDictionary<NSString *, NSString *> *customAppServerTable;

@implementation LCRouter

+ (NSString *)serverURLString {
    return serverURLString;
}

+ (void)setServerURLString:(NSString *)URLString {
    serverURLString = [URLString copy];
}

+ (instancetype)sharedInstance
{
    static LCRouter *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LCRouter alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        self->_lock = [NSLock new];
        
        NSMutableDictionary *(^ loadCacheToMemoryBlock)(NSString *) = ^NSMutableDictionary *(NSString *key) {
            NSString *filePath = [[LCRouter routerCacheDirectoryPath] stringByAppendingPathComponent:key];
            BOOL isDirectory;
            if ([[NSFileManager defaultManager] fileExistsAtPath:filePath isDirectory:&isDirectory] && !isDirectory) {
                NSData *data = [NSData dataWithContentsOfFile:filePath];
                if ([data length]) {
                    NSError *error = nil;
                    NSMutableDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
                    if (error || ![NSMutableDictionary _lc_isTypeOf:dictionary]) {
                        if (!error) { error = LCErrorInternalServer([NSString stringWithFormat:@"file: %@ is invalid.", filePath]); }
                        LCLoggerError(LCLoggerDomainDefault, @"%@", error);
                    } else {
                        return dictionary;
                    }
                }
            }
            return [NSMutableDictionary dictionary];
        };
        self->_appRouterMap = loadCacheToMemoryBlock(RouterCacheKeyApp);
        self->_RTMRouterMap = loadCacheToMemoryBlock(RouterCacheKeyRTM);
        
        self->_isUpdatingAppRouter = false;
        self->_RTMRouterCallbacksMap = [NSMutableDictionary dictionary];
        
        self->_keyToModule = ({
            @{ RouterKeyAppAPIServer : AppModuleAPI,
               RouterKeyAppEngineServer : AppModuleEngine,
               RouterKeyAppPushServer : AppModulePush,
               RouterKeyAppRTMRouterServer : AppModuleRTMRouter,
               RouterKeyAppStatsServer : AppModuleStats };
        });
    }
    return self;
}

// MARK: - API Version

+ (NSString *)APIVersion
{
    return @"1.1";
}

static NSString * pathWithVersion(NSString *path)
{
    NSString *version = [LCRouter APIVersion];
    if ([path hasPrefix:[@"/" stringByAppendingPathComponent:version]]) {
        return path;
    } else if ([path hasPrefix:version]) {
        return [@"/" stringByAppendingPathComponent:path];
    } else {
        return [[@"/" stringByAppendingPathComponent:version] stringByAppendingPathComponent:path];
    }
}

// MARK: - RTM Router Path

+ (NSString *)RTMRouterPath
{
    return @"/v1/route";
}

// MARK: - Disk Cache

+ (NSString *)routerCacheDirectoryPath
{
    return [LCPersistenceUtils homeDirectoryLibraryCachesLeanCloudCachesRouter];
}

static void cachingRouterData(NSDictionary *routerDataMap, RouterCacheKey key)
{
#if DEBUG
    assert(routerDataMap);
    assert(key);
#endif
    NSData *data = ({
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:routerDataMap options:0 error:&error];
        if (error || ![data length]) {
            if (!error) { error = LCErrorInternalServer(@"data invalid."); }
            LCLoggerError(LCLoggerDomainDefault, @"%@", error);
            return;
        }
        data;
    });
    NSString *filePath = ({
        NSString *routerCacheDirectoryPath = [LCRouter routerCacheDirectoryPath];
        BOOL isDirectory;
        BOOL isExists = [[NSFileManager defaultManager] fileExistsAtPath:routerCacheDirectoryPath isDirectory:&isDirectory];
        if (!isExists) {
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:routerCacheDirectoryPath withIntermediateDirectories:true attributes:nil error:&error];
            if (error) {
                LCLoggerError(LCLoggerDomainDefault, @"%@", error);
                return;
            }
        } else if (isExists && !isDirectory) {
            LCLoggerError(LCLoggerDomainDefault, @"%@", LCErrorInternalServer(@"can't create directory for router."));
            return;
        }
        [routerCacheDirectoryPath stringByAppendingPathComponent:key];
    });
    [data writeToFile:filePath atomically:true];
}

- (BOOL)cleanCacheWithKey:(RouterCacheKey)key
                    error:(NSError * __autoreleasing *)error
{
    NSParameterAssert(key);
    BOOL result = false;
    NSString *filePath = [[LCRouter routerCacheDirectoryPath] stringByAppendingPathComponent:key];
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        result = [[NSFileManager defaultManager] removeItemAtPath:filePath error:error];
    }
    return result;
}

- (BOOL)cleanCacheWithApplication:(LCApplication *)application
                              key:(RouterCacheKey)key
                            error:(NSError * __autoreleasing *)error
{
    NSString *appID = [application identifierThrowException];
    if (key == RouterCacheKeyApp) {
        [self->_lock lock];
        [self->_appRouterMap removeObjectForKey:appID];
        [self->_lock unlock];
    } else if (key == RouterCacheKeyRTM) {
        [self->_lock lock];
        [self->_RTMRouterMap removeObjectForKey:appID];
        [self->_lock unlock];
    }
    return [self cleanCacheWithKey:key error:error];
}

// MARK: - App Router

- (void)getAppRouterDataWithAppID:(NSString *)appID callback:(void (^)(NSDictionary *dataDictionary, NSError *error))callback
{
    NSParameterAssert(appID);
    [[LCPaasClient sharedInstance] getObject:AppRouterURLString withParameters:@{@"appId":appID} block:^(id _Nullable object, NSError * _Nullable error) {
        if (error) {
            callback(nil, error);
        } else {
            NSDictionary *dictionary = (NSDictionary *)object;
            if ([NSDictionary _lc_isTypeOf:dictionary]) {
                callback(dictionary, nil);
            } else {
                callback(nil, LCErrorInternalServer(@"response data invalid."));
            }
        }
    }];
}

- (void)tryUpdateAppRouterWithAppID:(NSString *)appID callback:(void (^)(NSError *error))callback
{
    NSParameterAssert(appID);
    if (self.isUpdatingAppRouter) {
        return;
    }
    self.isUpdatingAppRouter = true;
    [self getAppRouterDataWithAppID:appID callback:^(NSDictionary *dataDictionary, NSError *error) {
        if (error) { LCLoggerError(LCLoggerDomainDefault, @"%@", error); }
        if (dataDictionary) {
            NSDictionary *routerDataTuple = ({
                @{ RouterCacheKeyData : dataDictionary,
                   RouterCacheKeyTimestamp : @(NSDate.date.timeIntervalSince1970) };
            });
            NSDictionary *appRouterMapCopy = nil;
            [self->_lock lock];
            self->_appRouterMap[appID] = routerDataTuple;
            appRouterMapCopy = [self->_appRouterMap copy];
            [self->_lock unlock];
            cachingRouterData(appRouterMapCopy, RouterCacheKeyApp);
        }
        self.isUpdatingAppRouter = false;
        if (callback) { callback(error); }
    }];
}

- (NSString *)appURLForPath:(NSString *)path appID:(NSString *)appID
{
    NSParameterAssert(path);
    NSParameterAssert(appID);
    
    RouterKey serverKey = serverKeyForPath(path);
    
    NSString *(^constructedURL)(NSString *) = ^NSString *(NSString *host) {
        if ([serverKey isEqualToString:RouterKeyAppRTMRouterServer]) {
            return absoluteURLStringWithHostAndPath(host, path);
        } else {
            return absoluteURLStringWithHostAndPath(host, pathWithVersion(path));
        }
    };
    
    ({  /// get server URL from custom server table.
        NSString *customServerURL = [NSString _lc_decoding:customAppServerTable key:serverKey];
        if ([customServerURL length]) {
            return constructedURL(customServerURL);
        }
    });
    
    if ([LCRouter serverURLString].length) {
        return constructedURL([LCRouter serverURLString]);
    }
    
    if ([appID hasSuffix:AppIDSuffixUS]) {
        NSDictionary *appRouterDataTuple = nil;
        [self->_lock lock];
        appRouterDataTuple = [NSDictionary _lc_decoding:self->_appRouterMap key:appID];
        [self->_lock unlock];
        if (shouldUpdateRouterData(appRouterDataTuple)) {
            [self tryUpdateAppRouterWithAppID:appID callback:nil];
        }
        NSDictionary *dataDic = [NSDictionary _lc_decoding:appRouterDataTuple key:RouterCacheKeyData];
        NSString *serverURL = [NSString _lc_decoding:dataDic key:serverKey];
        if ([serverURL length]) {
            return constructedURL(serverURL);
        } else {
            NSString *fallbackServerURL = [self appRouterFallbackURLWithKey:serverKey appID:appID];
            return constructedURL(fallbackServerURL);
        }
    }
    
    return nil;
}

+ (NSString *)appDomainForAppID:(NSString *)appID
{
    NSString *appDomain;
    if ([appID hasSuffix:AppIDSuffixCN]) {
        appDomain = AppDomainCN;
    } else if ([appID hasSuffix:AppIDSuffixCE]) {
        appDomain = AppDomainCE;
    } else if ([appID hasSuffix:AppIDSuffixUS]) {
        appDomain = AppDomainUS;
    } else {
        appDomain = AppDomainCN;
    }
    return appDomain;
}

- (NSString *)appRouterFallbackURLWithKey:(NSString *)key appID:(NSString *)appID
{
    NSParameterAssert(key);
    NSParameterAssert(appID);
    return [NSString stringWithFormat:@"%@.%@.%@",
            [[appID substringToIndex:8] lowercaseString],
            self->_keyToModule[key],
            [LCRouter appDomainForAppID:appID]];
}

// MARK: - RTM Router

- (NSString *)RTMRouterURLForAppID:(NSString *)appID
{
    NSParameterAssert(appID);
    return [self appURLForPath:[LCRouter RTMRouterPath] appID:appID];
}

- (void)getRTMRouterDataWithAppID:(NSString *)appID RTMRouterURL:(NSString *)RTMRouterURL callback:(void (^)(NSDictionary *dataDictionary, NSError *error))callback
{
    NSParameterAssert(appID);
    NSParameterAssert(RTMRouterURL);
    LCPaasClient *paasClient = [LCPaasClient sharedInstance];
    NSURLRequest *request = [paasClient requestWithPath:RTMRouterURL
                                                 method:@"GET"
                                                headers:nil
                                             parameters:@{
                                                 @"appId": appID,
                                                 @"secure": @"1",
                                             }];
    [paasClient performRequest:request success:^(NSHTTPURLResponse *response, id responseObject) {
        if ([NSDictionary _lc_isTypeOf:responseObject]) {
            callback(responseObject, nil);
        } else {
            callback(nil, LCError(LCErrorInternalErrorCodeMalformedData,
                                  @"Response data is malformed.",
                                  @{ @"data": (responseObject ?: @"nil") }));
        }
    } failure:^(NSHTTPURLResponse *response, id responseObject, NSError *error) {
        callback(nil, error);
    }];
}

- (void)getAndCacheRTMRouterDataWithAppID:(NSString *)appID RTMRouterURL:(NSString *)RTMRouterURL callback:(void (^)(NSDictionary *dataDictionary, NSError *error))callback
{
    NSParameterAssert(appID);
    NSParameterAssert(RTMRouterURL);
    [self getRTMRouterDataWithAppID:appID RTMRouterURL:RTMRouterURL callback:^(NSDictionary *dataDictionary, NSError *error) {
        if (error) {
            callback(nil, error);
            return;
        }
        NSDictionary *routerDataTuple = ({
            @{ RouterCacheKeyData : dataDictionary,
               RouterCacheKeyTimestamp : @(NSDate.date.timeIntervalSince1970) };
        });
        NSDictionary *RTMRouterMapCopy = nil;
        [self->_lock lock];
        self->_RTMRouterMap[appID] = routerDataTuple;
        RTMRouterMapCopy = [self->_RTMRouterMap copy];
        [self->_lock unlock];
        cachingRouterData(RTMRouterMapCopy, RouterCacheKeyRTM);
        callback(dataDictionary, nil);
    }];
}

- (void)getRTMURLWithAppID:(NSString *)appID callback:(void (^)(NSDictionary *dictionary, NSError *error))callback
{
    NSParameterAssert(appID);
    
    /// get RTM router URL & try update app router
    NSString *RTMRouterURL = [self RTMRouterURLForAppID:appID];
    if (!RTMRouterURL) {
        callback(nil, LCError(9973, @"RTM Router URL not found.", nil));
        return;
    }
    
    ({  /// add callback to map
        BOOL addCallbacksToArray = false;
        [self->_lock lock];
        NSMutableArray<void (^)(NSDictionary *, NSError *)> *callbacks = self->_RTMRouterCallbacksMap[appID];
        if (callbacks) {
            [callbacks addObject:callback];
            addCallbacksToArray = true;
        } else {
            callbacks = [NSMutableArray arrayWithObject:callback];
            self->_RTMRouterCallbacksMap[appID] = callbacks;
        }
        [self->_lock unlock];
        if (addCallbacksToArray) {
            return;
        }
    });
    
    void(^invokeCallbacks)(NSDictionary *, NSError *) = ^(NSDictionary *data, NSError *error) {
        NSMutableArray<void (^)(NSDictionary *, NSError *)> *callbacks = nil;
        [self->_lock lock];
        callbacks = self->_RTMRouterCallbacksMap[appID];
        [self->_RTMRouterCallbacksMap removeObjectForKey:appID];
        [self->_lock unlock];
        for (void (^block)(NSDictionary *, NSError *) in callbacks) {
            block(data, error);
        }
    };
    
    ({  /// get RTM URL data from memory
        NSDictionary *RTMRouterDataTuple = nil;
        [self->_lock lock];
        RTMRouterDataTuple = [NSDictionary _lc_decoding:self->_RTMRouterMap key:appID];
        [self->_lock unlock];
        if (!shouldUpdateRouterData(RTMRouterDataTuple)) {
            NSDictionary *dataDic = [NSDictionary _lc_decoding:RTMRouterDataTuple key:RouterCacheKeyData];
            invokeCallbacks(dataDic, nil);
            return;
        }
    });
    
    [self getAndCacheRTMRouterDataWithAppID:appID RTMRouterURL:RTMRouterURL callback:^(NSDictionary *dataDictionary, NSError *error) {
        invokeCallbacks(dataDictionary, error);
    }];
}

// MARK: - Batch Path

- (NSString *)batchPathForPath:(NSString *)path
{
    NSParameterAssert(path);
    return pathWithVersion(path);
}

// MARK: - Custom App URL

+ (void)customAppServerURL:(NSString *)URLString key:(RouterKey)key
{
    if (!customAppServerTable) {
        customAppServerTable = [NSMutableDictionary dictionary];
    }
    if (!key) { return; }
    if (URLString) {
        customAppServerTable[key] = URLString;
    } else {
        [customAppServerTable removeObjectForKey:key];
    }
}

// MARK: - Misc

static BOOL shouldUpdateRouterData(NSDictionary *routerDataTuple)
{
    if (!routerDataTuple) {
        return true;
    }
    NSDictionary *dataDic = [NSDictionary _lc_decoding:routerDataTuple key:RouterCacheKeyData];
    NSTimeInterval lastTimestamp = [[NSNumber _lc_decoding:routerDataTuple key:RouterCacheKeyTimestamp] doubleValue];
    if (!dataDic) {
        return true;
    }
    NSTimeInterval ttl = [[NSNumber _lc_decoding:dataDic key:RouterKeyTTL] doubleValue];
    NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
    if (currentTimestamp >= lastTimestamp && currentTimestamp <= (lastTimestamp + ttl)) {
        return false;
    } else {
        return true;
    }
}

static RouterKey serverKeyForPath(NSString *path)
{
#if DEBUG
    assert(path);
#endif
    if ([path hasPrefix:@"call"] || [path hasPrefix:@"functions"]) {
        return RouterKeyAppEngineServer;
    } else if ([path hasPrefix:@"push"] || [path hasPrefix:@"installations"]) {
        return RouterKeyAppPushServer;
    } else if ([path hasPrefix:@"stats"] || [path hasPrefix:@"statistics"] || [path hasPrefix:@"always_collect"]) {
        return RouterKeyAppStatsServer;
    } else if ([path isEqualToString:[LCRouter RTMRouterPath]]) {
        return RouterKeyAppRTMRouterServer;
    } else {
        return RouterKeyAppAPIServer;
    }
}

static NSString * absoluteURLStringWithHostAndPath(NSString *host, NSString *path)
{
#if DEBUG
    assert(host);
    assert(path);
#endif
    NSString *unifiedHost = ({
        NSString *unifiedHost = nil;
        /// For "example.com:8080", the scheme is "example.com". Here, we need a farther check.
        NSURL *URL = [NSURL URLWithString:host];
        if (URL.scheme && [host hasPrefix:[URL.scheme stringByAppendingString:@"://"]]) {
            unifiedHost = host;
        } else {
            unifiedHost = [@"https://" stringByAppendingString:host];
        }
        unifiedHost;
    });
    
    NSURLComponents *URLComponents = ({
        NSURLComponents *URLComponents = [[NSURLComponents alloc] initWithString:unifiedHost];
        if ([path length]) {
            NSString *pathString = nil;
            if ([URLComponents.path length]) {
                pathString = [URLComponents.path stringByAppendingPathComponent:path];
            } else {
                pathString = path;
            }
            NSURL *pathURL = [NSURL URLWithString:pathString];
            URLComponents.path = pathURL.path;
            URLComponents.query = pathURL.query;
            URLComponents.fragment = pathURL.fragment;
        }
        URLComponents;
    });
    
    return [[URLComponents URL] absoluteString];
}

@end
