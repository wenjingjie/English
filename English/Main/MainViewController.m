//
//  MainViewController.m
//  English
//
//  Created by wangshengfeng on 2023/12/7.
//

#import "MainViewController.h"

#import "MainModel.h"

#import "MainTableViewCell.h"


#import "DetailViewController.h"


#import <MJExtension.h>
#import <Foundation.h>

@interface MainViewController ()<UITableViewDataSource,UITableViewDelegate>

@property (nonatomic, strong) NSMutableArray<MainModel*> *dataArr;
@property (weak, nonatomic) IBOutlet UITableView *tableView;

@end

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.dataArr = @[].mutableCopy;

    
    [LCApplication setApplicationId:@"9ecsHLk6s4l4XCtswcGR0MN3-gzGzoHsz"
                          clientKey:@"aMv5I6qTiBcjIQjm3RhH38Cd"
                    serverURLString:@"https://9ecshlk6.lc-cn-n1-shared.com"];
    
    LCQuery *query = [LCQuery queryWithClassName:@"main"];
    [query findObjectsInBackgroundWithBlock:^(NSArray<LCObject*> * _Nullable objects, NSError * _Nullable error) {
        [objects enumerateObjectsUsingBlock:^(LCObject * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            MainModel *model = [MainModel mj_objectWithKeyValues:[obj dictionaryForObject]];
            [self.dataArr addObject:model];
        }];
        
        
        NSDateFormatter *formatter = NSDateFormatter.new;
        formatter.dateFormat = @"yyyy-MM-dd";
[        self.dataArr sortUsingComparator:^NSComparisonResult(MainModel * obj1, MainModel * obj2) {
    NSDate *d1 = [formatter dateFromString:obj1.date];
    NSDate *d2 = [formatter dateFromString:obj2.date];
    return d1.timeIntervalSince1970<d2.timeIntervalSince1970;
        }];
        [self reload];
                
    }];
    
}

-(void)reload{
    self.tableView.dataSource=self;
    self.tableView.delegate=self;
    
    
    NSString *identifier = NSStringFromClass(MainTableViewCell.class);
    UINib *nib=    [UINib nibWithNibName:identifier bundle:NSBundle.mainBundle];
    [self.tableView registerNib:nib forCellReuseIdentifier:identifier];
    
    self.tableView.rowHeight = 80;
    
    [self.tableView reloadData];
    
    
}

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.dataArr.count;
    
    
}


-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    MainTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:NSStringFromClass(MainTableViewCell.class)];
    
    MainModel *model = self.dataArr[indexPath.row];
    cell.label.text = model.date;
    
    return cell;
}


-(void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    DetailViewController *detail = DetailViewController.new;
    
    
    MainModel *model = self.dataArr[indexPath.row];
    detail.model = model;
    
    
    
    [self.navigationController pushViewController:detail animated:YES];
}


@end

