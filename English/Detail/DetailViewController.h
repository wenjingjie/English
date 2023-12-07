//
//  DetailViewController.h
//  English
//
//  Created by wangshengfeng on 2023/12/7.
//

#import <UIKit/UIKit.h>

@class MainModel;

NS_ASSUME_NONNULL_BEGIN

@interface DetailViewController : UIViewController

@property (nonatomic, strong) MainModel *model;

@end

NS_ASSUME_NONNULL_END
