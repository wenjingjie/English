//
//  DetailViewController.m
//  English
//
//  Created by wangshengfeng on 2023/12/7.
//

#import "DetailViewController.h"

#import "MainModel.h"


#import "DetailTableViewCell.h"

@interface DetailViewController ()<UITableViewDataSource,UITableViewDelegate>

@property (nonatomic, copy) NSArray<MainDataModel*> *dataArr;

@property (weak, nonatomic) IBOutlet UITableView *tableView;

@end

@implementation DetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    
    
    self.dataArr = self.model.data;
    
    
    
    self.tableView.dataSource=self;
    self.tableView.delegate=self;
    
    
    NSString *identifier = NSStringFromClass(DetailTableViewCell.class);
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
    DetailTableViewCell*cell = [tableView dequeueReusableCellWithIdentifier:NSStringFromClass(DetailTableViewCell.class)];
    
    
    MainDataModel *model = self.dataArr[indexPath.row];
    cell.label .text = model.text;
    
    
    return cell;
}

-(void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    MainDataModel *model = self.dataArr[indexPath.row];
}

@end
