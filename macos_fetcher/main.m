//
//  main.m
//  macos_fetcher
//
//  Created by Julien-Pierre Avérous on 10/11/2018.
//  Copyright © 2018 SourceMac. All rights reserved.
//

#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <getopt.h>



/*
** Defines
*/
#pragma mark - Defines

#define MFCatalogURLString @"https://swscan.apple.com/content/catalogs/others/index-10.15seed-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz"

#define MFDynamicCast(Class, Object) ({ id __obj = (Object); ([__obj isKindOfClass:[Class class]] ? ((Class *)(__obj)) : nil); })



/*
** Helper
*/
#pragma mark - Helper

static inline void _execBlock (__strong dispatch_block_t *block) {
	(*block)();
}

#define __concat_(A, B) A ## B
#define __concat(A, B) __concat_(A, B)

#define _onExit \
	__strong dispatch_block_t __concat(_exitBlock_, __LINE__) __attribute__((cleanup(_execBlock), unused)) = ^


@interface MFURLSessionDownloadTask : NSObject <NSURLSessionDownloadDelegate>
- (instancetype)initWithTemporaryDirectoryURL:(NSURL *)temporaryDirectoryURL;
- (NSURL *)synchronouslyDownloadURL:(NSURL *)url targetDirectory:(NSURL *)targetDirectoryURL error:(NSError **)error updateHandler:(void (^)(uint64_t totalBytesWritten, uint64_t totalBytesExpectedToWrite))handler;
@end



/*
** Main
*/
#pragma mark - Main

int main(int argc, const char * argv[])
{
	NSError *error = nil;
	
	// Parse parameters.
	dispatch_block_t usage = ^{
		fprintf(stderr, "Usage: %s <options>\n", getprogname());
		fprintf(stderr, "  -o / --output path           Directory on which the installer should be saved. Default: user downloads directory.\n");
		fprintf(stderr, "  -c / --catalog URL           Catalog to use. Default: 10.9 to 10.14 merged catalog.\n");
		fprintf(stderr, "  -s / --select build/id       Pre-select which product to use. Can be a macOS build number or a catalog product id. Default: ask interactively.\n");
		fprintf(stderr, "  -v / --version               Print current version.\n");
	};
	
	int			ch;
	NSURL		*targetDirectoryURL = nil;
	NSURL		*catalogURL = nil;
	NSString	*selectKey = nil;
	
	struct option longopts[] = {
		{ "output",		required_argument,	NULL,	'o' },
		{ "catalog",	required_argument,	NULL,	'c' },
		{ "select",		required_argument,	NULL,	's' },
		{ "version",	no_argument,		NULL,	'v' },
		{ NULL,			0,					NULL,	0 }
	};

	while ((ch = getopt_long(argc, (char * const *)argv, "o:c:s:v", longopts, NULL)) != -1)
	{
		switch (ch)
		{
			case 'o':
				targetDirectoryURL = [NSURL fileURLWithPath:@(optarg)];
				break;
				
			case 'c':
				catalogURL = [NSURL URLWithString:@(optarg)];
				break;
				
			case 's':
				selectKey = @(optarg);
				break;
				
			case 'v':
			{
				NSBundle *bundle = [NSBundle mainBundle];
				NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
				
				fprintf(stdout, "macos_fetcher version %s\n", version.UTF8String);
				
				return 0;
			}

			default:
				usage();
				return 2;
		}
	}
	
	// > Check target directory.
	BOOL isDirectory = NO;

	if (!targetDirectoryURL)
		targetDirectoryURL = [NSURL fileURLWithPath:[@"~/Downloads/" stringByExpandingTildeInPath]];

	if ([[NSFileManager defaultManager] fileExistsAtPath:targetDirectoryURL.path isDirectory:&isDirectory] && isDirectory == NO)
	{
		fprintf(stderr, "Error: Target should be a directory.\n");
		return 1;
	}
	
	// > Check catalog.
	if (!catalogURL)
		catalogURL = [NSURL URLWithString:MFCatalogURLString];
	
	
	// Download catalog.
	fprintf(stderr, "[+] Downloading the catalog file...\n");
	
	NSData *catalogData = [NSData dataWithContentsOfURL:catalogURL options:0 error:&error];
	
	if (!catalogData)
	{
		fprintf(stderr, "[-] Cannot download the catalog file (%s).\n", error.localizedDescription.UTF8String);
		return 1;
	}
	
	
	// Parse catalog.
	fprintf(stderr, "[+] Parsing the catalog file...\n");

	id plist = [NSPropertyListSerialization propertyListWithData:catalogData options:0 format:nil error:&error];
	
	if (!plist)
	{
		fprintf(stderr, "[-] Cannot parse the catalog file (%s).\n", error.localizedDescription.UTF8String);
		return 1;
	}
	
	
	// Search macOS installers.
	fprintf(stderr, "[+] Searching for macOS installer in catalog...\n");

	NSDictionary 		*catalogRoot = MFDynamicCast(NSDictionary, plist);
	NSDictionary		*products = MFDynamicCast(NSDictionary, catalogRoot[@"Products"]);
	NSMutableDictionary	*macosProducts = [[NSMutableDictionary alloc] init];
	
	if (!products)
	{
		fprintf(stderr, "[-] Unexpected catalog format ('Products' not found).\n");
		return 1;
	}
	
	for (NSString *productId in products)
	{
		NSDictionary *product = MFDynamicCast(NSDictionary, products[productId]);
		
		// > Search package URLs.
		NSArray	*packages = MFDynamicCast(NSArray, product[@"Packages"]);
		NSURL	*recoveryMetaURL = nil;
		NSURL	*installAssistantAutoURL = nil;
		NSURL	*installESDURL = nil;

		for (id entry in packages)
		{
			NSDictionary	*package = MFDynamicCast(NSDictionary, entry);
			NSString		*urlString =  MFDynamicCast(NSString, package[@"URL"]);
			
			if ([[urlString lastPathComponent] isEqualToString:@"RecoveryHDMetaDmg.pkg"])
				recoveryMetaURL = [NSURL URLWithString:urlString];
			else if ([[urlString lastPathComponent] isEqualToString:@"InstallAssistantAuto.pkg"])
				installAssistantAutoURL = [NSURL URLWithString:urlString];
			else if ([[urlString lastPathComponent] isEqualToString:@"InstallESDDmg.pkg"])
				installESDURL = [NSURL URLWithString:urlString];
		}
		
		if (!recoveryMetaURL || !installAssistantAutoURL || !installESDURL)
			continue;
		
		// > Search distribution info.
		NSDictionary	*distributions = MFDynamicCast(NSDictionary, product[@"Distributions"]);
		NSString		*distributionURLString = MFDynamicCast(NSString, distributions[@"no"]);
		
		if (!distributionURLString)
			continue;
		
		// > Retain this product.
		NSMutableDictionary *macosProduct = [[NSMutableDictionary alloc] init];
		
		macosProduct[@"recoveryMetaURL"] = recoveryMetaURL;
		macosProduct[@"installAssistantAutoURL"] = installAssistantAutoURL;
		macosProduct[@"installESDURL"] = installESDURL;
		macosProduct[@"distributionURL"] = [NSURL URLWithString:distributionURLString];
		
		macosProducts[productId] = macosProduct;
	}
	
	if (macosProducts.count == 0)
	{
		fprintf(stderr, "[-] Cannot find valid macOS installer in catalog.\n");
		return 1;
	}
	
	fprintf(stderr, "[#] Found %lu macOS installers.\n", macosProducts.count);
	
	
	// Fetch product info.
	NSArray *productKeys = [macosProducts allKeys];

	fprintf(stderr, "[+] Gathering macOS installers informations...\n");
	
	for (NSString *productKey in productKeys)
	{
		NSMutableDictionary *macosProduct = macosProducts[productKey];
		
		// > Fetch dist data.
		NSURL	*distributionURL = macosProduct[@"distributionURL"];
		NSData	*distributionData = [NSData dataWithContentsOfURL:distributionURL options:0 error:&error];
		
		if (!distributionData)
		{
			fprintf(stderr, "[~] Cannot fetch information %s (%s).\n", productKey.UTF8String, error.description.UTF8String);
			[macosProducts removeObjectForKey:productKey];
			continue;
		}
		
		// > Parse content.
		NSXMLDocument *distribution = [[NSXMLDocument alloc] initWithData:distributionData options:NSXMLNodeOptionsNone error:&error];
		
		if (!distribution)
		{
			fprintf(stderr, "[~] Cannot parse information %s (%s).\n", productKey.UTF8String, error.description.UTF8String);
			[macosProducts removeObjectForKey:productKey];
			continue;
		}
		
		// > Search content.
		NSXMLElement	*rootElement = distribution.rootElement;
		NSXMLNode		*auxInfoNode = [[rootElement nodesForXPath:@"/installer-gui-script/auxinfo/*" error:&error] firstObject];
		NSString		*auxInfoString = auxInfoNode.XMLString;
		
		if (!auxInfoString)
		{
			fprintf(stderr, "[~] Cannot extract auxiliary information %s (%s).\n", productKey.UTF8String, error.description.UTF8String);
			[macosProducts removeObjectForKey:productKey];
			continue;
		}
		
		// > Parse aux content.
		NSData	*auxInfoData = [auxInfoString dataUsingEncoding:NSUTF8StringEncoding];
		id 		auxInfoPlist = [NSPropertyListSerialization propertyListWithData:auxInfoData options:0 format:nil error:&error];
		
		if (!auxInfoPlist)
		{
			fprintf(stderr, "[~] Cannot parse auxiliary information %s (%s).\n", productKey.UTF8String, error.description.UTF8String);
			[macosProducts removeObjectForKey:productKey];
			continue;
		}
		
		// > Extract aux content.
		NSDictionary 	*auxInfo = MFDynamicCast(NSDictionary, auxInfoPlist);
		NSString		*auxInfoBuild = MFDynamicCast(NSString, auxInfo[@"BUILD"]);
		NSString		*auxInfoVersion = MFDynamicCast(NSString, auxInfo[@"VERSION"]);
		
		if (!auxInfoVersion || !auxInfoBuild)
		{
			fprintf(stderr, "[~] Cannnot extract auxiliary information content %s (%s).\n", productKey.UTF8String, error.description.UTF8String);
			[macosProducts removeObjectForKey:productKey];
			continue;
		}

		// > Store result.
		macosProduct[@"build"] = auxInfoBuild;
		macosProduct[@"version"] = auxInfoVersion;
	}

	
	// Select the product.
	NSDictionary *macosProductSelected = nil;
	
	// > Helper.
	__auto_type productSearch = ^ NSDictionary * (NSString *token) {
		
		NSDictionary *result = macosProducts[token];
		
		if (result)
			return result;

		for (NSString *productKey in macosProducts)
		{
			NSDictionary	*macosProduct = macosProducts[productKey];
			NSString		*build = macosProduct[@"build"];
			
			if ([build isEqualToString:token])
				return macosProduct;
		}
		
		return nil;
	};
	
	// > Use command argument or ask user.
	if (selectKey)
	{
		macosProductSelected = productSearch(selectKey);
		
		if (!macosProductSelected)
		{
			fprintf(stderr, "[-] The build number or product-id '%s' cannot be found.\n", selectKey.UTF8String);
			return 1;
		}
	}
	else
	{
		fprintf(stderr, "[#] Please enter the build number or product-id of the version you want to download:\n");
		
		// > Short by build number.
		NSArray *sortedMacosProductsKeys = [[macosProducts allKeys] sortedArrayUsingComparator:^NSComparisonResult(id  key1, id key2) {
			NSDictionary *item1 = macosProducts[key1];
			NSDictionary *item2 = macosProducts[key2];
			
			return [item1[@"build"] compare:item2[@"build"] options:NSNumericSearch];
		}];
		
		// > Show what we found.
		for (NSString *productKey in sortedMacosProductsKeys)
		{
			NSDictionary	*macosProduct = macosProducts[productKey];
			NSString		*build = macosProduct[@"build"];
			NSString		*version = macosProduct[@"version"];
			
			fprintf(stderr, "  > macOS %s (%s):\t%s\n", version.UTF8String, build.UTF8String, productKey.UTF8String);
		}
		
		// > Ask for selection
		while (!macosProductSelected)
		{
			// > Prompt.
			fprintf(stderr, "Selection: ");
			
			// > Read line.
			char 	*cline = NULL;
			size_t	linecap = 0;
			ssize_t	sz = getline(&cline, &linecap, stdin);
			
			if (sz == -1 || cline == NULL)
				return 2;
			
			// > Fetch product.
			NSString *line = [[NSString alloc] initWithBytes:cline length:sz encoding:NSASCIIStringEncoding];

			macosProductSelected = productSearch([line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
			
			if (!macosProductSelected)
				fprintf(stderr, "[~] Product not found. Please retry.\n");
		}
	}
	
	fprintf(stderr, "[#] You selected macOS %s (%s).\n", [macosProductSelected[@"version"] UTF8String], [macosProductSelected[@"build"] UTF8String]);
	
	
	// Prepare tmp directory.
	NSURL *tempDirectoryURL = [targetDirectoryURL URLByAppendingPathComponent:@".temp_macos_fetcher"];
	
	[[NSFileManager defaultManager] removeItemAtURL:tempDirectoryURL error:nil];
	
	if ([[NSFileManager defaultManager] createDirectoryAtURL:tempDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error] == NO)
	{
		fprintf(stderr, "[-] Cannot create temporary directory in the target directory.\n");
		return 1;
	}
	
	_onExit {
		[[NSFileManager defaultManager] removeItemAtURL:tempDirectoryURL error:nil];
	};

	
	// Create temporary download directory.
	NSURL *tempDownloadDirectoryURL = [tempDirectoryURL URLByAppendingPathComponent:@"cfnetwork"];
	
	[[NSFileManager defaultManager] createDirectoryAtURL:tempDownloadDirectoryURL withIntermediateDirectories:YES attributes:nil error:nil];
	
	
	// Download files.
	MFURLSessionDownloadTask	*downloadTask = [[MFURLSessionDownloadTask alloc] initWithTemporaryDirectoryURL:tempDownloadDirectoryURL];
	NSMutableDictionary			*downloadedDict = [[NSMutableDictionary alloc] init];

	NSArray *downloadArray = @[
		@{ @"key" : @"installAssistantAutoURL",	@"url" : macosProductSelected[@"installAssistantAutoURL"] },
		@{ @"key" : @"recoveryMetaURL", 		@"url" : macosProductSelected[@"recoveryMetaURL"] },
		@{ @"key" : @"installESDURL", 			@"url" : macosProductSelected[@"installESDURL"] }
	];
	
	for (NSDictionary *downloadDescriptor in downloadArray)
	{
		NSString	*downloadKey = downloadDescriptor[@"key"];
		NSURL 		*downloadUrl = downloadDescriptor[@"url"];
		
		fprintf(stderr, "[+] Downloading %s...", downloadUrl.lastPathComponent.UTF8String);

		NSURL *targetURL = [downloadTask synchronouslyDownloadURL:downloadUrl targetDirectory:tempDirectoryURL error:&error updateHandler:^(uint64_t totalBytesWritten, uint64_t totalBytesExpectedToWrite) {
			char 		progressBar[21];
			double		percent = (double)MIN(totalBytesWritten, totalBytesExpectedToWrite) / (double)totalBytesExpectedToWrite;
			uint64_t	barSize = percent * 20.0;
			
			memset(progressBar, ' ', sizeof(progressBar));
			memset(progressBar, '=', barSize);
			progressBar[sizeof(progressBar) - 1] = 0;
			
			fprintf(stderr, "\r[+] Downloading %s [%s] %u%%", downloadUrl.lastPathComponent.UTF8String, progressBar, (unsigned)(percent * 100.0));
		}];
		
		fprintf(stderr, "\n");
		
		if (!targetURL)
		{
			fprintf(stderr, "[-] Cannot download %s (%s).\n", downloadUrl.lastPathComponent.UTF8String, error.localizedDescription.UTF8String);
			return 1;
		}
		
		downloadedDict[downloadKey] = targetURL;
	}
	
	
	// Extract install assistant app.
	NSTask	*taskPkgExtract = [[NSTask alloc] init];
	NSURL	*inputInstallAssistantArchiveFileURL = downloadedDict[@"installAssistantAutoURL"];
	NSURL	*outputInstallAssistantDirectoryURL = [tempDirectoryURL URLByAppendingPathComponent:@"InstallAssistantAuto"];

	fprintf(stderr, "[+] Extracting install assistant application...\n");
	
	taskPkgExtract.launchPath = @"/usr/sbin/pkgutil";
	taskPkgExtract.arguments = @[ @"--expand-full", inputInstallAssistantArchiveFileURL.path, outputInstallAssistantDirectoryURL.path ];
	taskPkgExtract.standardInput = [NSFileHandle fileHandleWithNullDevice];
	taskPkgExtract.standardOutput = [NSFileHandle fileHandleWithNullDevice];
	taskPkgExtract.standardError = [NSFileHandle fileHandleWithNullDevice];

	[taskPkgExtract launch];
	[taskPkgExtract waitUntilExit];
	
	if (taskPkgExtract.terminationStatus != 0)
	{
		fprintf(stderr, "[-] Cannot extract install assistant application.\n");
		return 1;
	}

	
	// Search install assistant app.
	NSDirectoryEnumerator<NSURL *> *outputInstallAssistantDirectoryEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:outputInstallAssistantDirectoryURL includingPropertiesForKeys:nil options:0 errorHandler:nil];
	NSBundle *installAssistantAppBundle = nil;

	fprintf(stderr, "[+] Locate install assistant application...\n");

	for (NSURL *url in outputInstallAssistantDirectoryEnumerator)
	{
		NSBundle	*bundle = nil;
		NSNumber	*isDirectory = nil;

		[url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
		
		if ([isDirectory boolValue] == NO)
			continue;
		
		if ([url.pathExtension isEqualToString:@"app"] == NO)
			continue;
		
		bundle = [NSBundle bundleWithURL:url];
		
		if ([bundle sharedSupportPath] == nil)
			continue;
		
		installAssistantAppBundle = bundle;
		break;
	}
	
	if (!installAssistantAppBundle)
	{
		fprintf(stderr, "[-] Cannot find install assistant application.\n");
		return 1;
	}
	
	
	// Attach recovery meta.
	NSTask	*taskRecoveryAttach = [[NSTask alloc] init];
	NSURL	*inputRecoveryMetaFileURL = downloadedDict[@"recoveryMetaURL"];
	NSURL	*outputRecoveryMetaMountURL = [tempDirectoryURL URLByAppendingPathComponent:@"RecoveryHDMetaDmg"];
	
	fprintf(stderr, "[+] Attach recovery image...\n");

	[[NSFileManager defaultManager] createDirectoryAtURL:outputRecoveryMetaMountURL withIntermediateDirectories:YES attributes:nil error:nil];
	
	taskRecoveryAttach.launchPath = @"/usr/bin/hdiutil";
	taskRecoveryAttach.arguments = @[ @"attach", @"-readonly", @"-mountpoint", outputRecoveryMetaMountURL.path, @"-nobrowse", inputRecoveryMetaFileURL.path ];
	taskRecoveryAttach.standardInput = [NSFileHandle fileHandleWithNullDevice];
	taskRecoveryAttach.standardOutput = [NSFileHandle fileHandleWithNullDevice];
	taskRecoveryAttach.standardError = [NSFileHandle fileHandleWithNullDevice];
	
	[taskRecoveryAttach launch];
	[taskRecoveryAttach waitUntilExit];
	
	if (taskRecoveryAttach.terminationStatus != 0)
	{
		fprintf(stderr, "[-] Cannot mount meta image disk.\n");
		return 1;
	}
	
	_onExit {
		NSTask *taskRecoveryDetach = [[NSTask alloc] init];
		
		taskRecoveryDetach.launchPath = @"/usr/bin/hdiutil";
		taskRecoveryDetach.arguments = @[ @"detach", outputRecoveryMetaMountURL.path, @"-force" ];
		taskRecoveryDetach.standardInput = [NSFileHandle fileHandleWithNullDevice];
		taskRecoveryDetach.standardOutput = [NSFileHandle fileHandleWithNullDevice];
		taskRecoveryDetach.standardError = [NSFileHandle fileHandleWithNullDevice];
		
		[taskRecoveryDetach launch];
		[taskRecoveryDetach waitUntilExit];
	};
	
	
	// Copy files to app.
	NSURL *installAssistantSharedSupportURL = [installAssistantAppBundle sharedSupportURL];
	
	__auto_type copyFile = ^ BOOL (NSURL *sourceDirURL, NSURL *targetDirURL, NSString *filename) {
		
		NSURL 	*sourceFileURL = [sourceDirURL URLByAppendingPathComponent:filename];
		NSURL 	*targetFileURL = [targetDirURL URLByAppendingPathComponent:filename];
		NSError	*copyError = nil;

		if ([[NSFileManager defaultManager] copyItemAtURL:sourceFileURL toURL:targetFileURL error:&copyError] == NO)
		{
			fprintf(stderr, "[-] Cannot copy file '%s' (%s).\n", filename.UTF8String, copyError.description.UTF8String);
			return NO;
		}
		
		return YES;
	};
	
	fprintf(stderr, "[+] Copy files into install assistant application...\n");

	// > Recoveries.
	if (copyFile(outputRecoveryMetaMountURL, installAssistantSharedSupportURL, @"AppleDiagnostics.chunklist") == NO)
		return 1;
	
	if (copyFile(outputRecoveryMetaMountURL, installAssistantSharedSupportURL, @"AppleDiagnostics.dmg") == NO)
		return 1;
	
	if (copyFile(outputRecoveryMetaMountURL, installAssistantSharedSupportURL, @"BaseSystem.chunklist") == NO)
		return 1;
	
	if (copyFile(outputRecoveryMetaMountURL, installAssistantSharedSupportURL, @"BaseSystem.dmg") == NO)
		return 1;

	// > ESD image.
	NSURL *inputESDFileURL = downloadedDict[@"installESDURL"];
	NSURL *outputESDFileURL = [installAssistantSharedSupportURL URLByAppendingPathComponent:@"InstallESD.dmg"];

	if ([[NSFileManager defaultManager] moveItemAtURL:inputESDFileURL toURL:outputESDFileURL error:&error] == NO)
	{
		fprintf(stderr, "[-] Cannot copy ESD image file (%s).\n", error.localizedDescription.UTF8String);
		return 1;
	}
	
	
	// Move install assistant app to target directory.
	NSURL *inputApplicationDirectoryURL = [installAssistantAppBundle bundleURL];
	NSURL *outputApplicationDirectoryURL = [targetDirectoryURL URLByAppendingPathComponent:inputApplicationDirectoryURL.lastPathComponent];
	
	if ([[NSFileManager defaultManager] moveItemAtURL:inputApplicationDirectoryURL toURL:outputApplicationDirectoryURL error:&error] == NO)
	{
		fprintf(stderr, "[-] Cannot move install assistant application to final directory.\n");
		return 1;
	}
	
	
	// Done.
	fprintf(stderr, "[#] Everything done with success. Your can find the installer at path '%s'.\n", outputApplicationDirectoryURL.fileSystemRepresentation);

	
	return 0;
}



/*
** MFURLSessionDownloadTask
*/
#pragma mark - MFURLSessionDownloadTask

@interface NSURLSessionConfiguration (Private)
- (void)set_directoryForDownloadedFiles:(id)arg1;
@end

@implementation MFURLSessionDownloadTask
{
	NSURLSession	*_urlSession;
	
	_Atomic(BOOL)	_isRunning;
	
	NSDate			*_lasUpdate;
	
	void (^_currentUpdateHandler)(uint64_t totalBytesWritten, uint64_t totalBytesExpectedToWrite);
	void (^_currentCompletionHandler)(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error);
}

- (instancetype)initWithTemporaryDirectoryURL:(NSURL *)temporaryDirectoryURL
{
	self = [super init];
	
	if (self)
	{
		NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
		
		if ([configuration respondsToSelector:@selector(set_directoryForDownloadedFiles:)])
			[configuration set_directoryForDownloadedFiles:temporaryDirectoryURL];
		else
			fprintf(stderr, "Warning: Cannot change default temporary download directory.\n");
		
		_urlSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
	}
	
	return self;
}

- (NSURL *)synchronouslyDownloadURL:(NSURL *)url targetDirectory:(NSURL *)targetDirectoryURL error:(NSError **)error updateHandler:(void (^)(uint64_t totalBytesWritten, uint64_t totalBytesExpectedToWrite))handler
{
	// Only one download at the same time.
	BOOL runningExpected = NO;
	
	if (atomic_compare_exchange_strong(&_isRunning, &runningExpected, YES) == NO)
	{
		if (error)
			*error = [NSError errorWithDomain:@"MFURLSessionDownloadTask" code:1 userInfo:@{ NSLocalizedFailureErrorKey: @"A download is already in progress." }];
		return nil;
	}
	
	// Set blocks.
	dispatch_semaphore_t	semaphore = dispatch_semaphore_create(0);
	__block NSURL			*resultURL = nil;
	__block NSError			*resultError = nil;
	
	__auto_type completionHandler = ^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
		if (location)
		{
			NSError	*subError;
			NSURL	*targetFileURL = [targetDirectoryURL URLByAppendingPathComponent:response.suggestedFilename];
			
			if ([[NSFileManager defaultManager] moveItemAtURL:location toURL:targetFileURL error:&subError])
				resultURL = targetFileURL;
			else
				resultError = subError;
		}
		else
			resultError = error;
		
		dispatch_semaphore_signal(semaphore);
	};
	
	_currentUpdateHandler = handler;
	_currentCompletionHandler = completionHandler;

	// Create task.
	NSURLSessionDownloadTask *downloadTask = [_urlSession downloadTaskWithURL:url];
	
	[downloadTask resume];
	
	// Wait.
	dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
	
	// Conclude download status.
	_currentUpdateHandler(downloadTask.countOfBytesReceived, downloadTask.countOfBytesExpectedToReceive);
	
	// Clean.
	_currentUpdateHandler = nil;
	_currentCompletionHandler = nil;
	_lasUpdate = nil;
	
	// Clean running flag.
	atomic_store(&_isRunning, NO);
	
	// Give result.
	if (error && resultError)
		*error = resultError;
		
	return resultURL;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
	NSDate *currentDate = [NSDate date];
	
	if (!_lasUpdate || [currentDate timeIntervalSinceDate:_lasUpdate] > 0.5)
	{
		_currentUpdateHandler(totalBytesWritten, totalBytesExpectedToWrite);
		_lasUpdate = currentDate;
	}
}

- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location
{
	_currentCompletionHandler(location, downloadTask.response, nil);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(nullable NSError *)error
{
	if (error)
		_currentCompletionHandler(nil, nil, error);
}

@end
