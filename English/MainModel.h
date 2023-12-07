//
//  MainModel.h
//  English
//
//  Created by wangshengfeng on 2023/12/7.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN


@interface MainDataModel: NSObject
@property (nonatomic ,copy)NSString * text;
@end

@interface MainModel : NSObject


@property (nonatomic, copy) NSString *date;
@property (nonatomic ,copy)NSArray<MainDataModel *> * data;
@end

NS_ASSUME_NONNULL_END
