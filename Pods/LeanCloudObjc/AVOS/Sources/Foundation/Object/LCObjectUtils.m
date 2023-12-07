//
//  LCObjectUtils.m
//  LeanCloud
//
//  Created by Zhu Zeng on 7/4/13.
//  Copyright (c) 2013 LeanCloud. All rights reserved.
//

#import <objc/runtime.h>
#import "LCObjectUtils.h"
#import "LCObject_Internal.h"
#import "LCFile.h"
#import "LCFile_Internal.h"
#import "LCObjectUtils.h"
#import "LCUser_Internal.h"
#import "LCACL_Internal.h"
#import "LCRelation.h"
#import "LCRole_Internal.h"
#import "LCInstallation_Internal.h"
#import "LCPaasClient.h"
#import "LCGeoPoint_Internal.h"
#import "LCRelation_Internal.h"
#import "LCUtils.h"
#import "LCFriendship.h"
#import "LCHelpers.h"

@implementation LCDate

+ (NSDateFormatter *)iso8601DateFormatter {
    static NSDateFormatter *dateFormatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        dateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
        dateFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return dateFormatter;
}

+ (NSString *)stringFromDate:(NSDate *)date {
    return [[self iso8601DateFormatter] stringFromDate:date];
}

+ (NSDictionary *)dictionaryFromDate:(NSDate *)date {
    return @{
        @"__type": @"Date",
        @"iso": [self stringFromDate:date],
    };
}

+ (NSDate *)dateFromString:(NSString *)string {
    return [[self iso8601DateFormatter] dateFromString:string];
}

+ (NSDate *)dateFromDictionary:(NSDictionary *)dictionary {
    NSString *iso8601String = [NSString _lc_decoding:dictionary key:@"iso"];
    if (iso8601String) {
        return [self dateFromString:iso8601String];
    } else {
        return nil;
    }
}

+ (NSDate *)dateFromValue:(id)value {
    if ([NSString _lc_isTypeOf:value]) {
        return [self dateFromString:value];
    } else if ([NSDictionary _lc_isTypeOf:value]) {
        return [self dateFromDictionary:value];
    } else {
        return nil;
    }
}

@end

@implementation LCObjectUtils

// MARK: Check Type

+ (BOOL)isRelation:(NSString *)type {
    return [type isEqualToString:@"Relation"];
}

+ (BOOL)isPointer:(NSString *)type {
    return [type isEqualToString:@"Pointer"];
}

+ (BOOL)isGeoPoint:(NSString *)type {
    return [type isEqualToString:@"GeoPoint"];
}

+ (BOOL)isACL:(NSString *)type {
    return [type isEqualToString:@"ACL"];
}

+ (BOOL)isDate:(NSString *)type {
    return [type isEqualToString:@"Date"];
}

+ (BOOL)isData:(NSString *)type {
    return [type isEqualToString:@"Bytes"];
}

+ (BOOL)isFile:(NSString *)type {
    return [type isEqualToString:@"File"];
}

+ (BOOL)isPointerDictionary:(NSDictionary *)dictionary {
    NSString *type = [dictionary objectForKey:@"__type"];
    if ([type isKindOfClass:[NSString class]]) {
        return [self isPointer:type];
    } else {
        return false;
    }
}

+ (BOOL)isFilePointer:(NSDictionary *)dictionary {
    NSString *className = [dictionary objectForKey:@"className"];
    if ([className isKindOfClass:[NSString class]]) {
        return [className isEqualToString:@"_File"];
    } else {
        return false;
    }
}

+ (BOOL)isLCObject:(NSDictionary *)dictionary {
    return [[dictionary objectForKey:@"className"] isKindOfClass:[NSString class]];
}

#pragma mark - Simple objecitive-c object from server side dictionary

+(NSData *)dataFromDictionary:(NSDictionary *)dict
{
    NSString * string = [dict valueForKey:@"base64"];
    NSData * data = [NSData _lc_dataFromBase64String:string];
    return data;
}

+(LCGeoPoint *)geoPointFromDictionary:(NSDictionary *)dict
{
    LCGeoPoint * point = [[LCGeoPoint alloc]init];
    point.latitude = [[dict objectForKey:@"latitude"] doubleValue];
    point.longitude = [[dict objectForKey:@"longitude"] doubleValue];
    return point;
}

+(LCACL *)aclFromDictionary:(NSDictionary *)dict
{
    LCACL * acl = [LCACL ACL];
    acl.permissionsById = [dict mutableCopy];
    return acl;
}

+(NSArray *)arrayFromArray:(NSArray *)array
{
    NSMutableArray *newArray = [NSMutableArray arrayWithCapacity:array.count];
    for (id obj in [array copy]) {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            [newArray addObject:[LCObjectUtils objectFromDictionary:obj]];
        } else if ([obj isKindOfClass:[NSArray class]]) {
            NSArray * sub = [LCObjectUtils arrayFromArray:obj];
            [newArray addObject:sub];
        } else {
            [newArray addObject:obj];
        }
    }
    return newArray;
}

+(NSObject *)objectFromDictionary:(NSDictionary *)dict
{
    NSString * type = [dict valueForKey:@"__type"];
    if ([LCObjectUtils isRelation:type])
    {
        return [LCObjectUtils targetObjectFromRelationDictionary:dict];
    }
    else if ([LCObjectUtils isPointer:type] ||
             [LCObjectUtils isLCObject:dict] )
    {
        /*
         the backend stores LCFile as LCObject, but in sdk LCFile is not subclass of LCObject, have to process the situation here.
         */
        if ([LCObjectUtils isFilePointer:dict]) {
            return [[LCFile alloc] initWithRawJSONData:[dict mutableCopy]];
        }
        return [LCObjectUtils lcObjectFromDictionary:dict];
    }
    else if ([LCObjectUtils isFile:type]) {
        return [[LCFile alloc] initWithRawJSONData:[dict mutableCopy]];
    }
    else if ([LCObjectUtils isGeoPoint:type])
    {
        LCGeoPoint * point = [LCObjectUtils geoPointFromDictionary:dict];
        return point;
    }
    else if ([LCObjectUtils isDate:type]) {
        return [LCDate dateFromDictionary:dict];;
    }
    else if ([LCObjectUtils isData:type])
    {
        NSData * data = [LCObjectUtils dataFromDictionary:dict];
        return data;
    }
    return dict;
}

+ (NSObject *)objectFromDictionary:(NSDictionary *)dict recursive:(BOOL)recursive {
    if (recursive) {
        NSMutableDictionary *mutableDict = [dict mutableCopy];
        
        for (NSString *key in [dict allKeys]) {
            id object = dict[key];
            
            if ([object isKindOfClass:[NSDictionary class]]) {
                object = [self objectFromDictionary:object recursive:YES];
                mutableDict[key] = object;
            }
        }
        
        return [self objectFromDictionary:mutableDict];
    } else {
        return [self objectFromDictionary:dict];
    }
}

+(void)copyDictionary:(NSDictionary *)dict
             toTarget:(LCObject *)target
                  key:(NSString *)key
{
    NSString * type = [dict valueForKey:@"__type"];
    if ([LCObjectUtils isRelation:type])
    {
        // 解析 {"__type":"Relation","className":"_User"}，添加第一个来判断类型
        LCObject * object = [LCObjectUtils targetObjectFromRelationDictionary:dict];
        [target addRelation:object forKey:key submit:NO];
    }
    else if ([LCObjectUtils isPointer:type])
    {
        [target setObject:[LCObjectUtils objectFromDictionary:dict] forKey:key submit:NO];
    }
    else if ([LCObjectUtils isLCObject:dict]) {
        [target setObject:[LCObjectUtils objectFromDictionary:dict] forKey:key submit:NO];
    }
    else if ([LCObjectUtils isFile:type]) {
        LCFile *file = [[LCFile alloc] initWithRawJSONData:[dict mutableCopy]];
        [target setObject:file forKey:key submit:false];
    }
    else if ([LCObjectUtils isGeoPoint:type])
    {
        LCGeoPoint * point = [LCGeoPoint geoPointFromDictionary:dict];
        [target setObject:point forKey:key submit:NO];
    }
    else if ([LCObjectUtils isACL:type] ||
             [LCObjectUtils isACL:key])
    {
        [target setObject:[LCObjectUtils aclFromDictionary:dict] forKey:ACLTag submit:NO];
    }
    else if ([LCObjectUtils isDate:type]) {
        [target setObject:[LCDate dateFromDictionary:dict]
                   forKey:key
                   submit:NO];
    }
    else if ([LCObjectUtils isData:type])
    {
        NSData * data = [LCObjectUtils dataFromDictionary:dict];
        [target setObject:data forKey:key submit:NO];
    }
    else
    {
        id object = [self objectFromDictionary:dict recursive:YES];
        [target setObject:object forKey:key submit:NO];
    }
}


/// Add object to lcobject container.
+(void)addObject:(NSObject *)object
              to:(NSObject *)parent
             key:(NSString *)key
      isRelation:(BOOL)isRelation
{
    if ([key hasPrefix:@"_"]) {
        // NSLog(@"Ingore key %@", key);
        return;
    }
    
    if (![parent isKindOfClass:[LCObject class]]) {
        return;
    }
    LCObject * avParent = (LCObject *)parent;
    if ([object isKindOfClass:[LCObject class]]) {
        if (isRelation) {
            [avParent addRelation:(LCObject *)object forKey:key submit:NO];
        } else {
            [avParent setObject:object forKey:key submit:NO];
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for(LCObject * item in [object copy]) {
            [avParent addObject:item forKey:key];
        }
    } else {
        [avParent setObject:object forKey:key submit:NO];
    }
}

+(void)updateObjectProperty:(LCObject *)target
                        key:(NSString *)key
                      value:(NSObject *)value
{
    if ([key isEqualToString:@"createdAt"]) {
        target.createdAt = [LCDate dateFromValue:value];
    } else if ([key isEqualToString:@"updatedAt"]) {
        target.updatedAt = [LCDate dateFromValue:value];
    } else if ([key isEqualToString:ACLTag]) {
        LCACL * acl = [LCObjectUtils aclFromDictionary:(NSDictionary *)value];
        [target setObject:acl forKey:key submit:NO];
    } else {
        if ([value isKindOfClass:[NSDictionary class]]) {
            NSDictionary * valueDict = (NSDictionary *)value;
            [LCObjectUtils copyDictionary:valueDict toTarget:target key:key];
        } else if ([value isKindOfClass:[NSArray class]]) {
            NSArray * array = [LCObjectUtils arrayFromArray:(NSArray *)value];
            [target setObject:array forKey:key submit:NO];
        } else if ([value isEqual:[NSNull null]]) {
            [target removeObjectForKey:key];
        } else {
            [target setObject:value forKey:key submit:NO];
        }
    }
}

+(void)updateSubObjects:(LCObject *)target
                    key:(NSString *)key
                  value:(NSObject *)obj
{
    // additional properties, use setObject
    if ([obj isKindOfClass:[NSDictionary class]])
    {
        [LCObjectUtils copyDictionary:(NSDictionary *)obj toTarget:target key:key];
    }
    else if ([obj isKindOfClass:[NSArray class]])
    {
        NSArray * array = [LCObjectUtils arrayFromArray:(NSArray *)obj];
        [target setObject:array forKey:key submit:NO];
    }
    else
    {
        [target setObject:obj forKey:key submit:NO];
    }
}


#pragma mark - Update Objecitive-c object from server side dictionary
+(void)copyDictionary:(NSDictionary *)src
             toObject:(LCObject *)target
{
    [src enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if ([target respondsToSelector:NSSelectorFromString(key)]) {
            [LCObjectUtils updateObjectProperty:target key:key value:obj];
        } else {
            [LCObjectUtils updateSubObjects:target key:key value:obj];
        }
    }];
}

#pragma mark - Server side dictionary representation of objective-c object.
+ (NSMutableDictionary *)dictionaryFromDictionary:(NSDictionary *)dic {
    return [self dictionaryFromDictionary:dic topObject:NO];
}

/// topObject is for cloud rpc
+ (NSMutableDictionary *)dictionaryFromDictionary:(NSDictionary *)dic topObject:(BOOL)topObject{
    NSMutableDictionary *newDic = [NSMutableDictionary dictionaryWithCapacity:dic.count];
    for (NSString *key in [dic allKeys]) {
        id obj = [dic objectForKey:key];
        [newDic setObject:[LCObjectUtils dictionaryFromObject:obj topObject:topObject] forKey:key];
    }
    return newDic;
}

+ (NSMutableArray *)dictionaryFromArray:(NSArray *)array {
    return [self dictionaryFromArray:array topObject:NO];
}

+ (NSMutableArray *)dictionaryFromArray:(NSArray *)array topObject:(BOOL)topObject
{
    NSMutableArray *newArray = [NSMutableArray arrayWithCapacity:array.count];
    for (id obj in [array copy]) {
        [newArray addObject:[LCObjectUtils dictionaryFromObject:obj topObject:topObject]];
    }
    return newArray;
}

+(NSDictionary *)dictionaryFromObjectPointer:(LCObject *)object
{
    NSMutableDictionary * dict = [[NSMutableDictionary alloc] init];
    [dict setObject:@"Pointer" forKey:@"__type"];
    [dict setObject:[object internalClassName] forKey:classNameTag];
    if ([object hasValidObjectId])
    {
        [dict setObject:object.objectId forKey:@"objectId"];
    }
    return dict;
}

/*
 {
 "cid" : "67c35bc8-4183-4db0-8f5a-0ee2b0baa4d4",
 "className" : "ddd",
 "key" : "myddd"
 }
 */
+(NSDictionary *)childDictionaryFromObject:(LCObject *)object
                                     withKey:(NSString *)key
{
    NSMutableDictionary * dict = [[NSMutableDictionary alloc] init];
    [dict setObject:[object internalClassName] forKey:classNameTag];
    NSString *cid = [object objectId] != nil ? [object objectId] : [object _uuid];
    [dict setObject:cid forKey:@"cid"];
    [dict setObject:key forKey:@"key"];
    return dict;
}

+ (NSSet *)allObjectProperties:(Class)objectClass {
    NSMutableSet *properties = [NSMutableSet set];
    
    [self allObjectProperties:objectClass properties:properties];
    
    return [properties copy];
}

+(void)allObjectProperties:(Class)objectClass
                  properties:(NSMutableSet *)properties {
    unsigned int numberOfProperties = 0;
    objc_property_t *propertyArray = class_copyPropertyList(objectClass, &numberOfProperties);
    for (NSUInteger i = 0; i < numberOfProperties; i++)
    {
        objc_property_t property = propertyArray[i];
        
        char *readonly = property_copyAttributeValue(property, "R");
        
        if (readonly) {
            free(readonly);
            continue;
        }
        
        NSString *key = [[NSString alloc] initWithUTF8String:property_getName(property)];
        [properties addObject:key];
    }
    
    if ([objectClass isSubclassOfClass:[LCObject class]] && objectClass != [LCObject class])
    {
        [LCObjectUtils allObjectProperties:[objectClass superclass] properties:properties];
    }
    free(propertyArray);
}

// generate object json dictionary. For LCObject, we generate the full
// json dictionary instead of pointer only. This function is different
// from dictionaryFromObject which generates pointer json only for LCObject.
+ (id)snapshotDictionary:(id)object {
    return [self snapshotDictionary:object recursive:YES];
}

+ (id)snapshotDictionary:(id)object recursive:(BOOL)recursive {
    if (recursive && [object isKindOfClass:[LCObject class]]) {
        return [LCObjectUtils objectSnapshot:object recursive:recursive];
    } else {
        return [LCObjectUtils dictionaryFromObject:object];
    }
}

+ (NSMutableDictionary *)objectSnapshot:(LCObject *)object {
    return [self objectSnapshot:object recursive:YES];
}

+ (NSMutableDictionary *)objectSnapshot:(LCObject *)object recursive:(BOOL)recursive {
    __block NSDictionary *localDataCopy = nil;
    [object internalSyncLock:^{
        localDataCopy = object._localData.copy;
    }];
    NSArray * objects = @[localDataCopy, object._estimatedData];
    NSMutableDictionary * result = [NSMutableDictionary dictionary];
    [result setObject:@"Object" forKey:kLCTypeTag];
    
    for (NSDictionary *object in objects) {
        NSDictionary *dictionary = [object copy];
        NSArray *keys = [dictionary allKeys];
        
        for(NSString * key in keys) {
            id valueObject = [self snapshotDictionary:dictionary[key] recursive:recursive];
            if (valueObject != nil) {
                [result setObject:valueObject forKey:key];
            }
        }
    }
    
    NSArray * keys = [object._relationData allKeys];
    
    for(NSString * key in keys) {
        NSString * childClassName = [object childClassNameForRelation:key];
        id valueObject = [self dictionaryForRelation:childClassName];
        if (valueObject != nil) {
            [result setObject:valueObject forKey:key];
        }
    }
    
    NSSet *ignoreKeys = [NSSet setWithObjects:
                         @"_localData",
                         @"_relationData",
                         @"_estimatedData",
                         @"_operationQueue",
                         @"_requestManager",
                         @"_inSetter",
                         @"_uuid",
                         @"_submit",
                         @"_hasDataForInitial",
                         @"_hasDataForCloud",
                         @"fetchWhenSave",
                         @"isNew", // from LCUser
                         nil];
    
    NSMutableSet * properties = [NSMutableSet set];
    [self allObjectProperties:[object class] properties:properties];
    
    for (NSString * key in properties) {
        if ([ignoreKeys containsObject:key]) {
            continue;
        }
        id valueObjet = [self snapshotDictionary:[object valueForKey:key] recursive:recursive];
        if (valueObjet != nil) {
            [result setObject:valueObjet forKey:key];
        }
    }
    
    return result;
}

+ (LCObject *)lcObjectForClass:(NSString *)className {
    if (![className isKindOfClass:[NSString class]]) {
        return nil;
    }
    LCObject *object;
    Class classObject = [[LCPaasClient sharedInstance] classFor:className];
    if (classObject && [classObject isSubclassOfClass:[LCObject class]]) {
        if ([classObject respondsToSelector:@selector(object)]) {
            object = [classObject performSelector:@selector(object)];
        }
    } else {
        if ([LCObjectUtils isUserClass:className]) {
            object = [LCUser user];
        } else if ([LCObjectUtils isInstallationClass:className]) {
            object = [LCInstallation installation];
        } else if ([LCObjectUtils isRoleClass:className]) {
            object = [LCRole role];
        } else if ([LCObjectUtils isFriendshipRequestClass:className]) {
            object = [[LCFriendshipRequest alloc] init];
        } else {
            object = [LCObject objectWithClassName:className];
        }
    }
    return object;
}

+ (LCObject *)lcObjectFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *className = [dictionary objectForKey:@"className"];
    if (![className isKindOfClass:[NSString class]]) {
        return nil;
    }
    LCObject *object = [LCObjectUtils lcObjectForClass:className];
    [LCObjectUtils copyDictionary:dictionary toObject:object];
    return object;
}

+ (LCObject *)targetObjectFromRelationDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return [LCObjectUtils lcObjectForClass:[dictionary objectForKey:@"className"]];
}

+(NSDictionary *)dictionaryFromGeoPoint:(LCGeoPoint *)point
{
    return [LCGeoPoint dictionaryFromGeoPoint:point];
}

+(NSDictionary *)dictionaryFromData:(NSData *)data
{
    NSString *base64 = [data _lc_base64EncodedString];
    return @{@"__type": @"Bytes", @"base64":base64};
}

+ (NSDictionary *)dictionaryFromFile:(LCFile *)file {
    NSDictionary *dictionary;
    NSString *objectId = file.objectId;
    if (objectId && objectId.length != 0) {
        dictionary = @{
            @"id" : objectId,
            @"__type" : @"File",
        };
    } else {
        dictionary = [file rawJSONDataMutableCopy];
    }
    return dictionary;
}

+(NSDictionary *)dictionaryFromACL:(LCACL *)acl {
    return [acl.permissionsById copy];
}

+(NSDictionary *)dictionaryFromRelation:(LCRelation *)relation {
    if (relation.targetClass) {
        return [LCObjectUtils dictionaryForRelation:relation.targetClass];
    }
    return nil;
}

+(NSDictionary *)dictionaryForRelation:(NSString *)className {
    return  @{@"__type": @"Relation", @"className":className};
}

// Generate server side dictionary representation of input NSObject
+ (id)dictionaryFromObject:(id)obj {
    return [self dictionaryFromObject:obj topObject:NO];
}

/// topObject means get the top level LCObject with Pointer child if any LCObject. Used for cloud rpc.
+ (id)dictionaryFromObject:(id)obj topObject:(BOOL)topObject
{
    if ([obj isKindOfClass:[NSDictionary class]]) {
        return [LCObjectUtils dictionaryFromDictionary:obj topObject:topObject];
    } else if ([obj isKindOfClass:[NSArray class]]) {
        return [LCObjectUtils dictionaryFromArray:obj topObject:topObject];
    } else if ([obj isKindOfClass:[LCObject class]]) {
        if (topObject) {
            return [LCObjectUtils objectSnapshot:obj recursive:NO];
        } else {
            return [LCObjectUtils dictionaryFromObjectPointer:obj];
        }
    } else if ([obj isKindOfClass:[LCGeoPoint class]]) {
        return [LCObjectUtils dictionaryFromGeoPoint:obj];
    } else if ([obj isKindOfClass:[NSDate class]]) {
        return [LCDate dictionaryFromDate:obj];
    } else if ([obj isKindOfClass:[NSData class]]) {
        return [LCObjectUtils dictionaryFromData:obj];
    } else if ([obj isKindOfClass:[LCFile class]]) {
        return [LCObjectUtils dictionaryFromFile:obj];
    } else if ([obj isKindOfClass:[LCACL class]]) {
        return [LCObjectUtils dictionaryFromACL:obj];
    } else if ([obj isKindOfClass:[LCRelation class]]) {
        return [LCObjectUtils dictionaryFromRelation:obj];
    }
    // string or other?
    return obj;
}

+(void)setupRelation:(LCObject *)parent
      withDictionary:(NSDictionary *)relationMap
{
    for(NSString * key in [relationMap allKeys]) {
        NSArray * array = [relationMap objectForKey:key];
        for(NSDictionary * item in [array copy]) {
            NSObject * object = [LCObjectUtils objectFromDictionary:item];
            if ([object isKindOfClass:[LCObject class]]) {
                [parent addRelation:(LCObject *)object forKey:key submit:NO];
            }
        }
    }
}

// MARK: Batch Request from operation list

+ (BOOL)isUserClass:(NSString *)className {
    return [className isEqualToString:[LCUser userTag]];
}

+ (BOOL)isRoleClass:(NSString *)className {
    return [className isEqualToString:[LCRole className]];
}

+ (BOOL)isFileClass:(NSString *)className {
    return [className isEqualToString:[LCFile className]];
}

+ (BOOL)isInstallationClass:(NSString *)className {
    return [className isEqualToString:[LCInstallation className]];
}

+ (BOOL)isFriendshipRequestClass:(NSString *)className {
    return [className isEqualToString:[LCFriendshipRequest className]];
}

+ (NSString *)classEndPoint:(NSString *)className objectId:(NSString *)objectId {
    if (objectId) {
        return [NSString stringWithFormat:@"classes/%@/%@", className, objectId];
    } else {
        return [NSString stringWithFormat:@"classes/%@", className];
    }
}

+ (NSString *)userObjectPath:(NSString *)objectId {
    if (objectId) {
        return [NSString stringWithFormat:@"%@/%@", [LCUser endPoint], objectId];
    } else {
        return [LCUser endPoint];
    }
}

+ (NSString *)roleObjectPath:(NSString *)objectId {
    if (objectId) {
        return [NSString stringWithFormat:@"%@/%@", [LCRole endPoint], objectId];
    } else {
        return [LCRole endPoint];
    }
}

+ (NSString *)installationObjectPath:(NSString *)objectId {
    if (objectId) {
        return [NSString stringWithFormat:@"%@/%@", [LCInstallation endPoint], objectId];
    } else {
        return [LCInstallation endPoint];
    }
}

+ (NSString *)objectPath:(NSString *)className objectId:(NSString *)objectId {
    if ([self isUserClass:className]) {
        return [self userObjectPath:objectId];
    } else if ([self isRoleClass:className]) {
        return [self roleObjectPath:objectId];
    } else if ([self isInstallationClass:className]) {
        return [self installationObjectPath:objectId];
    }
    return [self classEndPoint:className objectId:objectId];
}

+(NSString *)batchPath {
    return @"batch";
}

+(NSString *)batchSavePath
{
    return @"batch/save";
}

+(BOOL)safeAdd:(NSDictionary *)dict
       toArray:(NSMutableArray *)array
{
    if (dict != nil) {
        [array addObject:dict];
        return YES;
    }
    return NO;
}

+(BOOL)hasAnyKeys:(id)object {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary * dict = (NSDictionary *)object;
        return ([dict count] > 0);
    }
    return NO;
}

@end
