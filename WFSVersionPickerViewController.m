#import "WFSVersionPickerViewController.h"

@interface WFSVersionPickerViewController () <UISearchResultsUpdating>
@property(nonatomic, strong) NSArray *versions;
@property(nonatomic, strong) NSArray *filteredVersions;
@property(nonatomic, strong) UISearchController *searchController;
@end

@implementation WFSVersionPickerViewController

- (instancetype)initWithVersions:(NSArray *)versions
					  completion:(WFSVersionPickerCompletion)completion
{
	UITableViewStyle style = UITableViewStyleGrouped;
	if (@available(iOS 13.0, *))
	{
		style = (UITableViewStyle)2;
	}
	self = [super initWithStyle:style];
	if (self)
	{
		_versions = versions ?: @[];
		_filteredVersions = _versions;
		_completionHandler = completion;
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Select Version";
	[self.tableView registerClass:[UITableViewCell class]
		   forCellReuseIdentifier:@"VersionCell"];
	UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc]
		initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
							 target:self
							 action:@selector(cancelTapped)];
	self.navigationItem.leftBarButtonItem = cancelButton;

	self.searchController =
		[[UISearchController alloc] initWithSearchResultsController:nil];
	self.searchController.searchResultsUpdater = self;
	if ([self.searchController respondsToSelector:@selector(setObscuresBackgroundDuringPresentation:)])
	{
		self.searchController.obscuresBackgroundDuringPresentation = NO;
	}
	self.searchController.searchBar.placeholder = @"Search versions";

	if ([self.navigationItem respondsToSelector:@selector(setSearchController:)])
	{
		self.navigationItem.searchController = self.searchController;
		self.navigationItem.hidesSearchBarWhenScrolling = NO;
	}
	self.definesPresentationContext = YES;
}

- (void)cancelTapped
{
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:
	(UISearchController *)searchController
{
	NSString *query = searchController.searchBar.text;

	if (query.length == 0)
	{
		self.filteredVersions = self.versions;
		[self.tableView reloadData];
		return;
	}

	NSString *needle = query.lowercaseString;
	NSMutableArray *results = [NSMutableArray array];

	for (NSDictionary *version in self.versions)
	{
		NSString *bundleVersion = [NSString
			stringWithFormat:@"%@", version[@"bundle_version"] ?: @""];
		NSString *externalIdentifier = [NSString
			stringWithFormat:@"%@", version[@"external_identifier"] ?: @""];

		NSString *haystack =
			[[NSString stringWithFormat:@"%@ %@", bundleVersion,
										externalIdentifier] lowercaseString];

		if ([haystack containsString:needle])
		{
			[results addObject:version];
		}
	}

	self.filteredVersions = results;
	[self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
	numberOfRowsInSection:(NSInteger)section
{
	return self.filteredVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
		 cellForRowAtIndexPath:(NSIndexPath *)indexPath
{

	UITableViewCell *cell =
		[tableView dequeueReusableCellWithIdentifier:@"VersionCell"
										forIndexPath:indexPath];

	NSDictionary *version = self.filteredVersions[indexPath.row];
	NSString *bundleVersion =
		[NSString stringWithFormat:@"%@", version[@"bundle_version"] ?: @""];
	NSString *externalIdentifier = [NSString
		stringWithFormat:@"%@", version[@"external_identifier"] ?: @""];
	cell.textLabel.text = bundleVersion.length > 0 ? bundleVersion : externalIdentifier;
	SEL monoFontSelector = NSSelectorFromString(@"monospacedDigitSystemFontOfSize:weight:");
	if ([UIFont respondsToSelector:monoFontSelector])
	{
		CGFloat fontSize = 15.0;
		CGFloat fontWeight = UIFontWeightRegular;
		uintptr_t sizeBits = 0;
		uintptr_t weightBits = 0;
		memcpy(&sizeBits, &fontSize, sizeof(CGFloat));
		memcpy(&weightBits, &fontWeight, sizeof(CGFloat));
		cell.textLabel.font = [UIFont performSelector:monoFontSelector withObject:(__bridge id)(void*)sizeBits withObject:(__bridge id)(void*)weightBits];
	}
	else
	{
		cell.textLabel.font = [UIFont systemFontOfSize:15];
	}
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	return cell;
}

- (void)tableView:(UITableView *)tableView
	didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NSDictionary *selected = self.filteredVersions[indexPath.row];
	[self dismissViewControllerAnimated:YES
							 completion:^{
							   if (self.completionHandler)
							   {
								   self.completionHandler(selected);
							   }
							 }];
}

- (NSString *)tableView:(UITableView *)tableView
	titleForHeaderInSection:(NSInteger)section
{
	if (self.searchController.searchBar.text.length > 0)
	{
		return [NSString
			stringWithFormat:@"%lu of %lu versions",
							 (unsigned long)self.filteredVersions.count,
							 (unsigned long)self.versions.count];
	}

	return [NSString stringWithFormat:@"%lu versions available",
									  (unsigned long)self.versions.count];
}

@end
