
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>

#import "LCFile_Internal.h"
#import "LCFileTaskManager.h"
#import "LCPaasClient.h"
#import "LCUtils_Internal.h"
#import "LCNetworking.h"
#import "LCErrorUtils.h"
#import "LCPersistenceUtils.h"
#import "LCObjectUtils.h"
#import "LCACL_Internal.h"
#import "LCUser_Internal.h"
#import "LCFileQuery.h"
#import "LCLogger.h"

static NSString * LCFile_CustomPersistentCacheDirectory = nil;

static NSString * LCFile_PersistentCacheDirectory()
{
    return LCFile_CustomPersistentCacheDirectory ?: [LCPersistenceUtils homeDirectoryLibraryCachesLeanCloudCachesFiles];
}

static NSString * LCFile_CompactUUID()
{
    return [LCUtils generateCompactUUID];
}

static NSString * LCFile_ObjectPath(NSString *objectId)
{
    return (objectId && objectId.length > 0) ? [@"classes/_file" stringByAppendingPathComponent:objectId] : nil;
}

@implementation LCFile {
    
    NSLock *_lock;
    
    NSMutableDictionary *_rawJSONData;
    
    NSData *_data;
    
    NSString *_localPath;
    
    NSString *_pathExtension;
    
    LCACL *_ACL;
    
    NSDictionary<NSString *, NSString *> *_uploadingHeaders;
    
    NSURLSessionUploadTask *_uploadTask;
    
    NSNumber *_uploadOption;
    
    NSURLSessionDownloadTask *_downloadTask;
}

+ (NSString *)className
{
    return @"File";
}

// MARK: - Create File

+ (instancetype)fileWithData:(NSData *)data
{
    return [[LCFile alloc] initWithData:data name:nil];
}

+ (instancetype)fileWithData:(NSData *)data name:(NSString *)name
{
    return [[LCFile alloc] initWithData:data name:name];
}

+ (instancetype)fileWithLocalPath:(NSString *)localPath
                            error:(NSError * __autoreleasing *)error
{
    return [[LCFile alloc] initWithLocalPath:localPath error:error];
}

+ (instancetype)fileWithRemoteURL:(NSURL *)remoteURL
{
    return [[LCFile alloc] initWithRemoteURL:remoteURL];
}

+ (instancetype)fileWithObject:(LCObject *)object
{
    return [[LCFile alloc] initWithRawJSONData:[object dictionaryForObject]];
}

+ (instancetype)fileWithObjectId:(NSString *)objectId url:(NSString *)url
{
    return [[LCFile alloc] initWithRawJSONData:@{kLCFile_objectId: objectId, kLCFile_url: url}.mutableCopy];
}

// MARK: - Initialization

- (instancetype)init
{
    self = [super init];
    
    if (self) {
        
        _lock = [[NSLock alloc] init];
        
        _rawJSONData = [NSMutableDictionary dictionary];
    }
    
    return self;
}

- (instancetype)initWithData:(NSData *)data
                        name:(NSString *)name
{
    self = [self init];
    
    if (self) {
        
        _data = data;
        
        _pathExtension = name.pathExtension;
        
        _rawJSONData[kLCFile_name] = (name && name.length > 0) ? name : LCFile_CompactUUID();
        
        _rawJSONData[kLCFile_mime_type] = ({
            
            NSString *mimeType = nil;
            if (name && name.length > 0) {
                mimeType = [LCUtils MIMEType:name];
            }
            if (!mimeType && data.length > 0) {
                mimeType = [LCUtils contentTypeForImageData:data];
            }
            mimeType ?: @"application/octet-stream";
        });
        
        _rawJSONData[kLCFile_metaData] = @{ kLCFile_size : @(data.length) };
        
        _ACL = ({
            
            LCACL *acl = LCPaasClient.sharedInstance.updatedDefaultACL;
            if (acl) {
                _rawJSONData[ACLTag] = [LCObjectUtils dictionaryFromACL:acl];
            }
            acl;
        });
    }
    
    return self;
}

- (instancetype)initWithLocalPath:(NSString *)localPath
                            error:(NSError * __autoreleasing *)error
{
    NSDictionary *fileAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:localPath error:error];
    
    if (!fileAttributes) {
        
        return nil;
    }
    
    self = [self init];
    
    if (self) {
        
        _localPath = localPath;
        
        _pathExtension = localPath.pathExtension;
        
        NSString *name = ({
            
            NSString *lastPathComponent = localPath.lastPathComponent;
            (lastPathComponent && lastPathComponent.length > 0) ? lastPathComponent : LCFile_CompactUUID();
        });
        
        _rawJSONData[kLCFile_name] = name;
        
        _rawJSONData[kLCFile_mime_type] = ({
            
            NSString *mimeType = nil;
            if (name && name.length > 0) {
                mimeType = [LCUtils MIMEType:name];
            }
            if (!mimeType && localPath.length > 0) {
                mimeType = [LCUtils MIMETypeFromPath:localPath];
            }
            mimeType ?: @"application/octet-stream";
        });
        
        NSNumber *fileSize = fileAttributes[NSFileSize];
        _rawJSONData[kLCFile_metaData] = (fileSize != nil) ? @{ kLCFile_size : fileSize } : @{};
        
        _ACL = ({
            
            LCACL *acl = [LCPaasClient sharedInstance].updatedDefaultACL;
            if (acl) {
                _rawJSONData[ACLTag] = [LCObjectUtils dictionaryFromACL:acl];
            }
            acl;
        });
    }
    
    return self;
}

- (instancetype)initWithRemoteURL:(NSURL *)remoteURL
{
    self = [self init];
    
    if (self) {
        
        _pathExtension = remoteURL.pathExtension;
        
        NSString *absoluteString = remoteURL.absoluteString;
        
        _rawJSONData[kLCFile_url] = absoluteString;
        
        _rawJSONData[kLCFile_name] = ({
            
            NSString *lastPathComponent = remoteURL.lastPathComponent;
            (lastPathComponent && lastPathComponent.length > 0) ? lastPathComponent : LCFile_CompactUUID();
        });
        
        _rawJSONData[kLCFile_mime_type] = ({
            
            NSString *mimeType = nil;
            if (absoluteString && absoluteString.length > 0) {
                mimeType = [LCUtils MIMEType:absoluteString];
            }
            mimeType ?: @"application/octet-stream";
        });
        
        _rawJSONData[kLCFile_metaData] = @{ @"__source" : @"external" };
        
        _ACL = ({
            
            LCACL *acl = [LCPaasClient sharedInstance].updatedDefaultACL;
            if (acl) {
                _rawJSONData[ACLTag] = [LCObjectUtils dictionaryFromACL:acl];
            }
            acl;
        });
    }
    
    return self;
}

- (instancetype)initWithRawJSONData:(NSMutableDictionary *)rawJSONData
{
    self = [self init];
    
    if (self) {
        
        _rawJSONData = rawJSONData;
        
        _pathExtension = ({
            
            NSString *pathExtension = [[NSString _lc_decoding:_rawJSONData key:kLCFile_name] pathExtension];
            if (!pathExtension) {
                pathExtension = [[NSString _lc_decoding:_rawJSONData key:kLCFile_url] pathExtension];
            }
            pathExtension;
        });
        
        _ACL = LCPaasClient.sharedInstance.updatedDefaultACL;
    }
    
    return self;
}

// MARK: - NSCoding

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [self init];
    
    if (self) {
        
        NSDictionary *dic = [aDecoder decodeObjectForKey:@"dictionary"];
        
        if (dic) {
            
            _rawJSONData = dic.mutableCopy;
            
            _pathExtension = ({
                
                NSString *pathExtension = [[NSString _lc_decoding:_rawJSONData key:kLCFile_name] pathExtension];
                if (!pathExtension) {
                    pathExtension = [[NSString _lc_decoding:_rawJSONData key:kLCFile_url] pathExtension];
                }
                pathExtension;
            });
            
            _ACL = LCPaasClient.sharedInstance.updatedDefaultACL;
        }
    }
    
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    NSMutableDictionary *dic = [_rawJSONData mutableCopy];
    [dic setObject:@"File" forKey:@"__type"];
    [aCoder encodeObject:dic forKey:@"dictionary"];
}

// MARK: - Lock

- (void)internalSyncLock:(void (^)(void))block
{
    [_lock lock];
    block();
    [_lock unlock];
}

// MARK: - Property

- (LCACL *)ACL
{
    __block LCACL *ACL = nil;
    
    [self internalSyncLock:^{
        
        ACL = self->_ACL;
    }];
    
    return ACL;
}

- (void)setACL:(LCACL *)ACL
{
    NSDictionary *ACLDic = [LCObjectUtils dictionaryFromACL:ACL];
    
    [self internalSyncLock:^{
        
        self->_ACL = ACL;
        
        if (ACL) {
            
            self->_rawJSONData[ACLTag] = ACLDic;
            
        } else {
            
            [self->_rawJSONData removeObjectForKey:ACLTag];
        }
    }];
}

- (NSDate *)createdAt {
    return [LCDate dateFromValue:self->_rawJSONData[@"createdAt"]];
}

- (NSDate *)updatedAt {
    return [LCDate dateFromValue:self->_rawJSONData[@"updatedAt"]];
}

- (NSDictionary<NSString *,NSString *> *)uploadingHeaders
{
    __block NSDictionary<NSString *,NSString *> *dic = nil;
    
    [self internalSyncLock:^{
        
        dic = self->_uploadingHeaders;
    }];
    
    return dic;
}

- (void)setUploadingHeaders:(NSDictionary<NSString *,NSString *> *)uploadingHeaders
{
    [self internalSyncLock:^{
        
        self->_uploadingHeaders = [uploadingHeaders copy];
    }];
}

- (NSString *)objectId {
    __block NSString *objectId;
    [self internalSyncLock:^{
        objectId = [LCFile decodingObjectIdFromDic:self->_rawJSONData];
    }];
    return objectId;
}

- (NSString *)name {
    __block NSString *name;
    [self internalSyncLock:^{
        name = [NSString _lc_decoding:self->_rawJSONData key:kLCFile_name];
    }];
    return name;
}

- (void)setName:(NSString *)name {
    [self internalSyncLock:^{
        self->_rawJSONData[kLCFile_name] = name;
    }];
}

- (NSString *)url {
    __block NSString *url;
    [self internalSyncLock:^{
        url = [NSString _lc_decoding:self->_rawJSONData key:kLCFile_url];
    }];
    return url;
}

- (NSDictionary *)metaData {
    __block NSDictionary *metaData;
    [self internalSyncLock:^{
        metaData = [NSDictionary _lc_decoding:self->_rawJSONData key:kLCFile_metaData];
    }];
    return metaData;
}

- (void)setMetaData:(NSDictionary *)metaData {
    [self internalSyncLock:^{
        self->_rawJSONData[kLCFile_metaData] = metaData;
    }];
}

- (NSString *)mimeType {
    __block NSString *mimeType;
    [self internalSyncLock:^{
        mimeType = [NSString _lc_decoding:self->_rawJSONData key:kLCFile_mime_type];
    }];
    return mimeType;
}

- (void)setMimeType:(NSString *)mimeType {
    [self internalSyncLock:^{
        self->_rawJSONData[kLCFile_mime_type] = mimeType;
    }];
}

- (id)objectForKey:(id)key
{
    __block id value = nil;
    
    [self internalSyncLock:^{
        
        value = [self->_rawJSONData objectForKey:key];
    }];
    
    return value;
}

- (NSDictionary *)rawJSONDataCopy
{
    __block NSDictionary *dic = nil;
    
    [self internalSyncLock:^{
        
        dic = self->_rawJSONData.copy;
    }];
    
    return dic;
}

- (NSMutableDictionary *)rawJSONDataMutableCopy
{
    __block NSMutableDictionary *dic = nil;
    
    [self internalSyncLock:^{
        
        dic = self->_rawJSONData.mutableCopy;
    }];
    
    return dic;
}

// MARK: - Upload

- (void)uploadWithCompletionHandler:(void (^)(BOOL, NSError * _Nullable))completionHandler
{
    [self uploadWithOption:LCFileUploadOptionCachingData
                  progress:nil
         completionHandler:completionHandler];
}

- (void)uploadWithProgress:(void (^)(NSInteger))uploadProgressBlock
         completionHandler:(void (^)(BOOL, NSError * _Nullable))completionHandler
{
    [self uploadWithOption:LCFileUploadOptionCachingData
                  progress:uploadProgressBlock
         completionHandler:completionHandler];
}

- (void)uploadWithOption:(LCFileUploadOption)uploadOption
                progress:(void (^)(NSInteger))uploadProgressBlock
       completionHandler:(void (^)(BOOL, NSError * _Nullable))completionHandler
{
    if (self.objectId) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (uploadProgressBlock) {
                uploadProgressBlock(100);
            }
            completionHandler(true, nil);
        });
        
        return;
    }
    
    BOOL isUploading = ({
        
        __block BOOL isUploading = false;
        [self internalSyncLock:^{
            if (self->_uploadOption != nil) {
                isUploading = true;
            } else {
                self->_uploadOption = @(uploadOption);
            }
        }];
        isUploading;
    });
    
    if (isUploading) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(false, ({
                NSString *reason = @"File is in uploading, Can't do repeated upload operation.";
                LCErrorInternalServer(reason);
            }));
        });
        
        return;
    }
    
    // _data & _localPath only set in initialization, so no need lock.
    if (self->_data || self->_localPath) {
        
        NSData *data = _data;
        NSString *localPath = _localPath;
        
        void (^progress)(NSInteger) = uploadProgressBlock ? ^(NSInteger number) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                uploadProgressBlock(number);
            });
            
        } : nil;
        
        [self uploadLocalDataWithData:data localPath:localPath progress:progress completionHandler:^(BOOL succeeded, NSError *error) {
            
            LCFileUploadOption uploadOption = ({
                
                __block LCFileUploadOption uploadOption = 0;
                [self internalSyncLock:^{
                    uploadOption = [self->_uploadOption unsignedIntegerValue];
                    self->_uploadOption = nil;
                }];
                uploadOption;
            });
            
            if (succeeded && !(uploadOption & LCFileUploadOptionIgnoringCachingData)) {
                
                NSString *persistenceCachePath = ({
                    
                    NSError *error = nil;
                    NSString *path = [self persistentCachePathThrowError:&error];
                    if (error) {
                        LCLoggerError(LCLoggerDomainStorage, @"%@", error);
                    }
                    path;
                });
                
                if (persistenceCachePath) {
                    
                    BOOL isPathCleared = ({
                        
                        NSError *error = nil;
                        if ([NSFileManager.defaultManager fileExistsAtPath:persistenceCachePath]) {
                            [NSFileManager.defaultManager removeItemAtPath:persistenceCachePath error:&error];
                            if (error) {
                                LCLoggerError(LCLoggerDomainStorage, @"%@", error);
                            }
                        }
                        error ? false : true;
                    });
                    
                    
                    if (isPathCleared) {
                        
                        NSError *cachingError = ({
                            
                            NSError *error = nil;
                            if (data) {
                                [data writeToFile:persistenceCachePath atomically:true];
                            }
                            else if (localPath) {
                                [[NSFileManager defaultManager] copyItemAtPath:localPath
                                                                        toPath:persistenceCachePath
                                                                         error:&error];
                            }
                            error;
                        });
                        
                        if (cachingError) {
                            
                            LCLoggerError(LCLoggerDomainStorage, @"%@", cachingError);
                        }
                    }
                }
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(succeeded, error);
            });
        }];
        
        return;
    }
    
    if (self.url) {
        
        [self uploadRemoteURLWithCompletionHandler:^(BOOL succeeded, NSError *error) {
            
            [self internalSyncLock:^{
                self->_uploadOption = nil;
            }];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (uploadProgressBlock && succeeded) {
                    uploadProgressBlock(100);
                }
                completionHandler(succeeded, error);
            });
        }];
        
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        [self internalSyncLock:^{
            self->_uploadOption = nil;
        }];
        
        completionHandler(false, ({
            NSString *reason = @"No data or URL to Upload.";
            LCErrorInternalServer(reason);
        }));
    });
}

- (void)uploadLocalDataWithData:(NSData *)data
                      localPath:(NSString *)localPath
                       progress:(void (^)(NSInteger number))uploadProgressBlock
              completionHandler:(void (^)(BOOL succeeded, NSError *error))completionHandler
{
    NSMutableDictionary *parameters = [self rawJSONDataMutableCopy];
    [parameters removeObjectsForKeys:@[@"__type", @"className"]];
    [self getFileTokensWithParameters:parameters callback:^(LCFileTokens *fileTokens, NSError *error) {
        
        if (error) {
            completionHandler(false, error);
            return;
        }
        
        [parameters addEntriesFromDictionary:fileTokens.rawDic];
        
        NSURLSessionUploadTask *task = ({
            
            NSDictionary<NSString *, NSString *> *uploadingHeaders = self.uploadingHeaders;
            
            void (^progress)(NSProgress *) = uploadProgressBlock ? ^(NSProgress *progress) {
                
                CGFloat completedUnitCount = (CGFloat)progress.completedUnitCount;
                CGFloat totalUnitCount = (CGFloat)progress.totalUnitCount;
                NSInteger number = (NSInteger)((completedUnitCount * 100.0) / totalUnitCount);
                uploadProgressBlock(number);
                
            } : nil;
            
            void(^completionHandler_block)(BOOL success, NSError *error) = ^(BOOL success, NSError *error) {
                
                [self internalSyncLock:^{
                    self->_uploadTask = nil;
                }];
                
                void(^fileCallback_block)(BOOL succeeded) = ^(BOOL succeeded) {
                    
                    if (fileTokens && fileTokens.token) {
                        [LCPaasClient.sharedInstance postObject:@"fileCallback"
                                                 withParameters:@{ @"token" : fileTokens.token, @"result" : @(succeeded) }
                                                          block:nil];
                    }
                };
                
                if (error) {
                    fileCallback_block(false);
                    completionHandler(false, error);
                    return;
                }
                
                fileCallback_block(true);
                [self internalSyncLock:^{
                    self->_rawJSONData = parameters;
                }];
                
                completionHandler(true, nil);
            };
            
            NSURLSessionUploadTask *task = nil;
            if (data) {
                task = [LCFileTaskManager.sharedInstance uploadTaskWithData:data
                                                                 fileTokens:fileTokens
                                                             fileParameters:parameters
                                                           uploadingHeaders:uploadingHeaders
                                                                   progress:progress
                                                          completionHandler:completionHandler_block];
            } else {
                task = [LCFileTaskManager.sharedInstance uploadTaskWithLocalPath:localPath
                                                                      fileTokens:fileTokens
                                                                  fileParameters:parameters
                                                                uploadingHeaders:uploadingHeaders
                                                                        progress:progress
                                                               completionHandler:completionHandler_block];
            }
            task;
        });
        
        
        if (task) {
            
            [self internalSyncLock:^{
                self->_uploadTask = task;
            }];
            [task resume];
        }
    }];
}

- (void)uploadRemoteURLWithCompletionHandler:(void (^)(BOOL succeeded, NSError *error))completionHandler
{
    NSMutableDictionary *mutableParameters = ({
        
        __block NSMutableDictionary *mutableDic = nil;
        [self internalSyncLock:^{
            mutableDic = [self->_rawJSONData mutableCopy];
        }];
        mutableDic;
    });
    
    [LCPaasClient.sharedInstance postObject:@"files" withParameters:mutableParameters.copy block:^(id object, NSError *error) {
        
        if (error) {
            completionHandler(false, error);
            return;
        }
        
        if (![NSDictionary _lc_isTypeOf:object]) {
            
            completionHandler(false, ({
                NSString *reason = @"response invalid.";
                LCErrorInternalServer(reason);
            }));
            
            return;
        }
        
        [mutableParameters addEntriesFromDictionary:(NSDictionary *)object];
        [self internalSyncLock:^{
            self->_rawJSONData = mutableParameters;
        }];
        
        completionHandler(true, nil);
    }];
}

- (void)getFileTokensWithParameters:(NSDictionary *)parameters
                           callback:(void (^)(LCFileTokens *fileTokens, NSError *error))callback
{
    NSDictionary *metaData = parameters[@"metaData"];
    NSString *prefix = metaData[@"prefix"];
    if (prefix) {
        parameters = [parameters mutableCopy];
        ((NSMutableDictionary *)parameters)[@"prefix"] = prefix;
    }
    [LCPaasClient.sharedInstance postObject:@"fileTokens" withParameters:parameters block:^(id _Nullable object, NSError * _Nullable error) {
        
        if (error) {
            callback(nil, error);
            return;
        }
        
        NSDictionary *dic = (NSDictionary *)object;
        
        if (![NSDictionary _lc_isTypeOf:dic]) {
            callback(nil, ({
                NSString *reason = @"fileTokens response invalid.";
                LCErrorInternalServer(reason);
            }));
            return;
        }
        
        LCFileTokens *fileTokens = [[LCFileTokens alloc] initWithDic:dic];
        
        callback(fileTokens, nil);
    }];
}

// MARK: - Download

- (void)downloadWithCompletionHandler:(void (^)(NSURL * _Nullable, NSError * _Nullable))completionHandler
{
    [self downloadWithOption:LCFileDownloadOptionCachedData
                    progress:nil
           completionHandler:completionHandler];
}

- (void)downloadWithProgress:(void (^)(NSInteger))downloadProgressBlock
           completionHandler:(void (^)(NSURL * _Nullable, NSError * _Nullable))completionHandler
{
    [self downloadWithOption:LCFileDownloadOptionCachedData
                    progress:downloadProgressBlock
           completionHandler:completionHandler];
}

- (void)downloadWithOption:(LCFileDownloadOption)downloadOption
                  progress:(void (^)(NSInteger))downloadProgressBlock
         completionHandler:(void (^)(NSURL * _Nullable, NSError * _Nullable))completionHandler
{
    NSURLSessionDownloadTask *downloadTask = ({
        
        __block NSURLSessionDownloadTask *task = nil;
        [self internalSyncLock:^{
            task = self->_downloadTask;
        }];
        task;
    });
    
    if (downloadTask) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(nil, ({
                NSString *reason = @"File is in downloading, Can't do repeated download operation.";
                LCErrorInternalServer(reason);
            }));
        });
        
        return;
    }
    
    NSString *URLString = self.url;
    
    if (!URLString || URLString.length == 0) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(nil, ({
                NSString *reason = @"url is invalid.";
                LCErrorInternalServer(reason);
            }));
        });
        
        return;
    }
    
    NSError *pathError = nil;
    
    NSString *permanentLocationPath = [self persistentCachePathThrowError:&pathError];
    
    if (pathError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(nil, pathError);
        });
        return;
    }
    
    if (!(downloadOption & LCFileDownloadOptionIgnoringCachedData)) {
        
        if ([NSFileManager.defaultManager fileExistsAtPath:permanentLocationPath]) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (downloadProgressBlock) {
                    downloadProgressBlock(100);
                }
                completionHandler([NSURL fileURLWithPath:permanentLocationPath], nil);
            });
            
            return;
        }
    }
    
    NSURLSessionDownloadTask *task = ({
        
        void(^progress)(NSProgress *) = (downloadProgressBlock ? ^(NSProgress *progress) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                CGFloat completedUnitCount = (CGFloat)progress.completedUnitCount;
                CGFloat totalUnitCount = (CGFloat)progress.totalUnitCount;
                NSInteger number = (NSInteger)((completedUnitCount * 100.0) / totalUnitCount);
                downloadProgressBlock(number);
            });
            
        } : nil);
        
        [LCFileTaskManager.sharedInstance downloadTaskWithURLString:URLString destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
            
            BOOL isPathCleared = ({
                
                BOOL isPathCleared = true;
                if ([NSFileManager.defaultManager fileExistsAtPath:permanentLocationPath]) {
                    NSError *error = nil;
                    [NSFileManager.defaultManager removeItemAtPath:permanentLocationPath
                                                             error:&error];
                    if (error) {
                        LCLoggerError(LCLoggerDomainStorage, @"%@", error);
                        isPathCleared = false;
                    }
                }
                isPathCleared;
            });
            
            return (isPathCleared ? [NSURL fileURLWithPath:permanentLocationPath] : targetPath);
            
        } progress:progress completionHandler:^(NSURL *filePath, NSError *error) {
            
            [self internalSyncLock:^{
                self->_downloadTask = nil;
            }];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(filePath, error);
            });
        }];
    });
    
    if (task) {
        [self internalSyncLock:^{
            self->_downloadTask = task;
        }];
        [task resume];
    }
}

// MARK: - Cancel

- (void)cancelUploading
{
    [self internalSyncLock:^{
        if (self->_uploadTask) {
            [self->_uploadTask cancel];
            self->_uploadTask = nil;
        }
        self->_uploadOption = nil;
    }];
}

- (void)cancelDownloading
{
    [self internalSyncLock:^{
        if (self->_downloadTask) {
            [self->_downloadTask cancel];
            self->_downloadTask = nil;
        }
    }];
}

// MARK: - Persistence Cache

+ (void)setCustomPersistentCacheDirectory:(NSString *)directory
{
    LCFile_CustomPersistentCacheDirectory = directory;
}

- (void)clearPersistentCache
{
    NSString *cachePath = self.persistentCachePath;
    if (!cachePath) {
        return;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:cachePath]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:cachePath
                                                   error:&error];
        if (error) {
            LCLoggerError(LCLoggerDomainStorage, @"Error: %@", error);
        }
    }
}

+ (void)clearAllPersistentCache
{
    NSString *directoryPath = LCFile_PersistentCacheDirectory();
    if (!directoryPath) {
        return;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:directoryPath]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:directoryPath
                                                   error:&error];
        if (error) {
            LCLoggerError(LCLoggerDomainStorage, @"Error: %@", error);
        }
    }
}

- (NSString *)persistentCachePath
{
    NSError *error = nil;
    NSString *persistentCachePath = [self persistentCachePathThrowError:&error];
    if (error) {
        LCLoggerError(LCLoggerDomainStorage, @"%@", error);
    }
    return persistentCachePath;
}

- (NSString *)persistentCachePathThrowError:(NSError * __autoreleasing *)error
{
    NSString *objectId = self.objectId;
    
    if (!objectId) {
        if (error) {
            *error = ({
                NSString *reason = @"objectId invalid.";
                LCErrorInternalServer(reason);
            });
        }
        return nil;
    }
    
    NSString *directory = LCFile_PersistentCacheDirectory();
    
    NSError *createFailError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:true
                                             attributes:nil
                                                  error:&createFailError];
    if (createFailError) {
        if (error) {
            *error = createFailError;
        }
        return nil;
    }
    
    NSString *persistentCachePath = ({
        
        NSString *persistentCachePath = [directory stringByAppendingPathComponent:objectId];
        if (_pathExtension) {
            persistentCachePath = [persistentCachePath stringByAppendingPathExtension:_pathExtension];
        }
        persistentCachePath;
    });
    
    return persistentCachePath;
}

// MARK: - Delete

- (void)deleteWithCompletionHandler:(void (^)(BOOL, NSError * _Nullable))completionHandler
{
    NSString *objectPath = LCFile_ObjectPath([self objectId]);
    
    if (!objectPath) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            NSError *aError = ({
                NSString *reason = @"`objectId` is invalid.";
                LCErrorInternalServer(reason);
            });
            
            completionHandler(false, aError);
        });
        
        return;
    }
    
    [[LCPaasClient sharedInstance] deleteObject:objectPath withParameters:nil block:^(id _Nullable object, NSError * _Nullable error) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            BOOL succeeded = error ? false : true;
            
            completionHandler(succeeded, error);
        });
    }];
}

+ (void)deleteWithFiles:(NSArray<LCFile *> *)files
      completionHandler:(void (^)(BOOL, NSError * _Nullable))completionHandler
{
    if (!files || files.count == 0) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            completionHandler(true, nil);
        });
        
        return;
    }
    
    NSMutableArray *requests = [NSMutableArray array];
    
    for (LCFile *file in files) {
        
        NSString *objectId = [file objectId];
        
        if (!objectId || objectId.length == 0) {
            
            continue;
        }
        
        NSString *objectPath = [@"files" stringByAppendingPathComponent:objectId];
        
        NSMutableDictionary *request = [LCPaasClient batchMethod:@"DELETE"
                                                            path:objectPath
                                                            body:nil
                                                      parameters:nil];
        
        [requests addObject:request];
    }
    
    [[LCPaasClient sharedInstance] postBatchObject:requests block:^(NSArray * _Nullable objects, NSError * _Nullable error) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            BOOL succeeded = error ? false : true;
            
            completionHandler(succeeded, error);
        });
    }];
}

// MARK: - Get

+ (void)getFileWithObjectId:(NSString *)objectId
          completionHandler:(void (^)(LCFile *file, NSError *error))completionHandler
{
    NSString *objectPath = LCFile_ObjectPath(objectId);
    
    if (!objectPath) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            NSError *aError = ({
                NSString *reason = @"`objectId` is invalid.";
                LCErrorInternalServer(reason);
            });
            
            completionHandler(nil, aError);
        });
        
        return;
    }
    
    [[LCPaasClient sharedInstance] getObject:objectPath withParameters:nil block:^(id object, NSError* error) {
        
        if (error) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                completionHandler(nil, error);
            });
            
            return;
        }
        
        if (![NSDictionary _lc_isTypeOf:object]) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                NSError *aError = ({
                    NSString *reason = @"Get an invalid Object.";
                    LCErrorInternalServer(reason);
                });
                
                completionHandler(nil, aError);
            });
            
            return;
        }
        
        NSDictionary *dic = (NSDictionary *)object;
        
        LCFile *file = [[LCFile alloc] initWithRawJSONData:dic.mutableCopy];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            completionHandler(file, nil);
        });
    }];
}

// MARK: - Thumbnail

- (NSString *)getThumbnailURLWithScaleToFit:(BOOL)scaleToFit
                                      width:(int)width
                                     height:(int)height
                                    quality:(int)quality
                                     format:(NSString *)format
{
    if (!self.url)
        return nil;
    
    if (width < 0) {
        [NSException raise:NSInvalidArgumentException format:@"Invalid thumbnail width."];
    }
    
    if (height < 0) {
        [NSException raise:NSInvalidArgumentException format:@"Invalid thumbnail height."];
    }
    
    if (quality < 1 || quality > 100) {
        [NSException raise:NSInvalidArgumentException format:@"Invalid quality, valid range is 1 - 100."];
    }
    
    int mode = scaleToFit ? 2 : 1;
    
    NSString *url = [NSString stringWithFormat:@"%@?imageView/%d/w/%d/h/%d/q/%d", self.url, mode, width, height, quality];
    
    format = [format stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if ([format length]) {
        url = [NSString stringWithFormat:@"%@/format/%@", url, format];
    }
    
    return url;
}

- (NSString *)getThumbnailURLWithScaleToFit:(BOOL)scaleToFit
                                      width:(int)width
                                     height:(int)height
{
    return [self getThumbnailURLWithScaleToFit:scaleToFit width:width height:height quality:100 format:nil];
}

- (void)getThumbnail:(BOOL)scaleToFit
               width:(int)width
              height:(int)height
           withBlock:(LCIdResultBlock)block
{
    NSString *url = [self getThumbnailURLWithScaleToFit:scaleToFit width:width height:height];
    
    [[LCFileTaskManager sharedInstance] getThumbnailWithURLString:url completionHandler:^(id thumbnail, NSError *error) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            block(thumbnail, error);
        });
    }];
}

// MARK: - Query

+ (LCQuery *)query
{
    return [LCFileQuery query];
}

// MARK: - Code for Compatibility

+ (NSString *)decodingObjectIdFromDic:(NSDictionary *)dic
{
    /* @note For compatibility, should decoding multiple keys ... ... */
    
    NSString *value = [NSString _lc_decoding:dic key:kLCFile_objectId];
    
    if (value) { return value; }
    
    value = [NSString _lc_decoding:dic key:kLCFile_objId];
    
    if (value) { return value; }
    
    value = [NSString _lc_decoding:dic key:kLCFile_id];
    
    return value;
}

// MARK: Compatibility

- (void)saveInBackgroundWithBlock:(void (^)(BOOL, NSError * _Nullable))block
{
    [self uploadWithCompletionHandler:block];
}

- (void)saveInBackgroundWithBlock:(void (^)(BOOL, NSError * _Nullable))block
                    progressBlock:(void (^)(NSInteger))progressBlock
{
    [self uploadWithProgress:progressBlock completionHandler:block];
}

- (void)setPathPrefix:(NSString *)prefix {
    if ([NSString _lc_isTypeOf:prefix] &&
        prefix.length != 0) {
        NSMutableDictionary *metaData = [self.metaData mutableCopy] ?: [NSMutableDictionary dictionary];
        metaData[@"prefix"] = prefix;
        self.metaData = metaData;
    }
}

- (void)clearPathPrefix {
    NSMutableDictionary *metaData = [self.metaData mutableCopy];
    if (metaData) {
        [metaData removeObjectForKey:@"prefix"];
        self.metaData = metaData;
    }
}

@end

@implementation LCFileTokens

@synthesize provider = _provider;
@synthesize objectId = _objectId;
@synthesize token = _token;
@synthesize bucket = _bucket;
@synthesize url = _url;
@synthesize uploadUrl = _uploadUrl;

- (instancetype)initWithDic:(NSDictionary *)dic
{
    self = [super init];
    
    if (self) {
        
        _rawDic = dic;
    }
    
    return self;
}

- (NSString *)provider
{
    if (_provider) {
        
        return _provider;
        
    } else {
        
        _provider = [NSString _lc_decoding:_rawDic key:@"provider"];
        
        return _provider;
    }
}

- (NSString *)objectId
{
    if (_objectId) {
        
        return _objectId;
        
    } else {
        
        _objectId = [NSString _lc_decoding:_rawDic key:@"objectId"];
        
        return _objectId;
    }
}

- (NSString *)token
{
    if (_token) {
        
        return _token;
        
    } else {
        
        _token = [NSString _lc_decoding:_rawDic key:@"token"];
        
        return _token;
    }
}

- (NSString *)bucket
{
    /* unused, maybe can delete. */
    
    if (_bucket) {
        
        return _bucket;
        
    } else {
        
        _bucket = [NSString _lc_decoding:_rawDic key:@"bucket"];
        
        return _bucket;
    }
}

- (NSString *)url
{
    if (_url) {
        
        return _url;
        
    } else {
        
        _url = [NSString _lc_decoding:_rawDic key:@"url"];
        
        return _url;
    }
}

- (NSString *)uploadUrl
{
    if (_uploadUrl) {
        
        return _uploadUrl;
        
    } else {
        
        _uploadUrl = [NSString _lc_decoding:_rawDic key:@"upload_url"];
        
        return _uploadUrl;
    }
}

@end
