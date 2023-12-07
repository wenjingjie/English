// LCQuery.m
// Copyright 2013 LeanCloud, Inc. All rights reserved.

#import <Foundation/Foundation.h>
#import "LCGeoPoint.h"
#import "LCObject_Internal.h"
#import "LCQuery.h"
#import "LCUtils_Internal.h"
#import "LCPaasClient.h"
#import "LCPaasClient.h"
#import "LCUser_Internal.h"
#import "LCGeoPoint_Internal.h"
#import "LCCacheManager.h"
#import "LCErrorUtils.h"
#import "LCObjectUtils.h"
#import "LCQuery_Internal.h"
#import "LCCloudQueryResult_Internal.h"

NS_INLINE
NSString *LCStringFromDistanceUnit(LCQueryDistanceUnit unit) {
    NSString *unitString = nil;

    switch (unit) {
    case LCQueryDistanceUnitMile:
        unitString = @"miles";
        break;
    case LCQueryDistanceUnitKilometer:
        unitString = @"kilometers";
        break;
    case LCQueryDistanceUnitRadian:
        unitString = @"radians";
        break;
    default:
        break;
    }

    return unitString;
}

@interface   LCQuery()

@property (nonatomic, readwrite, strong) NSMutableSet *include;
@property (nonatomic, readwrite, strong) NSString *order;

@end

@implementation  LCQuery

@synthesize className = _className;
@synthesize where = _where;
@synthesize include = _include;
@synthesize order = _order;


- (NSMutableDictionary *)parameters {
    if (!_parameters) {
        _parameters = [NSMutableDictionary dictionary];
    }
    return _parameters;
}

+ (instancetype)queryWithClassName:(NSString *)className
{
    LCQuery * query = [[[self class] alloc] initWithClassName:className];
    return query;
}

+ (LCCloudQueryResult *)doCloudQueryWithCQL:(NSString *)cql {
    return [self doCloudQueryWithCQL:cql error:NULL];
}

+ (LCCloudQueryResult *)doCloudQueryWithCQL:(NSString *)cql error:(NSError **)error {
    return [self doCloudQueryWithCQL:cql pvalues:nil error:error];
}
+ (LCCloudQueryResult *)doCloudQueryWithCQL:(NSString *)cql pvalues:(NSArray *)pvalues error:(NSError **)error {
    return [self cloudQueryWithCQL:cql pvalues:pvalues callback:nil waitUntilDone:YES error:error];
}

+ (void)doCloudQueryInBackgroundWithCQL:(NSString *)cql callback:(LCCloudQueryCallback)callback {
    [self doCloudQueryInBackgroundWithCQL:cql pvalues:nil callback:callback];
}

+ (void)doCloudQueryInBackgroundWithCQL:(NSString *)cql pvalues:(NSArray *)pvalues callback:(LCCloudQueryCallback)callback {
    [self cloudQueryWithCQL:cql pvalues:pvalues callback:callback waitUntilDone:NO error:NULL];
}

+ (LCCloudQueryResult *)cloudQueryWithCQL:(NSString *)cql pvalues:(NSArray *)pvalues callback:(LCCloudQueryCallback)callback waitUntilDone:(BOOL)wait error:(NSError **)error{
    if (!cql) {
        NSError *err = LCError(kLCErrorInvalidQuery, @"cql can not be nil", nil);
        if (error) {
            *error = err;
        }
        if (callback) {
            [LCUtils callCloudQueryCallback:callback result:nil error:err];
        }
        return nil;
    }
    LCCloudQueryResult __block *theResultObject = [[LCCloudQueryResult alloc] init];
    BOOL __block hasCalledBack = NO;
    NSError __block *blockError = nil;
    
    NSString *path = @"cloudQuery";
    NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithObject:cql forKey:@"cql"];
    if (pvalues.count > 0) {
        NSArray *parsedPvalues = [LCObjectUtils dictionaryFromObject:pvalues];
        NSString *jsonString = [LCUtils jsonStringFromArray:parsedPvalues];
        if (jsonString) {
            parameters[@"pvalues"] = jsonString;
        }
    }
    
    [[LCPaasClient sharedInstance] getObject:path withParameters:parameters block:^(id dict, NSError *error) {
        if (error == nil && [LCObjectUtils hasAnyKeys:dict]) {
            NSString *className = [dict objectForKey:@"className"];
            NSArray *resultArray = [dict objectForKey:@"results"];
            NSNumber *count = [dict objectForKey:@"count"];
            NSMutableArray *results = [[NSMutableArray alloc] init];
            if (resultArray.count > 0 && className) {
                for (NSDictionary *objectDict in resultArray) {
                    LCObject *object = [LCObjectUtils lcObjectForClass:className];
                    [LCObjectUtils copyDictionary:objectDict toObject:object];
                    [results addObject:object];
                }
            }
            [theResultObject setResults:[results copy]];
            [theResultObject setCount:[count intValue]];
            [theResultObject setClassName:className];
        }
        [LCUtils callCloudQueryCallback:callback result:theResultObject error:error];
        if (wait) {
            blockError = error;
            hasCalledBack = YES;
        }
        
    }];
    if (wait) {
        [LCUtils warnMainThreadIfNecessary];
        LC_WAIT_TIL_TRUE(hasCalledBack, 0.1);
    };
    
    if (error != NULL) *error = blockError;
    return theResultObject;
    
}

- (instancetype)init {
    self = [super init];

    if (self) {
        [self doInitialization];
    }

    return self;
}

- (instancetype)initWithClassName:(NSString *)newClassName
{
    self = [super init];

    if (self) {
        _className = [newClassName copy];
        [self doInitialization];
    }

    return self;
}

- (void)doInitialization {
    _where = [[NSMutableDictionary alloc] init];
    _include = [[NSMutableSet alloc] init];
    _maxCacheAge = 24 * 3600;
}

- (void)includeKey:(NSString *)key {
    [self.include addObject:key];
}

- (void)resetIncludeKey {
    self.include = [[NSMutableSet alloc] init];
}

- (void)selectKeys:(NSArray<NSString *> *)keys {
    if (!self.selectedKeys) {
        self.selectedKeys = [[NSMutableSet alloc] initWithCapacity:keys.count];
    }
    [self.selectedKeys addObjectsFromArray:keys];
}

- (void)resetSelectKey {
    self.selectedKeys = nil;
}

- (void)addWhereItem:(id)dict forKey:(NSString *)key {
    if ([dict objectForKey:@"$eq"]) {
        if ([self.where objectForKey:@"$and"]) {
            NSMutableArray *eqArray = [self.where objectForKey:@"$and"];
            int removeIndex = -1;
            for (NSDictionary *eqDict in eqArray) {
                if ([eqDict objectForKey:key]) {
                    removeIndex = (int)[eqArray indexOfObject:eqDict];
                }
            }
            
            if (removeIndex >= 0) {
                [eqArray removeObjectAtIndex:removeIndex];
            }
            
            [eqArray addObject:@{key:[dict objectForKey:@"$eq"]}];
        } else {
            NSMutableArray *eqArray = [[NSMutableArray alloc] init];
            [eqArray addObject:@{key:[dict objectForKey:@"$eq"]}];
            [self.where setObject:eqArray forKey:@"$and"];
        }
    } else {
        if ([self.where objectForKey:key]) {
            [[self.where objectForKey:key] addEntriesFromDictionary:dict];
        } else {
            NSMutableDictionary *mutableDict = [[NSMutableDictionary alloc] initWithDictionary:dict];
            [self.where setObject:mutableDict forKey:key];
        }
    }
}

- (void)whereKeyExists:(NSString *)key
{
    NSDictionary * dict = @{@"$exists": [NSNumber numberWithBool:YES]};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKeyDoesNotExist:(NSString *)key
{
    NSDictionary * dict = @{@"$exists": [NSNumber numberWithBool:NO]};
    [self addWhereItem:dict forKey:key];
}

- (id)valueForEqualityTesting:(id)object {
    if (!object) {
        return [NSNull null];
    } else if ([object isKindOfClass:[LCObject class]]) {
        NSMutableDictionary * dict = [[NSMutableDictionary alloc] init];
        [dict setObject:@"Pointer" forKey:@"__type"];
        [dict setObject:[object internalClassName] forKey:classNameTag];
        if ([object hasValidObjectId])
        {
            [dict setObject:((LCObject *)object).objectId forKey:@"objectId"];
            return dict;
        } else {
            return NSNull.null;
        }
    } else {
        return object;
    }
}

- (void)whereKey:(NSString *)key equalTo:(id)object
{
    NSDictionary * dict = @{@"$eq": [self valueForEqualityTesting:object]};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key sizeEqualTo:(NSUInteger)count
{
    [self addWhereItem:@{@"$size": [NSNumber numberWithUnsignedInteger:count]} forKey:key];
}


- (void)whereKey:(NSString *)key lessThan:(id)object
{
    NSDictionary * dict = @{@"$lt":object};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key lessThanOrEqualTo:(id)object
{
    NSDictionary * dict = @{@"$lte":object};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key greaterThan:(id)object
{
    NSDictionary * dict = @{@"$gt": object};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key greaterThanOrEqualTo:(id)object
{
    NSDictionary * dict = @{@"$gte": object};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key notEqualTo:(id)object
{
    NSDictionary * dict = @{@"$ne": [self valueForEqualityTesting:object]};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key containedIn:(NSArray *)array
{
    NSDictionary * dict = @{@"$in": array };
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key notContainedIn:(NSArray *)array
{
    NSDictionary * dict = @{@"$nin": array };
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key containsAllObjectsInArray:(NSArray *)array
{
    NSDictionary * dict = @{@"$all": array };
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key nearGeoPoint:(LCGeoPoint *)geoPoint
{
    NSDictionary * dict = @{@"$nearSphere" : [LCGeoPoint dictionaryFromGeoPoint:geoPoint]};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key nearGeoPoint:(LCGeoPoint *)geoPoint withinMiles:(double)maxDistance
{
    NSDictionary * dict = @{@"$nearSphere" : [LCGeoPoint dictionaryFromGeoPoint:geoPoint], @"$maxDistanceInMiles":@(maxDistance)};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key nearGeoPoint:(LCGeoPoint *)geoPoint withinKilometers:(double)maxDistance
{
    NSDictionary * dict = @{@"$nearSphere" : [LCGeoPoint dictionaryFromGeoPoint:geoPoint], @"$maxDistanceInKilometers":@(maxDistance)};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key nearGeoPoint:(LCGeoPoint *)geoPoint withinRadians:(double)maxDistance
{
    NSDictionary * dict = @{@"$nearSphere" : [LCGeoPoint dictionaryFromGeoPoint:geoPoint], @"$maxDistanceInRadians":@(maxDistance)};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key
    nearGeoPoint:(LCGeoPoint *)geoPoint
     maxDistance:(double)maxDistance
 maxDistanceUnit:(LCQueryDistanceUnit)maxDistanceUnit
     minDistance:(double)minDistance
 minDistanceUnit:(LCQueryDistanceUnit)minDistanceUnit
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    dict[@"$nearSphere"] = [LCGeoPoint dictionaryFromGeoPoint:geoPoint];

    NSString *unitString = nil;

    if (maxDistance >= 0 && (unitString = LCStringFromDistanceUnit(maxDistanceUnit))) {
        NSString *querySelector = [NSString stringWithFormat:@"$maxDistanceIn%@", [unitString capitalizedString]];
        dict[querySelector] = @(maxDistance);
    }

    if (minDistance >= 0 && (unitString = LCStringFromDistanceUnit(minDistanceUnit))) {
        NSString *querySelector = [NSString stringWithFormat:@"$minDistanceIn%@", [unitString capitalizedString]];
        dict[querySelector] = @(minDistance);
    }

    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key
    nearGeoPoint:(LCGeoPoint *)geoPoint
     minDistance:(double)minDistance
 minDistanceUnit:(LCQueryDistanceUnit)minDistanceUnit
{
    [self whereKey:key nearGeoPoint:geoPoint maxDistance:-1 maxDistanceUnit:(LCQueryDistanceUnit)0 minDistance:minDistance minDistanceUnit:minDistanceUnit];
}

- (void)whereKey:(NSString *)key withinGeoBoxFromSouthwest:(LCGeoPoint *)southwest toNortheast:(LCGeoPoint *)northeast
{
    NSDictionary * dict = @{@"$within": @{@"$box" : @[[LCGeoPoint dictionaryFromGeoPoint:southwest], [LCGeoPoint dictionaryFromGeoPoint:northeast]]}};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key matchesRegex:(NSString *)regex
{
    NSDictionary * dict = @{@"$regex": regex};
    [self addWhereItem:dict forKey:key];
}

- (void)whereKey:(NSString *)key matchesRegex:(NSString *)regex modifiers:(NSString *)modifiers
{
    NSDictionary * dict = @{@"$regex":regex, @"$options":modifiers};
    [self addWhereItem:dict forKey:key];
}

/**
 * Converts a string into a regex that matches it.
 * Surrounding with \Q .. \E does this, we just need to escape \E's in
 * the text separately.
 */
static NSString * quote(NSString *string)
{
    NSString *replacedString = [string stringByReplacingOccurrencesOfString:@"\\E" withString:@"\\E\\\\E\\Q"];
    if (replacedString) {
        replacedString = [[@"\\Q" stringByAppendingString:replacedString] stringByAppendingString:@"\\E"];
    }
    return replacedString;
}

- (void)whereKey:(NSString *)key containsString:(NSString *)substring
{
    [self whereKey:key matchesRegex:[NSString stringWithFormat:@".*%@.*", quote(substring)]];
}

- (void)whereKey:(NSString *)key hasPrefix:(NSString *)prefix
{
    [self whereKey:key matchesRegex:[NSString stringWithFormat:@"^%@.*", quote(prefix)]];
}

- (void)whereKey:(NSString *)key hasSuffix:(NSString *)suffix
{
    [self whereKey:key matchesRegex:[NSString stringWithFormat:@".*%@$", quote(suffix)]];
}

+ (LCQuery *)orQueryWithSubqueries:(NSArray<LCQuery *> *)queries {
    LCQuery *orQuery;
    NSString *firstClassName = queries.firstObject.className;
    if (firstClassName) {
        NSMutableArray *wheres = [[NSMutableArray alloc] initWithCapacity:queries.count];
        for (LCQuery *query in queries) {
            NSAssert([query.className isEqualToString:firstClassName], @"the `queries` require same `className`");
            if (query.where.count > 0) {
                [wheres addObject:query.where];
            }
        }
        if (wheres.count > 0) {
            orQuery = [LCQuery queryWithClassName:firstClassName];
            [orQuery.where setValue:wheres forKey:@"$or"];
        }
    }
    return orQuery;
}

+ (LCQuery *)andQueryWithSubqueries:(NSArray<LCQuery *> *)queries {
    LCQuery *andQuery;
    NSString *firstClassName = queries.firstObject.className;
    if (firstClassName) {
        NSMutableArray *wheres = [[NSMutableArray alloc] initWithCapacity:queries.count];
        for (LCQuery *query in queries) {
            NSAssert([query.className isEqualToString:firstClassName], @"the `queries` require same `className`");
            if (query.where.count > 0) {
                [wheres addObject:query.where];
            }
        }
        if (wheres.count > 0) {
            andQuery = [LCQuery queryWithClassName:firstClassName];
            if (wheres.count > 1) {
                [andQuery.where setValue:wheres forKey:@"$and"];
            } else {
                [andQuery.where addEntriesFromDictionary:wheres[0]];
            }
        }
    }
    return andQuery;
}

// 'where={"belongTo":{"$select":{"query":{"className":"Person","where":{"gender":"Male"}},"key":"name"}}}'
- (void)whereKey:(NSString *)key matchesKey:(NSString *)otherKey inQuery:(LCQuery *)query
{
    NSMutableDictionary *queryDict = [[NSMutableDictionary alloc] initWithDictionary:@{@"className":query.className,
                                                                                       @"where":query.where}];
    if (query.limit > 0) {
        [queryDict addEntriesFromDictionary:@{@"limit":@(query.limit)}];
    }
    
    if (query.skip > 0) {
        [queryDict addEntriesFromDictionary:@{@"skip":@(query.skip)}];
    }
    
    if (query.order.length > 0) {
        [queryDict addEntriesFromDictionary:@{@"order":query.order}];
    }
    
    NSDictionary *dict = @{@"$select":
                               @{@"query":queryDict,
                                 @"key":otherKey
                                 }
                           };
    [self.where setValue:dict forKey:key];
}

- (void)whereKey:(NSString *)key doesNotMatchKey:(NSString *)otherKey inQuery:(LCQuery *)query
{
    NSDictionary *dict = @{@"$dontSelect":
                               @{@"query":
                                     @{@"className":query.className,
                                       @"where":query.where
                                       },
                                 @"key":otherKey
                                 }
                           };
    [self.where setValue:dict forKey:key];
}

// 'where={"post":{"$inQuery":{"where":{"image":{"$exists":true}},"className":"Post"}}}'
- (void)whereKey:(NSString *)key matchesQuery:(LCQuery *)query
{
    NSMutableDictionary *queryDict = [[NSMutableDictionary alloc] initWithDictionary:@{@"className":query.className,
                                                                                       @"where":query.where}];
    if (query.limit > 0) {
        [queryDict addEntriesFromDictionary:@{@"limit":@(query.limit)}];
    }
    
    if (query.skip > 0) {
        [queryDict addEntriesFromDictionary:@{@"skip":@(query.skip)}];
    }
    
    if (query.order.length > 0) {
        [queryDict addEntriesFromDictionary:@{@"order":query.order}];
    }
    
    NSDictionary *dic = @{@"$inQuery":queryDict};
    [self.where setValue:dic forKey:key];
}

- (void)whereKey:(NSString *)key doesNotMatchQuery:(LCQuery *)query
{
    NSDictionary *dic = @{@"$notInQuery":
                              @{@"where":query.where,
                                @"className":query.className
                                }
                          };
    [self.where setValue:dic forKey:key];
}

- (void)orderByAscending:(NSString *)key
{
    self.order = [NSString stringWithFormat:@"%@", key];
}

- (void)addAscendingOrder:(NSString *)key
{
    if (self.order.length <= 0)
    {
        [self orderByAscending:key];
        return;
    }
    self.order = [NSString stringWithFormat:@"%@,%@", self.order, key];
}

- (void)orderByDescending:(NSString *)key
{
    self.order = [NSString stringWithFormat:@"-%@", key];
}

- (void)addDescendingOrder:(NSString *)key
{
    if (self.order.length <= 0)
    {
        [self orderByDescending:key];
        return;
    }
    self.order = [NSString stringWithFormat:@"%@,-%@", self.order, key];
}

- (void)orderBySortDescriptor:(NSSortDescriptor *)sortDescriptor
{
    NSString *symbol = sortDescriptor.ascending ? @"" : @"-";
    self.order = [symbol stringByAppendingString:sortDescriptor.key];
}

- (void)orderBySortDescriptors:(NSArray *)sortDescriptors
{
    if (sortDescriptors.count == 0) return;

    self.order = @"";
    for (NSSortDescriptor *sortDescriptor in sortDescriptors) {
        NSString *symbol = sortDescriptor.ascending ? @"" : @"-";
        if (self.order.length) {
            self.order = [NSString stringWithFormat:@"%@,%@%@", self.order, symbol, sortDescriptor.key];
        } else {
            self.order=[NSString stringWithFormat:@"%@%@", symbol, sortDescriptor.key];
        }

    }
}

+ (LCObject *)getObjectOfClass:(NSString *)objectClass
                      objectId:(NSString *)objectId
{
    return [[self class] getObjectOfClass:objectClass objectId:objectId error:NULL];
}

+ (LCObject *)getObjectOfClass:(NSString *)objectClass
                      objectId:(NSString *)objectId
                         error:(NSError **)error
{
    return [[LCQuery queryWithClassName:objectClass] getObjectWithId:objectId error:error];
}

- (LCObject *)getObjectWithId:(NSString *)objectId
{
    return [self getObjectWithId:objectId error:NULL];
}

- (LCObject *)getObjectWithId:(NSString *)objectId error:(NSError **)error
{
    [self raiseSyncExceptionIfNeed];
    
    LCObject __block *theResultObject = nil;
    BOOL __block hasCalledBack = NO;
    NSError __block *blockError = nil;
    [self internalGetObjectInBackgroundWithId:objectId block:^(LCObject *object, NSError *error) {
        theResultObject = object;
        blockError = error;
        hasCalledBack = YES;
    }];
    
    [LCUtils warnMainThreadIfNecessary];
    LC_WAIT_TIL_TRUE(hasCalledBack, 0.1);
    
    if (error != NULL) {
        *error = blockError;
    }
    return theResultObject;
}

- (void)getObjectInBackgroundWithId:(NSString *)objectId
                              block:(LCObjectResultBlock)block {
    [self internalGetObjectInBackgroundWithId:objectId block:^(LCObject *object, NSError *error) {
        [LCUtils callObjectResultBlock:block object:object error:error];
    }];
}

- (void)internalGetObjectInBackgroundWithId:(NSString *)objectId
                              block:(LCObjectResultBlock)block
{
    NSString *path = [LCObjectUtils objectPath:self.className objectId:objectId];
    [self assembleParameters];
    [[LCPaasClient sharedInstance] getObject:path withParameters:self.parameters policy:self.cachePolicy maxCacheAge:self.maxCacheAge block:^(id dict, NSError *error) {
        LCObject *object = nil;
        if (error == nil && [LCObjectUtils hasAnyKeys:dict]) {
            object = [LCObjectUtils lcObjectForClass:self.className];
            [LCObjectUtils copyDictionary:dict toObject:object];
        }
        
        if (error == nil && [dict allKeys].count == 0) {
            error = LCError(kLCErrorObjectNotFound, [NSString stringWithFormat:@"No object with that objectId %@ was found.", objectId], nil);
        }
        if (block) {
            block(object, error);
        }
    }];
}

#pragma mark -
#pragma mark Getting Users

/*! @name Getting User Objects */

/*!
 Returns a LCUser with a given id.
 @param objectId The id of the object that is being requested.
 @result The LCUser if found. Returns nil if the object isn't found, or if there was an error.
 */
+ (LCUser *)getUserObjectWithId:(NSString *)objectId
{
    return [[self class] getUserObjectWithId:objectId error:NULL];
}

/*!
 Returns a LCUser with a given class and id and sets an error if necessary.
 @param error Pointer to an NSError that will be set if necessary.
 @result The LCUser if found. Returns nil if the object isn't found, or if there was an error.
 */
+ (LCUser *)getUserObjectWithId:(NSString *)objectId
                          error:(NSError **)error
{
    id user = [[LCUser query] getObjectWithId:objectId error:error];
    if ([user isKindOfClass:[LCUser class]]) {
        return user;
    }

    return nil;
}

#pragma mark -
#pragma mark Find methods

/** @name Getting all Matches for a Query */

/*!
 Finds objects based on the constructed query.
 @result Returns an array of LCObjects that were found.
 */
- (NSArray *)findObjects
{
    return [self findObjects:NULL];
}

/*!
 Finds objects based on the constructed query and sets an error if there was one.
 @param error Pointer to an NSError that will be set if necessary.
 @result Returns an array of LCObjects that were found.
 */
- (NSArray *)findObjects:(NSError **)error
{
    return [self findObjectsWithBlock:NULL waitUntilDone:YES error:error];
}

- (NSArray *)findObjectsAndThrowsWithError:(NSError * _Nullable __autoreleasing *)error {
    return [self findObjects:error];
}

-(void)queryWithBlock:(NSString *)path
           parameters:(NSDictionary *)parameters
                block:(LCArrayResultBlock)resultBlock
{

    [[LCPaasClient sharedInstance] getObject:path withParameters:parameters policy:self.cachePolicy maxCacheAge:self.maxCacheAge block:^(id object, NSError *error) {
        NSMutableArray * array;
        if (error == nil)
        {
            NSString *className = object[@"className"];
            BOOL end = [[object objectForKey:@"end"] boolValue];
            NSArray * results = [object objectForKey:@"results"];
            array = [self processResults:results className:className];
            [self processEnd:end];
        }
        if (resultBlock) {
            resultBlock(array, error);
        }
    }];
}

- (void)findObjectsInBackgroundWithBlock:(LCArrayResultBlock)resultBlock
{
    [self findObjectsWithBlock:resultBlock waitUntilDone:NO error:NULL];
}

// private method for sync and async using
- (NSArray *)findObjectsWithBlock:(LCArrayResultBlock)resultBlock
                    waitUntilDone:(BOOL)wait
                            error:(NSError **)theError
{
    if (wait) [self raiseSyncExceptionIfNeed];

    NSArray __block *theResultArray = nil;
    BOOL __block hasCalledBack = NO;
    NSError __block *blockError = nil;

    NSString *path = [self queryPath];
    [self assembleParameters];

    [self queryWithBlock:path parameters:self.parameters block:^(NSArray *objects, NSError *error) {
        [LCUtils callArrayResultBlock:resultBlock array:objects error:error];

        if (wait) {
            blockError = error;
            theResultArray = objects;
            hasCalledBack = YES;
        }
    }];

    if (wait) {
        [LCUtils warnMainThreadIfNecessary];
        LC_WAIT_TIL_TRUE(hasCalledBack, 0.1);
    };

     if (theError != NULL) *theError = blockError;
    return theResultArray;
}

// Called in findObjects and getFirstObject, isDataReady is set to YES
- (NSMutableArray *)processResults:(NSArray *)results className:(NSString *)className {
    NSMutableArray * array = [[NSMutableArray alloc] init];
    for(NSDictionary * dict in results)
    {
        LCObject * object = [LCObjectUtils lcObjectForClass:className ?: self.className];
        [LCObjectUtils copyDictionary:dict toObject:object];
        [array addObject:object];
    }
    return array;
}

- (void)processEnd:(BOOL)end {
    
}

- (void)deleteAllInBackgroundWithBlock:(LCBooleanResultBlock)block {
    [self findObjectsInBackgroundWithBlock:^(NSArray *objects, NSError *error) {
        if (error) {
            block(NO, error);
        } else {
            [LCObject deleteAllInBackground:objects block:block];
        }
    }];
}

/** @name Getting the First Match in a Query */

/*!
 Gets an object based on the constructed query.

 This mutates the LCQuery.

 @result Returns a LCObject, or nil if none was found.
 */
- (LCObject *)getFirstObject
{
    return [self getFirstObject:NULL];
}

/*!
 Gets an object based on the constructed query and sets an error if any occurred.

 This mutates the LCQuery.

 @param error Pointer to an NSError that will be set if necessary.
 @result Returns a LCObject, or nil if none was found.
 */
- (LCObject *)getFirstObject:(NSError **)error
{
    return [self getFirstObjectWithBlock:NULL waitUntilDone:YES error:error];
}

- (LCObject *)getFirstObjectAndThrowsWithError:(NSError * _Nullable __autoreleasing *)error {
    return [self getFirstObject:error];
}

- (void)getFirstObjectInBackgroundWithBlock:(LCObjectResultBlock)resultBlock
{
    [self getFirstObjectWithBlock:resultBlock waitUntilDone:NO error:NULL];
}

- (LCObject *)getFirstObjectWithBlock:(LCObjectResultBlock)resultBlock
                        waitUntilDone:(BOOL)wait
                                error:(NSError **)theError {
    if (wait) [self raiseSyncExceptionIfNeed];

    LCObject __block *theResultObject = nil;
    BOOL __block hasCalledBack = NO;
    NSError __block *blockError = nil;

    NSString *path = [self queryPath];
    [self assembleParameters];
    [self.parameters setObject:@(1) forKey:@"limit"];

    [[LCPaasClient sharedInstance] getObject:path withParameters:self.parameters policy:self.cachePolicy maxCacheAge:self.maxCacheAge block:^(id object, NSError *error) {
        NSString *className = object[@"className"];
        NSArray *results = [object objectForKey:@"results"];
        BOOL end = [[object objectForKey:@"end"] boolValue];
        NSError *wrappedError = error;

        if (error) {
            [LCUtils callObjectResultBlock:resultBlock object:nil error:error];
        } else if (results.count == 0) {
            wrappedError = LCError(kLCErrorObjectNotFound, @"no results matched the query", nil);
            [LCUtils callObjectResultBlock:resultBlock object:nil error:wrappedError];
        } else {
            NSMutableArray * array = [self processResults:results className:className];
            [self processEnd:end];
            LCObject *resultObject = [array objectAtIndex:0];
            [LCUtils callObjectResultBlock:resultBlock object:resultObject error:error];

            theResultObject = resultObject;
        }

        if (wait) {
            blockError = wrappedError;
            hasCalledBack = YES;
        }
    }];

    if (wait) {
        [LCUtils warnMainThreadIfNecessary];
        LC_WAIT_TIL_TRUE(hasCalledBack, 0.1);
    };

    if (theError != NULL) *theError = blockError;
    return theResultObject;
}

#pragma mark -
#pragma mark Count methods

/** @name Counting the Matches in a Query */

/*!
  Counts objects based on the constructed query.
 @result Returns the number of LCObjects that match the query, or -1 if there is an error.
 */
- (NSInteger)countObjects
{
    return [self countObjects:NULL];
}

/*!
  Counts objects based on the constructed query and sets an error if there was one.
 @param error Pointer to an NSError that will be set if necessary.
 @result Returns the number of LCObjects that match the query, or -1 if there is an error.
 */
- (NSInteger)countObjects:(NSError **)error
{
    return [self countObjectsWithBlock:NULL waitUntilDone:YES error:error];
}

- (NSInteger)countObjectsAndThrowsWithError:(NSError * _Nullable __autoreleasing *)error {
    return [self countObjects:error];
}

/*!
 Counts objects asynchronously and calls the given block with the counts.
 @param block The block to execute. The block should have the following argument signature:
 (int count, NSError *error)
 */
- (void)countObjectsInBackgroundWithBlock:(LCIntegerResultBlock)block
{
    [self countObjectsWithBlock:block waitUntilDone:NO error:NULL];
}

- (NSInteger)countObjectsWithBlock:(LCIntegerResultBlock)block
                     waitUntilDone:(BOOL)wait
                             error:(NSError **)theError {
    if (wait) [self raiseSyncExceptionIfNeed];

    NSInteger __block theResultCount = -1;
    BOOL __block hasCalledBack = NO;
    NSError __block *blockError = nil;

    NSString *path = [self queryPath];
    [self assembleParameters];
    [self.parameters setObject:@1 forKey:@"count"];
    [self.parameters setObject:@0 forKey:@"limit"];

    [[LCPaasClient sharedInstance] getObject:path withParameters:self.parameters policy:self.cachePolicy maxCacheAge:self.maxCacheAge block:^(id object, NSError *error) {
        NSInteger count = [[object objectForKey:@"count"] integerValue];
        [LCUtils callIntegerResultBlock:block number:count error:error];

        if (wait) {
            blockError = error;
            hasCalledBack = YES;
            theResultCount = count;
        }
    }];

    if (wait) {
        [LCUtils warnMainThreadIfNecessary];
        LC_WAIT_TIL_TRUE(hasCalledBack, 0.1);
    };

    if (theError != NULL) *theError = blockError;
    return theResultCount;
}

#pragma mark -
#pragma mark Cancel methods

/** @name Cancelling a Query */

/*!
 Cancels the current network request (if any). Ensures that callbacks won't be called.
 */
- (void)cancel
{
    /* NOTE: absolutely, following code is ugly and fragile.
       However, the compatibility is the chief culprit of this tragedy.
       Detail discussion: https://github.com/leancloud/paas/issues/828
       We should deprecate this method in future.
     */
    [[LCPaasClient sharedInstance].lock lock];
    NSMapTable *table = [[LCPaasClient sharedInstance].requestTable copy];
    [[LCPaasClient sharedInstance].lock unlock];
    NSString *URLString = [[LCPaasClient sharedInstance] absoluteStringFromPath:[self queryPath] parameters:self.parameters];

    for (NSString *key in table) {
        if ([URLString isEqualToString:key]) {
            NSURLSessionDataTask *request = [table objectForKey:key];
            [request cancel];
        }
    }
}

- (BOOL)hasCachedResult
{
    [self assembleParameters];
    NSString *key = [[LCPaasClient sharedInstance] absoluteStringFromPath:[self queryPath] parameters:self.parameters];
    return [[LCCacheManager sharedInstance] hasCacheForKey:key];
}

/*!
 Clears the cached result for this query.  If there is no cached result, this is a noop.
 */
- (void)clearCachedResult
{
    [self assembleParameters];
    NSString *key = [[LCPaasClient sharedInstance] absoluteStringFromPath:[self queryPath] parameters:self.parameters];
    [[LCCacheManager sharedInstance] clearCacheForKey:key];
}

/*!
 Clears the cached results for all queries.
 */
+ (void)clearAllCachedResults
{
    [LCCacheManager clearAllCache];
}

#pragma mark - Handle the data for communication with server
- (NSString *)queryPath {
    if (self.endpoint) {
        return self.endpoint;
    } else {
        return [LCObjectUtils objectPath:self.className objectId:nil];
    }
}

+ (NSDictionary *)dictionaryFromIncludeKeys:(NSArray *)array {
    return @{@"include": [array componentsJoinedByString:@","]};
}

- (NSMutableDictionary *)assembleParameters {
    [self.parameters removeAllObjects];
    if (self.where.count > 0) {
        [self.parameters setObject:[self whereString] forKey:@"where"];
    }
    if (self.limit > 0) {
        [self.parameters setObject:@(self.limit) forKey:@"limit"];
    }
    if (self.skip > 0) {
        [self.parameters setObject:@(self.skip) forKey:@"skip"];
    }
    if (self.order.length > 0) {
        [self.parameters setObject:self.order forKey:@"order"];
    }
    if (self.include.count > 0) {
        NSString *includes = [[self.include allObjects] componentsJoinedByString:@","];
        [self.parameters setObject:includes forKey:@"include"];
    }
    if (self.selectedKeys.count > 0) {
        NSString *keys = [[self.selectedKeys allObjects] componentsJoinedByString:@","];
        [self.parameters setObject:keys forKey:@"keys"];
    }
    if (self.includeACL) {
        [self.parameters setObject:@"true" forKey:@"returnACL"];
    }
    if (self.extraParameters.count > 0) {
        [self.parameters addEntriesFromDictionary:self.extraParameters];
    }
    return self.parameters;
}

- (NSString *)whereString {
    NSDictionary *dic = [LCObjectUtils dictionaryFromDictionary:self.where];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dic options:0 error:NULL];
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (NSDictionary *)whereJSONDictionary {
    NSData *data = [[self whereString] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return dictionary;
}

#pragma mark - Util methods
- (void)raiseSyncExceptionIfNeed {
    if (self.cachePolicy == kLCCachePolicyCacheThenNetwork) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"kLCCachePolicyCacheThenNetwork can't not use in sync methods"];
    };
}

#pragma mark - Advanced Settings


@end
