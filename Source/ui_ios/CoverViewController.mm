#import <SDWebImage/UIImageView+WebCache.h>
#import "CoverViewController.h"
#import "EmulatorViewController.h"
#import "SettingsViewController.h"
#import "../ui_shared/BootablesProcesses.h"
#import "../ui_shared/BootablesDbClient.h"
#import "PathUtils.h"
#import "BackgroundLayer.h"
#import "CoverViewCell.h"
#import "AltServerJitService.h"

#include <sys/mman.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif

// ---- Temporary JIT self-test (diagnostic) --------------------------------
// Probes each way of getting executable memory and reports the resulting page
// protection, WITHOUT executing (so it can't crash). 'x' in max protection
// means that method can produce runnable JIT memory on this device.
static NSString* SC_ProtString(vm_prot_t p)
{
	return [NSString stringWithFormat:@"%c%c%c",
		(p & VM_PROT_READ) ? 'r' : '-',
		(p & VM_PROT_WRITE) ? 'w' : '-',
		(p & VM_PROT_EXECUTE) ? 'x' : '-'];
}

static NSString* SC_QueryProt(void* mem)
{
	vm_address_t addr = (vm_address_t)(uintptr_t)mem;
	vm_size_t vmsize = 0;
	vm_region_basic_info_data_64_t info;
	mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
	mach_port_t obj = MACH_PORT_NULL;
	kern_return_t kr = vm_region_64(mach_task_self(), &addr, &vmsize,
		VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj);
	if(kr != KERN_SUCCESS) return @"prot=?";
	return [NSString stringWithFormat:@"prot=%@ max=%@",
		SC_ProtString(info.protection), SC_ProtString(info.max_protection)];
}

static NSString* SC_ProbeMapJit()
{
	const size_t sz = 16384;
	void* mem = mmap(NULL, sz, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANON|MAP_JIT, -1, 0);
	if(mem == MAP_FAILED) return [NSString stringWithFormat:@"MAP_JIT: mmap FAILED errno=%d", errno];
	typedef void (*wpfn)(int);
	wpfn wp = (wpfn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
	uint32_t code[2] = {0x52800540u, 0xD65F03C0u};
	if(wp) wp(0);
	memcpy(mem, code, sizeof(code));
	if(wp) wp(1);
	NSString* r = [NSString stringWithFormat:@"MAP_JIT(wp=%@): %@", wp?@"y":@"NIL", SC_QueryProt(mem)];
	munmap(mem, sz);
	return r;
}

static NSString* SC_ProbeRWX()
{
	const size_t sz = 16384;
	void* mem = mmap(NULL, sz, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANON, -1, 0);
	if(mem == MAP_FAILED) return [NSString stringWithFormat:@"RWX: mmap FAILED errno=%d", errno];
	uint32_t code[2] = {0x52800540u, 0xD65F03C0u};
	memcpy(mem, code, sizeof(code));
	NSString* r = [NSString stringWithFormat:@"RWX: %@", SC_QueryProt(mem)];
	munmap(mem, sz);
	return r;
}

static NSString* SC_ProbeMprotect()
{
	const size_t sz = 16384;
	void* mem = mmap(NULL, sz, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
	if(mem == MAP_FAILED) return [NSString stringWithFormat:@"mprot: mmap FAILED errno=%d", errno];
	uint32_t code[2] = {0x52800540u, 0xD65F03C0u};
	memcpy(mem, code, sizeof(code));
	int mp = mprotect(mem, sz, PROT_READ|PROT_EXEC);
	NSString* r = (mp != 0)
		? [NSString stringWithFormat:@"mprot RX: FAILED errno=%d", errno]
		: [NSString stringWithFormat:@"mprot RX: OK %@", SC_QueryProt(mem)];
	munmap(mem, sz);
	return r;
}
// --------------------------------------------------------------------------

static bool IsJitAvailable()
{
	//If ppid != 1, it means we're being run in the debugger
	if(getppid() != 1) return true;
	if([[AltServerJitService sharedAltServerJitService] jitEnabled])
	{
		return true;
	}
	{
		//Check if we can scan the mobile directory (only possible if jailbroken)
		std::error_code errorCode;
		fs::directory_iterator dirIterator("/private/var/mobile", errorCode);
		if(!errorCode)
		{
			return true;
		}
	}
	return false;
}

@interface CoverViewController ()

@end

@implementation CoverViewController

static NSString* const reuseIdentifier = @"coverCell";

- (void)buildCollectionWithForcedFullScan:(BOOL)forceFullDeviceScan
{
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Building collection" message:@"Please wait..." preferredStyle:UIAlertControllerStyleAlert];

	CGRect aivRect = CGRectMake(0, 0, 40, 40);

	UIActivityIndicatorView* aiv = [[UIActivityIndicatorView alloc] initWithFrame:aivRect];
	[aiv startAnimating];

	UIViewController* vc = [[UIViewController alloc] init];
	vc.preferredContentSize = aivRect.size;
	[vc.view addSubview:aiv];
	[alert setValue:vc forKey:@"contentViewController"];

	[self presentViewController:alert animated:YES completion:nil];

	dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	dispatch_async(queue, ^{
	  auto activeDirs = GetActiveBootableDirectories();
	  if(forceFullDeviceScan)
	  {
		  dispatch_async(dispatch_get_main_queue(), ^{
			alert.message = @"Scanning games on filesystem...";
		  });
		  ScanBootables("/private/var/mobile");
	  }
	  else if(!activeDirs.empty())
	  {
		  dispatch_async(dispatch_get_main_queue(), ^{
			alert.message = @"Scanning games in active directories...";
		  });
		  for(const auto& activeDir : activeDirs)
		  {
			  ScanBootables(activeDir, false);
		  }
	  }

	  //Always scan games in app storage. The app's path change when it's reinstalled,
	  //thus, games from the previous installation won't be found (will be deleted in PurgeInexistingFiles).
	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Scanning games in app storage...";
	  });
	  ScanBootables(Framework::PathUtils::GetPersonalDataPath());

	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Purging inexisting files...";
	  });
	  PurgeInexistingFiles();

	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Fetching game titles...";
	  });
	  FetchGameTitles();

	  if(_bootables)
	  {
		  delete _bootables;
		  _bootables = nullptr;
	  }
	  _bootables = new BootableArray(BootablesDb::CClient::GetInstance().GetBootables());

	  //Done
	  dispatch_async(dispatch_get_main_queue(), ^{
		[alert dismissViewControllerAnimated:YES completion:nil];
		[self.collectionView reloadData];
	  });
	});
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	CAGradientLayer* bgLayer = [BackgroundLayer blueGradient];
	bgLayer.frame = self.view.bounds;
	[self.view.layer insertSublayer:bgLayer atIndex:0];

	self.collectionView.allowsMultipleSelection = NO;
	if(@available(iOS 11.0, *))
	{
		self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
	}

	[[AltServerJitService sharedAltServerJitService] startProcess];
	[self buildCollectionWithForcedFullScan:NO];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	static BOOL s_jitTestShown = NO;
	if(s_jitTestShown) return;
	s_jitTestShown = YES;

	NSMutableArray* lines = [NSMutableArray array];
	[lines addObject:[NSString stringWithFormat:@"ppid=%d", getppid()]];
	[lines addObject:SC_ProbeMapJit()];
	[lines addObject:SC_ProbeRWX()];
	[lines addObject:SC_ProbeMprotect()];
	NSString* msg = [lines componentsJoinedByString:@"\n"];

	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"JIT Self-Test"
		message:msg preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidUnload
{
	assert(_bootables != nullptr);
	delete _bootables;

	[super viewDidUnload];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
	// resize your layers based on the view’s new bounds
	[[[self.view.layer sublayers] objectAtIndex:0] setFrame:self.view.bounds];
}

- (BOOL)shouldAutorotate
{
	if([self isViewLoaded] && self.view.window)
	{
		return YES;
	}
	else
	{
		return NO;
	}
}

#pragma mark <UICollectionViewDataSource>

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView*)collectionView
{
	return 1;
}

- (NSString*)collectionView:(UICollectionView*)collectionView titleForHeaderInSection:(NSInteger)section
{
	return @"";
}

- (NSInteger)collectionView:(UICollectionView*)collectionView numberOfItemsInSection:(NSInteger)section
{
	return _bootables ? _bootables->size() : 0;
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)collectionView cellForItemAtIndexPath:(NSIndexPath*)indexPath
{
	CoverViewCell* cell = (CoverViewCell*)[collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifier forIndexPath:indexPath];

	auto bootable = (*_bootables)[indexPath.row];
	UIImage* placeholder = [UIImage imageNamed:@"boxart.png"];
	cell.nameLabel.text = [NSString stringWithUTF8String:bootable.title.c_str()];
	cell.backgroundView = [[UIImageView alloc] initWithImage:placeholder];

	if(!bootable.coverUrl.empty())
	{
		NSString* coverUrl = [NSString stringWithUTF8String:bootable.coverUrl.c_str()];
		[(UIImageView*)cell.backgroundView sd_setImageWithURL:[NSURL URLWithString:coverUrl] placeholderImage:placeholder];
	}

	return cell;
}

#pragma mark <UICollectionViewDelegate>

- (BOOL)shouldPerformSegueWithIdentifier:(NSString*)identifier sender:(id)sender
{
	if([identifier isEqualToString:@"showEmulator"] && !IsJitAvailable())
	{
		UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"JIT unavailable" message:@"JIT doesn't seem to be available at the moment. If JIT is not available, the emulator will crash. Do you wish to continue?" preferredStyle:UIAlertControllerStyleAlert];
		{
			UIAlertAction* continueAction = [UIAlertAction
			    actionWithTitle:@"Continue"
			              style:UIAlertActionStyleDefault
			            handler:^(UIAlertAction*) {
				          [self performSegueWithIdentifier:@"showEmulator" sender:sender];
			            }];
			[alert addAction:continueAction];
		}
		{
			UIAlertAction* cancelAction = [UIAlertAction
			    actionWithTitle:@"Cancel"
			              style:UIAlertActionStyleCancel
			            handler:^(UIAlertAction*){}];
			[alert addAction:cancelAction];
		}
		{
			UIAlertAction* helpAction = [UIAlertAction
			    actionWithTitle:@"Help"
			              style:UIAlertActionStyleDefault
			            handler:^(UIAlertAction*) {
				          [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/jpd002/Play-#running-on-ios"]];
			            }];
			[alert addAction:helpAction];
		}
		[self presentViewController:alert animated:YES completion:nil];
		return NO;
	}
	return YES;
}

- (void)prepareForSegue:(UIStoryboardSegue*)segue sender:(id)sender
{
	if([segue.identifier isEqualToString:@"showEmulator"])
	{
		NSIndexPath* indexPath = [[self.collectionView indexPathsForSelectedItems] objectAtIndex:0];
		auto bootable = (*_bootables)[indexPath.row];
		BootablesDb::CClient::GetInstance().SetLastBootedTime(bootable.path, time(nullptr));
		EmulatorViewController* emulatorViewController = segue.destinationViewController;
		emulatorViewController.bootablePath = [NSString stringWithUTF8String:bootable.path.native().c_str()];
		[self.collectionView deselectItemAtIndexPath:indexPath animated:NO];
	}
	else if([segue.identifier isEqualToString:@"showSettings"])
	{
		UINavigationController* navViewController = segue.destinationViewController;
		SettingsViewController* settingsViewController = (SettingsViewController*)navViewController.visibleViewController;
		settingsViewController.allowFullDeviceScan = true;
		settingsViewController.allowGsHandlerSelection = true;
		settingsViewController.completionHandler = ^(bool fullScanRequested) {
		  [[AltServerJitService sharedAltServerJitService] startProcess];
		  if(fullScanRequested)
		  {
			  [self buildCollectionWithForcedFullScan:YES];
		  }
		};
	}
}

- (IBAction)onExit:(id)sender
{
	exit(0);
}

@end
