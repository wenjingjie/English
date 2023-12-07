//
//  LCStatus.m
//  paas
//
//  Created by Travis on 13-12-23.
//  Copyright (c) 2013年 LeanCloud. All rights reserved.
//

#import "LCStatus.h"
#import "LCPaasClient.h"
#import "LCErrorUtils.h"
#import "LCObjectUtils.h"
#import "LCObject_Internal.h"
#import "LCQuery_Internal.h"
#import "LCUtils.h"
#import "LCUser_Internal.h"

NSString * const kLCStatusTypeTimeline=@"default";
NSString * const kLCStatusTypePrivateMessage=@"private";

@interface LCStatus () {
    
}
@property (nonatomic,   copy) NSString *objectId;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, assign) NSUInteger messageId;

/* 用Query来设定受众群 */
@property(nonatomic,strong) LCQuery *targetQuery;

+(NSString*)parseClassName;

+(LCStatus*)statusFromCloudData:(NSDictionary*)data;

@end

@implementation LCQuery (Status)

-(NSDictionary*)dictionaryForStatusRequest{
    NSMutableDictionary *dict=[[self assembleParameters] mutableCopy];
    [dict setObject:self.className forKey:@"className"];
    
    //`where` here is a string, but the server ask for dictionary
    [dict removeObjectForKey:@"where"];
    [dict setObject:[LCObjectUtils dictionaryFromDictionary:self.where] forKey:@"where"];
    return dict;
}
@end


@interface LCStatusQuery ()
@property(nonatomic,copy) NSString *externalQueryPath;
@end

@implementation LCStatusQuery

- (id)init
{
    self = [super initWithClassName:[LCStatus parseClassName]];
    if (self) {
        
    }
    return self;
}

- (NSString *)queryPath {
    return self.externalQueryPath?self.externalQueryPath:[super queryPath];
}


- (NSMutableDictionary *)assembleParameters {
    BOOL handleInboxType=NO;
    if (self.inboxType) {
        if (self.externalQueryPath) {
            handleInboxType=YES;
        } else {
            [self whereKey:@"inboxType" equalTo:self.inboxType];
        }
        
    }
    [super assembleParameters];
    
    if (self.sinceId > 0)
    {
        [self.parameters setObject:@(self.sinceId) forKey:@"sinceId"];
    }
    if (self.maxId > 0)
    {
        [self.parameters setObject:@(self.maxId) forKey:@"maxId"];
    }
    
    if (self.owner) {
        [self.parameters setObject:[LCObjectUtils dictionaryFromObjectPointer:self.owner] forKey:@"owner"];
    }
    
    if (handleInboxType) {
        [self.parameters setObject:self.inboxType forKey:@"inboxType"];
    }
    
    return self.parameters;
}

-(void)queryWithBlock:(NSString *)path
           parameters:(NSDictionary *)parameters
                block:(LCArrayResultBlock)resultBlock {
    _end = NO;
    [super queryWithBlock:path parameters:parameters block:resultBlock];
}

- (LCObject *)getFirstObjectWithBlock:(LCObjectResultBlock)resultBlock
                        waitUntilDone:(BOOL)wait
                                error:(NSError **)theError {
    _end = NO;
    return [super getFirstObjectWithBlock:resultBlock waitUntilDone:wait error:theError];
}

// only called in findobjects, these object's data is ready
- (NSMutableArray *)processResults:(NSArray *)results className:(NSString *)className
{
    
    NSMutableArray *statuses=[NSMutableArray arrayWithCapacity:[results count]];
    
    for (NSDictionary *info in results) {
        [statuses addObject:[LCStatus statusFromCloudData:info]];
    }
    [statuses sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"messageId" ascending:NO]]];
    return statuses;
}

- (void)processEnd:(BOOL)end {
    _end = end;
}
@end



@implementation LCStatus

+(NSString*)parseClassName{
    return @"_Status";
}

+ (NSString *)statusInboxPath {
    return @"subscribe/statuses/inbox";
}

+(LCStatus*)statusFromCloudData:(NSDictionary*)data{
    if ([data isKindOfClass:[NSDictionary class]] && data[@"objectId"]) {
        LCStatus *status=[[LCStatus alloc] init];
        
        status.objectId=data[@"objectId"];
        status.type=data[@"inboxType"];
        status.createdAt = [LCDate dateFromValue:data[@"createdAt"]];
        status.messageId=[data[@"messageId"] integerValue];
        status.source=[LCObjectUtils lcObjectFromDictionary:data[@"source"]];
        
        NSMutableDictionary *newData=[data mutableCopy];
        [newData removeObjectsForKeys:@[@"inboxType",@"objectId",@"createdAt",@"updatedAt",@"messageId",@"source"]];
        
        status.data=newData;
        return status;
    }
    
    return nil;
}

+(NSError*)permissionCheck{
    if (![[LCUser currentUser] isAuthDataExistInMemory]) {
        return LCError(kLCErrorUserCannotBeAlteredWithoutSession, nil, nil);
    }
    
    return nil;
}

+(NSString*)stringOfStatusOwner:(NSString*)userObjectId{
    if (userObjectId) {
        NSString *info=[NSString stringWithFormat:@"{\"__type\":\"Pointer\", \"className\":\"_User\", \"objectId\":\"%@\"}",userObjectId];
        return info;
    }
    return nil;
}


#pragma mark - 查询


+(LCStatusQuery*)inboxQuery:(LCStatusType *)inboxType{
    LCStatusQuery *query=[[LCStatusQuery alloc] init];
    query.owner=[LCUser currentUser];
    query.inboxType=inboxType;
    query.externalQueryPath= @"subscribe/statuses";
    return query;
}


+(LCStatusQuery*)statusQuery{
    LCStatusQuery *q=[[LCStatusQuery alloc] init];
    [q whereKey:@"source" equalTo:[LCUser currentUser]];
    return q;
}

+(void)getStatusWithID:(NSString *)objectId andCallback:(LCStatusResultBlock)callback{
    NSError *error=[self permissionCheck];
    if (error) {
        callback(nil,error);
        return;
    }
    
    NSString *owner=[LCStatus stringOfStatusOwner:[LCUser currentUser].objectId];
    [[LCPaasClient sharedInstance] getObject:[NSString stringWithFormat:@"statuses/%@",objectId] withParameters:@{@"owner":owner,@"include":@"source"} block:^(id object, NSError *error) {
        
        if (!error) {
            
            object = [self statusFromCloudData:object];
        }
        
        [LCUtils callIdResultBlock:callback object:object error:error];
    }];
}

+(void)deleteStatusWithID:(NSString *)objectId andCallback:(LCBooleanResultBlock)callback{
    NSError *error=[self permissionCheck];
    if (error) {
        callback(NO,error);
        return;
    }
    
    NSString *owner=[LCStatus stringOfStatusOwner:[LCUser currentUser].objectId];
    [[LCPaasClient sharedInstance] deleteObject:[NSString stringWithFormat:@"statuses/%@",objectId] withParameters:@{@"owner":owner} block:^(id object, NSError *error) {
        
        [LCUtils callBooleanResultBlock:callback error:error];
    }];
}

+ (BOOL)deleteInboxStatusForMessageId:(NSUInteger)messageId inboxType:(NSString *)inboxType receiver:(NSString *)receiver error:(NSError *__autoreleasing *)error {
    if (!receiver) {
        if (error) *error = LCErrorInternalServer(@"Receiver of status can not be nil.");
        return NO;
    }

    if (!inboxType) {
        if (error) *error = LCErrorInternalServer(@"Inbox type of status can not be nil.");
        return NO;
    }

    NSDictionary *parameters = @{
        @"messageId" : [NSString stringWithFormat:@"%lu", (unsigned long)messageId],
        @"owner"     : [LCObjectUtils dictionaryFromObjectPointer:[LCUser objectWithoutDataWithObjectId:receiver]],
        @"inboxType" : inboxType
    };

    __block NSError *responseError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    [[LCPaasClient sharedInstance] deleteObject:[self statusInboxPath] withParameters:parameters block:^(id object, NSError *error) {
        responseError = error;
        dispatch_semaphore_signal(sema);
    }];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    if (error) {
        *error = responseError;
    }

    return responseError == nil;
}

+ (void)deleteInboxStatusInBackgroundForMessageId:(NSUInteger)messageId inboxType:(NSString *)inboxType receiver:(NSString *)receiver block:(LCBooleanResultBlock)block {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        [self deleteInboxStatusForMessageId:messageId inboxType:inboxType receiver:receiver error:&error];
        [LCUtils callBooleanResultBlock:block error:error];
    });
}

+(void)getUnreadStatusesCountWithType:(LCStatusType*)type andCallback:(LCIntegerResultBlock)callback{
    NSError *error=[self permissionCheck];

    if (error) {
        [LCUtils callIntegerResultBlock:callback number:0 error:error];
        return;
    }
    
    NSString *owner=[LCStatus stringOfStatusOwner:[LCUser currentUser].objectId];
    
    [[LCPaasClient sharedInstance] getObject:@"subscribe/statuses/count" withParameters:@{@"owner":owner,@"inboxType":type} block:^(id object, NSError *error) {
        NSUInteger count=[object[@"unread"] integerValue];
        [LCUtils callIntegerResultBlock:callback number:count error:error];
    }];
}

+ (void)resetUnreadStatusesCountWithType:(LCStatusType *)type andCallback:(LCBooleanResultBlock)callback {
    NSError *error = [self permissionCheck];

    if (error) {
        [LCUtils callBooleanResultBlock:callback error:error];
        return;
    }

    NSString *owner = [LCStatus stringOfStatusOwner:[LCUser currentUser].objectId];

    [[LCPaasClient sharedInstance] postObject:@"subscribe/statuses/resetUnreadCount" withParameters:@{@"owner": owner, @"inboxType": type} block:^(id object, NSError *error) {
        [LCUtils callBooleanResultBlock:callback error:error];
    }];
}

+(void)sendStatusToFollowers:(LCStatus*)status andCallback:(LCBooleanResultBlock)callback{
    NSError *error=[self permissionCheck];
    if (error) {
        callback(NO,error);
        return;
    }
    status.source=[LCUser currentUser];
    status.targetQuery=[LCUser followerQuery:[LCUser currentUser].objectId];
    [status sendInBackgroundWithBlock:callback];
}

+(void)sendPrivateStatus:(LCStatus *)status toUserWithID:(NSString *)userId andCallback:(LCBooleanResultBlock)callback{
    NSError *error=[self permissionCheck];
    if (error) {
        callback(NO,error);
        return;
    }
    status.source=[LCUser currentUser];
    [status setType:kLCStatusTypePrivateMessage];
    
    LCQuery *q=[LCUser query];
    [q whereKey:@"objectId" equalTo:userId];
    
    status.targetQuery=q;
    [status sendInBackgroundWithBlock:callback];
}

-(void)setQuery:(LCQuery*)query{
    self.targetQuery=query;
}

-(NSError *)preSave
{
    NSParameterAssert(self.data);
    
    if ([self objectId]) {
        return LCError(kLCErrorOperationForbidden, @"status can't be update", nil);
    }
    
    if ([LCUser currentUser]==nil) {
        return LCError(kLCErrorOperationForbidden, @"do NOT have an current user, please login first", nil);
    }
    
    if (self.source==nil) {
        self.source=[LCUser currentUser];
    }
    
    if (self.targetQuery==nil) {
        self.targetQuery=[LCUser followerQuery:[LCUser currentUser].objectId];
    }
    
    if (self.type==nil) {
        [self setType:kLCStatusTypeTimeline];
    }

    return nil;
}

-(void)sendInBackgroundWithBlock:(LCBooleanResultBlock)block{
    NSError *error=[self preSave];
    if (error) {
        block(NO,error);
        return;
    }
    
    NSMutableDictionary *body=[NSMutableDictionary dictionary];
    
    NSMutableDictionary *data=[self.data mutableCopy];
    [data setObject:self.source forKey:@"source"];
    
    [body setObject:[LCObjectUtils dictionaryFromDictionary:data] forKey:@"data"];
    
    
    NSDictionary *queryInfo=[self.targetQuery dictionaryForStatusRequest];
    
    [body setObject:queryInfo forKey:@"query"];
    [body setObject:self.type forKey:@"inboxType"];

    LCPaasClient *client = [LCPaasClient sharedInstance];
    NSURLRequest *request = [client requestWithPath:@"statuses" method:@"POST" headers:nil parameters:body];

    [client
     performRequest:request
     success:^(NSHTTPURLResponse *response, id responseObject) {
         if ([responseObject isKindOfClass:[NSDictionary class]]) {
             NSString *objectId = responseObject[@"objectId"];

             if (objectId) {
                 self.objectId = objectId;
                 self.createdAt = [LCDate dateFromValue:responseObject[@"createdAt"]];
                 [LCUtils callBooleanResultBlock:block error:nil];
                 return;
             }
         }

         [LCUtils callBooleanResultBlock:block error:LCError(kLCErrorInvalidJSON, @"unexpected result return", nil)];
     }
     failure:^(NSHTTPURLResponse *response, id responseObject, NSError *error) {
         [LCUtils callBooleanResultBlock:block error:error];
     }];
}

-(NSString*)debugDescription{
    if (self.messageId>0) {
        return [[super debugDescription] stringByAppendingFormat:@" <id: %@,messageId:%lu type: %@, createdAt:%@, source:%@(%@)>: %@",self.objectId,(unsigned long)self.messageId,self.type,self.createdAt,NSStringFromClass([self.source class]), [self.source objectId],[self.data debugDescription]];
    }
    return [[super debugDescription] stringByAppendingFormat:@" <id: %@, type: %@, createdAt:%@, source:%@(%@)>: %@",self.objectId,self.type,self.createdAt,NSStringFromClass([self.source class]), [self.source objectId],[self.data debugDescription]];
}

@end

