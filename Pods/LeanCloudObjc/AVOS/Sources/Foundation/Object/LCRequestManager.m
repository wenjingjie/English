//
//  LCRequestManager.m
//  paas
//
//  Created by Zhu Zeng on 9/10/13.
//  Copyright (c) 2013 LeanCloud. All rights reserved.
//

#import "LCRequestManager.h"
#import "LCObject.h"
#import "LCObjectUtils.h"
#import "LCObject_Internal.h"
#import "LCACL_Internal.h"

typedef enum {
    SET,
    UNSET,
    INC,
    ADD,
    ADD_UNIQUE,
    ADD_RELATION,
    REMOVE,
    REMOVE_RELATION,
} LCOp;

#define kLCOpAddRelation @"AddRelation"
#define kLCOpRemoveRelation @"RemoveRelation"
#define kLCOpAddUnique @"AddUnique"
#define kLCOpDelete @"Delete"
#define kLCOpIncrement @"Increment"
#define kLCOpAdd @"Add"
#define kLCOpRemove @"Remove"

@implementation LCRequestManager {
    NSRecursiveLock *_lock;
}

+ (NSString *)serverOpForOp:(LCOp)op {
    switch (op) {
        case SET:
            return nil;
        case UNSET:
            return kLCOpDelete;
        case INC:
            return kLCOpIncrement;
        case ADD:
            return kLCOpAdd;
        case ADD_UNIQUE:
            return kLCOpAddUnique;
        case ADD_RELATION:
            return kLCOpAddRelation;
        case REMOVE:
            return kLCOpRemove;
        case REMOVE_RELATION:
            return kLCOpRemoveRelation;
    }
    return nil;
}

+(NSDictionary *)unsetOpForKey:(NSString *)key {
    NSDictionary * op = @{key: @{@"__op": kLCOpDelete}};
    return op;
}

+(NSDictionary *)incOpForKey:(NSString *)key
                       value:(double)value {
    NSDictionary * op = @{key: @{@"__op": kLCOpIncrement, @"amount": @(value)}};
    return op;
}

+ (NSDictionary *)commonOpForKey:(NSString *)key objects:(NSArray *)objects op:(NSString *)op {
    NSMutableArray * array = [NSMutableArray array];
    for(LCObject * obj in objects) {
        NSDictionary * dict = [LCObjectUtils dictionaryFromObject:obj];
        [array addObject:dict];
    }
    NSDictionary *dict = @{key: @{@"__op": op, @"objects": array}};
    return dict;
}

-(instancetype)init {
    self = [super init];

    if (self) {
        _dictArray = [NSMutableArray array];

        for(int i = SET; i <= REMOVE_RELATION; ++i) {
            NSMutableDictionary * dict = [NSMutableDictionary dictionary];
            [_dictArray addObject:dict];
        }

        _lock = [[NSRecursiveLock alloc] init];
    }

    return self;
}

- (void)synchronize:(void (^)(void))action {
    if (action) {
        [_lock lock];
        action();
        [_lock unlock];
    }
}

-(NSMutableArray *)findArrayInDict:(NSMutableDictionary *)dict
                             byKey:(NSString *)key
                            create:(BOOL)create {
    __block NSMutableArray *array = nil;

    [self synchronize:^{
        array = [dict objectForKey:key];

        // Create array if needed.
        if (!array && create) {
            array = [[NSMutableArray alloc] init];
            [dict setObject:array forKey:key];
        }
    }];

    return array;
}

-(NSMutableDictionary *)requestDictForOp:(LCOp)type {
    __block NSMutableDictionary *dictionary = nil;

    [self synchronize:^{
        dictionary = [self.dictArray objectAtIndex:type];
    }];

    return dictionary;
}

-(NSMutableDictionary *)setDict {
    return [self requestDictForOp:SET];
}

-(NSMutableDictionary *)unsetDict {
    return [self requestDictForOp:UNSET];
}

-(NSMutableDictionary *)incDict {
    return [self requestDictForOp:INC];
}

-(NSMutableDictionary *)addDict {
    return [self requestDictForOp:ADD];
}

-(NSMutableDictionary *)addUniqueDict {
    return [self requestDictForOp:ADD_UNIQUE];
}

-(NSMutableDictionary *)addRelationDict {
    return [self requestDictForOp:ADD_RELATION];
}

-(NSMutableDictionary *)removeDict {
    return [self requestDictForOp:REMOVE];
}

-(NSMutableDictionary *)removeRelationDict {
    return [self requestDictForOp:REMOVE_RELATION];
}

#pragma mark - add request

-(void)removeAllForKey:(NSString *)key
            exceptDict:(NSMutableDictionary *)dict {
    for(int i = 0; i < self.dictArray.count; ++i) {
        if ([self.dictArray objectAtIndex:i] != dict) {
            [[self.dictArray objectAtIndex:i] removeObjectForKey:key];
        }
    }
}

-(void)setRequestForKey:(NSString *)key
                 object:(id)object {
    [self synchronize:^{
        [self removeAllForKey:key exceptDict:nil];

        if (object) {
            [[self setDict] setObject:object forKey:key];
        } else {
            [[self setDict] removeObjectForKey:key];
        }
    }];
}

-(void)unsetRequestForKey:(NSString *)key {
    [self synchronize:^{
        [self removeAllForKey:key exceptDict:nil];
        [[self unsetDict] setObject:@"" forKey:key];
    }];
}

-(void)incRequestForKey:(NSString *)key
                  value:(double)value {
    [self synchronize:^{
        NSMutableDictionary *incDict = [self incDict];
        [self removeAllForKey:key exceptDict:incDict];

        double current = [[[self incDict] objectForKey:key] doubleValue];
        current += value;

        [incDict setObject:@(current) forKey:key];
    }];
}

- (void)addRequestForKey:(NSString *)key
                  object:(id)object
                  toDict:(NSMutableDictionary *)dict
              removeFrom:(NSMutableDictionary *)removeDict
{
    [self synchronize:^{
        if (removeDict) {
            NSMutableArray *array = [self findArrayInDict:removeDict byKey:key create:NO];
            [array removeObject:object];
        }

        NSMutableArray *array = [self findArrayInDict:dict byKey:key create:YES];
        [array addObject:object];
    }];
}

-(void)addObjectRequestForKey:(NSString *)key
                       object:(id)object {
    [self addRequestForKey:key object:object toDict:[self addDict] removeFrom:nil];
}

-(void)addUniqueObjectRequestForKey:(NSString *)key
                             object:(id)object {
    [self addRequestForKey:key object:object toDict:[self addUniqueDict] removeFrom:nil];
}

-(void)addRelationRequestForKey:(NSString *)key
                         object:(id)object {
    [self addRequestForKey:key object:object toDict:[self addRelationDict] removeFrom:[self removeRelationDict]];
}

-(void)removeObjectRequestForKey:(NSString *)key
                          object:(id)object {
    [self addRequestForKey:key object:object toDict:[self removeDict] removeFrom:[self addDict]];
}

-(void)removeRelationRequestForKey:(NSString *)key
                            object:(id)object {
    [self addRequestForKey:key object:object toDict:[self removeRelationDict] removeFrom:[self addRelationDict]];
}

#pragma mark - Server json

-(NSDictionary *)jsonForSetWithIgnoreObject:(BOOL)ignoreObject {
    NSDictionary *setDict = [[self setDict] copy];
    NSMutableDictionary * dict = [NSMutableDictionary dictionary];
    for(NSString * key in setDict) {
        id object = setDict[key];
        
        // object without object id will be stored in
        // batch request, so just ignore them here.
        if (ignoreObject &&
            [object isKindOfClass:[LCObject class]] &&
            ![object hasValidObjectId]) {
            continue;
        }

        NSDictionary * jsonDict = [LCObjectUtils dictionaryFromObject:object];
        dict[key] = jsonDict;
    }

    return dict;
}

- (NSDictionary *)jsonForOp:(LCOp)op {
    if (op == SET) {
        return [self jsonForSetWithIgnoreObject:YES];
    } else {
        NSDictionary *requestDict = [self requestDictForOp:op];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        [requestDict enumerateKeysAndObjectsUsingBlock:^(NSString *key, id object, BOOL *stop) {
            NSDictionary *jsonDict;
            if (op == INC) {
                double value = [object doubleValue];
                jsonDict = [LCRequestManager incOpForKey:key value:value];
            } else if (op == UNSET) {
                jsonDict = [LCRequestManager unsetOpForKey:key];
            } else {
                NSString *serverOp = [[self class] serverOpForOp:op];
                NSArray *objects = (NSArray *)object;
                jsonDict = [[self class] commonOpForKey:key objects:objects op:serverOp];
            }
            [dict addEntriesFromDictionary:jsonDict];
        }];
        return dict;
    }
}

// add entry from dict to parent and remove the entry from target.
-(void)addDictionary:(NSDictionary *)dict
                  to:(NSMutableDictionary *)parent
              update:(NSMutableDictionary *)target {
    for(NSString * key in dict) {
        id valueObject = [parent objectForKey:key];
        if (valueObject == nil) {
            valueObject = [dict valueForKey:key];
            [parent setObject:valueObject forKey:key];
            [target removeObjectForKey:key];
        }
    }
}

-(NSMutableDictionary *)initialSetDict {
    NSMutableDictionary * result = [NSMutableDictionary dictionary];

    [self synchronize:^{
        NSDictionary * dict = [self jsonForSetWithIgnoreObject:YES];
        [self addDictionary:dict to:result update:[self setDict]];
    }];

    return result;
}

// Todo, 只有在 LCRole 中调用，应该可以移除
-(NSMutableDictionary *)initialSetAndAddRelationDict {
    NSMutableDictionary * result = [NSMutableDictionary dictionary];

    [self synchronize:^{
        NSDictionary * dict = [self jsonForSetWithIgnoreObject:YES];
        [self addDictionary:dict to:result update:[self setDict]];

        dict = [self jsonForOp:ADD_RELATION];
        [self addDictionary:dict to:result update:[self addRelationDict]];
    }];

    return result;
}

-(NSMutableArray *)allJsonDict {
    NSMutableArray * array = [NSMutableArray array];
    for(LCOp op = SET; op <= REMOVE_RELATION; op++) {
        NSDictionary *dict = [self jsonForOp:op];
        if (dict.count > 0) {
            [array addObject:dict];
        }
    }
    return array;
}

// common 共同的
-(BOOL)hasCommonKeys:(NSDictionary *)source
              target:(NSDictionary *)target {
    NSMutableSet * a = [NSMutableSet setWithArray:[source allKeys]];
    NSMutableSet * b = [NSMutableSet setWithArray:[target allKeys]];
    [a intersectSet:b];
    return a.count > 0;
}

// generate a list of json dictionary for LeanCloud.
-(NSMutableArray *)jsonForCloud {
    NSMutableArray * result = [NSMutableArray array];

    [self synchronize:^{
        NSMutableArray * array = [self allJsonDict];
        NSMutableDictionary * current = [NSMutableDictionary dictionary];

        for(NSMutableDictionary * item in array) {
            if (![self hasCommonKeys:current target:item]) {
                [current addEntriesFromDictionary:item];
            } else {
                [result addObject:current];
                current = [NSMutableDictionary dictionaryWithDictionary:item];
            }
        }

        if (current.count > 0) {
            [result addObject:current];
        }
    }];

    return result;
}

-(BOOL)containsRequest {
    __block BOOL result = NO;

    [self synchronize:^{
        for(NSDictionary * dict in self.dictArray) {
            if (dict.count > 0) {
                result = YES;
                return;
            }
        }
    }];

    return result;
}

-(void)clear {
    [self synchronize:^{
        for(NSMutableDictionary * dict in self.dictArray) {
            [dict removeAllObjects];
        }
    }];
}

@end
