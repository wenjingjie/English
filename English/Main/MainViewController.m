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

@interface MainViewController ()<UITableViewDataSource,UITableViewDelegate>

@property (nonatomic, copy) NSArray<MainModel*> *dataArr;
@property (weak, nonatomic) IBOutlet UITableView *tableView;

@end

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    
    
    
    NSString *path = [NSBundle.mainBundle pathForResource:@"DATASOURCE" ofType:@""];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
    self.dataArr = [MainModel mj_objectArrayWithKeyValuesArray:arr ];
    
    
    
    
    self.tableView.dataSource=self;
    self.tableView.delegate=self;
    
    
    NSString *identifier = NSStringFromClass(MainTableViewCell.class);
    UINib *nib=    [UINib nibWithNibName:identifier bundle:NSBundle.mainBundle];
    [self.tableView registerNib:nib forCellReuseIdentifier:identifier];
    
    [self.tableView reloadData];
    
    self.tableView.rowHeight = 80;
    
    
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

