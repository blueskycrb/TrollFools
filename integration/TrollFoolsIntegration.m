#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

typedef void (*TFShowActionsIMP)(id, SEL, NSIndexPath *);
typedef void (*TFDidSelectIMP)(id, SEL, UITableView *, NSIndexPath *);
typedef void (*TFPresentIMP)(id, SEL, UIViewController *, BOOL, void (^)(void));
typedef int (*TFPersonaSetIMP)(posix_spawnattr_t *, uid_t, uint32_t);
typedef int (*TFPersonaIDIMP)(posix_spawnattr_t *, uid_t);

static TFShowActionsIMP TFOriginalShowActions;
static TFDidSelectIMP TFOriginalDidSelect;
static TFPresentIMP TFOriginalPresent;
static TFPresentIMP TFOriginalDelegatePresent;
static const void *TFInjectedActionsKey = &TFInjectedActionsKey;
static NSDictionary *TFPendingAppInfo;
static NSTimeInterval TFLastReconcileTime;

static NSString *TFText(NSString *english, NSString *chinese) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    return [language hasPrefix:@"zh"] ? chinese : english;
}

static NSURL *TFWorkingDirectory(void) {
    NSURL *url = [NSURL fileURLWithPath:@"/var/mobile/Library/Caches/com.opa334.TrollStore/TrollFoolsIntegration"
                           isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:url
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return url;
}

static UIViewController *TFTopViewController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateUnattached) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window) break;
    }
    if (!window) {
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
    }

    UIViewController *controller = window.rootViewController;
    while (controller) {
        if (controller.presentedViewController) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            controller = ((UINavigationController *)controller).visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else {
            break;
        }
    }
    return controller;
}

static void TFConfigurePopover(UIAlertController *alert, UIViewController *presenter) {
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (!popover) return;
    popover.sourceView = presenter.view;
    popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                    CGRectGetMidY(presenter.view.bounds), 1, 1);
    popover.permittedArrowDirections = 0;
}

static void TFPresentAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = TFTopViewController();
        if (!presenter) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:TFText(@"OK", @"\u786e\u5b9a")
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static NSString *TFStringFromObject(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id TFAppInfoAtIndexPath(id controller, NSIndexPath *indexPath) {
    NSArray *appInfos = nil;
    @try {
        appInfos = [controller valueForKey:@"cachedAppInfos"];
    } @catch (__unused NSException *exception) {
        @try {
            appInfos = [controller valueForKey:@"_cachedAppInfos"];
        } @catch (__unused NSException *innerException) {
            return nil;
        }
    }
    NSUInteger row = indexPath.row;
    if (row == NSNotFound && indexPath.item != NSNotFound) row = indexPath.item;
    if (![appInfos isKindOfClass:NSArray.class] || row == NSNotFound || row >= appInfos.count) return nil;
    return appInfos[row];
}

static NSString *TFValidatedBundleIdentifier(id appInfo) {
    NSString *identifier = TFStringFromObject(appInfo, NSSelectorFromString(@"bundleIdentifier"));
    if (identifier.length == 0 || identifier.length > 255) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound
        ? identifier
        : nil;
}

static void TFRunCLI(NSArray<NSString *> *arguments,
                     void (^completion)(int exitCode, NSString *output)) {
    NSArray<NSString *> *argumentsCopy = [arguments copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *binary = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"trollfoolscli"];
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:binary]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(127, TFText(@"trollfoolscli is missing.", @"\u7f3a\u5c11 trollfoolscli\u3002"));
            });
            return;
        }

        NSURL *logsURL = [TFWorkingDirectory() URLByAppendingPathComponent:@"Logs" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:logsURL
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
        NSURL *logURL = [logsURL URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
        int logFD = open(logURL.fileSystemRepresentation, O_CREAT | O_TRUNC | O_RDWR, 0600);
        if (logFD < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(126, @"Unable to create command log."); });
            return;
        }

        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFD);

        posix_spawnattr_t attributes;
        posix_spawnattr_init(&attributes);
        TFPersonaSetIMP setPersona = (TFPersonaSetIMP)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
        TFPersonaIDIMP setUID = (TFPersonaIDIMP)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
        TFPersonaIDIMP setGID = (TFPersonaIDIMP)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
        if (setPersona && setUID && setGID) {
            setPersona(&attributes, 99, 1);
            setUID(&attributes, 0);
            setGID(&attributes, 0);
        }

        NSMutableArray<NSString *> *allArguments = [NSMutableArray arrayWithObject:binary];
        [allArguments addObjectsFromArray:argumentsCopy];
        char **argv = calloc(allArguments.count + 1, sizeof(char *));
        for (NSUInteger index = 0; index < allArguments.count; index++) {
            argv[index] = strdup(allArguments[index].UTF8String);
        }

        pid_t pid = 0;
        int spawnResult = posix_spawn(&pid, binary.fileSystemRepresentation,
                                      &actions, &attributes, argv, environ);
        int status = 0;
        int exitCode = spawnResult;
        if (spawnResult == 0) {
            do {
                exitCode = waitpid(pid, &status, 0);
            } while (exitCode == -1 && errno == EINTR);
            if (exitCode >= 0) {
                exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
            }
        }

        for (NSUInteger index = 0; index < allArguments.count; index++) free(argv[index]);
        free(argv);
        posix_spawnattr_destroy(&attributes);
        posix_spawn_file_actions_destroy(&actions);
        close(logFD);

        NSData *logData = [NSData dataWithContentsOfURL:logURL options:0 error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:logURL error:nil];
        if (logData.length > 64 * 1024) {
            logData = [logData subdataWithRange:NSMakeRange(logData.length - 64 * 1024, 64 * 1024)];
        }
        NSString *output = [[NSString alloc] initWithData:logData encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(exitCode, output); });
    });
}

static UIAlertController *TFPresentProgress(NSString *title) {
    UIViewController *presenter = TFTopViewController();
    if (!presenter) return nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:TFText(@"Please wait...", @"\u8bf7\u7a0d\u5019...")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [presenter presentViewController:alert animated:YES completion:nil];
    return alert;
}

static void TFRunVisibleCommand(NSArray<NSString *> *arguments,
                                NSString *progressTitle,
                                NSString *successMessage,
                                void (^success)(NSString *output)) {
    UIAlertController *progress = TFPresentProgress(progressTitle);
    TFRunCLI(arguments, ^(int exitCode, NSString *output) {
        [progress dismissViewControllerAnimated:YES completion:^{
            if (exitCode == 0) {
                if (success) success(output);
                else TFPresentAlert(TFText(@"Completed", @"\u5df2\u5b8c\u6210"), successMessage);
            } else {
                NSString *message = output.length ? output : [NSString stringWithFormat:@"Exit code: %d", exitCode];
                TFPresentAlert(TFText(@"TrollFools failed", @"TrollFools \u6267\u884c\u5931\u8d25"), message);
            }
        }];
    });
}

@interface TFPluginPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *appName;
@end

static TFPluginPickerDelegate *TFPickerDelegate;

@implementation TFPluginPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSSet<NSString *> *allowedExtensions = [NSSet setWithArray:
        @[@"dylib", @"deb", @"zip", @"framework", @"bundle"]];
    NSURL *stagingURL = [TFWorkingDirectory() URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                                                              isDirectory:YES];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:stagingURL
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error]) {
        TFPresentAlert(TFText(@"Import failed", @"\u5bfc\u5165\u5931\u8d25"), error.localizedDescription);
        return;
    }

    NSMutableArray<NSString *> *stagedPaths = [NSMutableArray new];
    for (NSURL *url in urls) {
        NSString *extension = url.pathExtension.lowercaseString;
        NSString *name = url.lastPathComponent;
        if (![allowedExtensions containsObject:extension] || name.length == 0 ||
            [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            error = [NSError errorWithDomain:@"TrollFoolsIntegration" code:1
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        TFText(@"Unsupported plugin file.", @"\u4e0d\u652f\u6301\u7684\u63d2\u4ef6\u6587\u4ef6\u3002")}];
            break;
        }

        NSURL *destination = [stagingURL URLByAppendingPathComponent:name isDirectory:NO].standardizedURL;
        if (![destination.path hasPrefix:[stagingURL.path stringByAppendingString:@"/"]]) {
            error = [NSError errorWithDomain:@"TrollFoolsIntegration" code:2
                                    userInfo:@{NSLocalizedDescriptionKey:@"Invalid plugin path."}];
            break;
        }

        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        __block NSError *copyError = nil;
        [coordinator coordinateReadingItemAtURL:url options:0 error:&copyError byAccessor:^(NSURL *newURL) {
            [[NSFileManager defaultManager] copyItemAtURL:newURL toURL:destination error:&copyError];
        }];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (copyError) {
            error = copyError;
            break;
        }
        [stagedPaths addObject:destination.path];
    }

    if (error || stagedPaths.count == 0) {
        [[NSFileManager defaultManager] removeItemAtURL:stagingURL error:nil];
        TFPresentAlert(TFText(@"Import failed", @"\u5bfc\u5165\u5931\u8d25"),
                       error.localizedDescription ?: TFText(@"No plugin selected.", @"\u672a\u9009\u62e9\u63d2\u4ef6\u3002"));
        return;
    }

    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:
        @"inject", self.bundleIdentifier, @"--path", nil];
    [arguments addObjectsFromArray:stagedPaths];
    [arguments addObject:@"--weak"];
    NSString *success = [NSString stringWithFormat:
        TFText(@"Injected into %@.", @"\u5df2\u6ce8\u5165 %@\u3002"), self.appName];
    TFRunVisibleCommand(arguments,
                        TFText(@"Injecting with TrollFools", @"\u6b63\u5728\u4f7f\u7528 TrollFools \u6ce8\u5165"),
                        success,
                        ^(__unused NSString *output) {
        [[NSFileManager defaultManager] removeItemAtURL:stagingURL error:nil];
        TFPresentAlert(TFText(@"Completed", @"\u5df2\u5b8c\u6210"), success);
    });
}

@end

static void TFPresentPluginPicker(NSString *bundleIdentifier, NSString *appName) {
    NSMutableArray<UTType *> *types = [NSMutableArray new];
    for (NSString *extension in @[@"dylib", @"deb", @"zip", @"framework", @"bundle"]) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if (type) [types addObject:type];
    }
    if (types.count == 0) [types addObject:UTTypeData];

    TFPickerDelegate = [TFPluginPickerDelegate new];
    TFPickerDelegate.bundleIdentifier = bundleIdentifier;
    TFPickerDelegate.appName = appName ?: bundleIdentifier;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = TFPickerDelegate;
    [TFTopViewController() presentViewController:picker animated:YES completion:nil];
}

static NSArray *TFParsePluginJSON(NSString *output) {
    NSRange start = [output rangeOfString:@"["];
    NSRange end = [output rangeOfString:@"]" options:NSBackwardsSearch];
    if (start.location == NSNotFound || end.location == NSNotFound || end.location < start.location) return nil;
    NSString *json = [output substringWithRange:NSMakeRange(start.location, end.location - start.location + 1)];
    id object = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:nil];
    return [object isKindOfClass:NSArray.class] ? object : nil;
}

static void TFRemovePlugin(NSString *bundleIdentifier, NSString *path) {
    TFRunVisibleCommand(@[@"eject", bundleIdentifier, @"--path", path],
                        TFText(@"Removing plugin", @"\u6b63\u5728\u79fb\u9664\u63d2\u4ef6"),
                        TFText(@"Plugin removed.", @"\u63d2\u4ef6\u5df2\u79fb\u9664\u3002"), nil);
}

static void TFPresentPluginManager(NSString *bundleIdentifier, NSString *appName) {
    TFRunVisibleCommand(@[@"plugins", bundleIdentifier],
                        TFText(@"Loading plugins", @"\u6b63\u5728\u8bfb\u53d6\u63d2\u4ef6"), @"", ^(NSString *output) {
        NSArray *plugins = TFParsePluginJSON(output);
        if (!plugins) {
            TFPresentAlert(TFText(@"Plugin manager", @"\u63d2\u4ef6\u7ba1\u7406"),
                           TFText(@"Unable to parse plugin list.", @"\u65e0\u6cd5\u89e3\u6790\u63d2\u4ef6\u5217\u8868\u3002"));
            return;
        }
        if (plugins.count == 0) {
            TFPresentAlert(appName, TFText(@"No TrollFools plugins.", @"\u6682\u65e0 TrollFools \u63d2\u4ef6\u3002"));
            return;
        }

        UIViewController *presenter = TFTopViewController();
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:appName
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *plugin in plugins) {
            NSString *name = [plugin[@"name"] isKindOfClass:NSString.class] ? plugin[@"name"] : nil;
            NSString *path = [plugin[@"path"] isKindOfClass:NSString.class] ? plugin[@"path"] : nil;
            BOOL enabled = [plugin[@"enabled"] boolValue];
            if (!name || !path) continue;
            NSString *title = [NSString stringWithFormat:@"%@ (%@)", name,
                enabled ? TFText(@"enabled", @"\u5df2\u542f\u7528") : TFText(@"stored", @"\u5df2\u4fdd\u5b58")];
            [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
                TFRemovePlugin(bundleIdentifier, path);
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:TFText(@"Remove all", @"\u79fb\u9664\u5168\u90e8")
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            TFRunVisibleCommand(@[@"eject", bundleIdentifier, @"--all"],
                                TFText(@"Removing plugins", @"\u6b63\u5728\u79fb\u9664\u63d2\u4ef6"),
                                TFText(@"All plugins removed.", @"\u6240\u6709\u63d2\u4ef6\u5df2\u79fb\u9664\u3002"), nil);
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:TFText(@"Cancel", @"\u53d6\u6d88")
                                                  style:UIAlertActionStyleCancel handler:nil]];
        TFConfigurePopover(sheet, presenter);
        [presenter presentViewController:sheet animated:YES completion:nil];
    });
}

static void TFPrepareFolder(NSString *bundleIdentifier) {
    TFRunVisibleCommand(@[@"prepare-folder", bundleIdentifier],
                        TFText(@"Creating folder", @"\u6b63\u5728\u521b\u5efa\u76ee\u5f55"), @"", ^(NSString *output) {
        NSString *path = [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        TFPresentAlert(TFText(@"Folder ready", @"\u76ee\u5f55\u5df2\u521b\u5efa"), path);
    });
}

static void TFAppendActionsToAlert(UIAlertController *alert, NSString *bundleIdentifier, NSString *appName) {
    if (!alert || bundleIdentifier.length == 0) return;
    if (objc_getAssociatedObject(alert, TFInjectedActionsKey)) return;
    objc_setAssociatedObject(alert, TFInjectedActionsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [alert addAction:[UIAlertAction actionWithTitle:TFText(@"Inject with TrollFools", @"TrollFools \u65b0\u7248\u6ce8\u5165")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        TFPresentPluginPicker(bundleIdentifier, appName);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:TFText(@"Manage TrollFools plugins", @"\u7ba1\u7406 TrollFools \u63d2\u4ef6")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        TFPresentPluginManager(bundleIdentifier, appName);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:TFText(@"Create auto-inject folder", @"\u521b\u5efa\u81ea\u52a8\u6ce8\u5165\u76ee\u5f55")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        TFPrepareFolder(bundleIdentifier);
    }]];
}

static void TFAppendPendingActionsIfNeeded(UIViewController *viewController) {
    NSDictionary *pending = TFPendingAppInfo;
    if (!pending || ![viewController isKindOfClass:UIAlertController.class]) return;
    UIAlertController *alert = (UIAlertController *)viewController;
    if (alert.preferredStyle != UIAlertControllerStyleActionSheet) return;

    TFAppendActionsToAlert(alert, pending[@"bundleIdentifier"], pending[@"appName"]);
    TFPendingAppInfo = nil;
}

static void TFHookedPresent(id self, SEL selector, UIViewController *viewController,
                            BOOL animated, void (^completion)(void)) {
    TFAppendPendingActionsIfNeeded(viewController);
    if (TFOriginalPresent) TFOriginalPresent(self, selector, viewController, animated, completion);
}

static void TFHookedDelegatePresent(id self, SEL selector, UIViewController *viewController,
                                    BOOL animated, void (^completion)(void)) {
    TFAppendPendingActionsIfNeeded(viewController);
    if (TFOriginalDelegatePresent) {
        TFOriginalDelegatePresent(self, selector, viewController, animated, completion);
    }
}

static void TFHookedShowActions(id self, SEL selector, NSIndexPath *indexPath) {
    id appInfo = TFAppInfoAtIndexPath(self, indexPath);
    NSString *bundleIdentifier = TFValidatedBundleIdentifier(appInfo);
    NSString *appName = TFStringFromObject(appInfo, NSSelectorFromString(@"displayName")) ?: bundleIdentifier;
    if (bundleIdentifier) {
        TFPendingAppInfo = @{ @"bundleIdentifier": bundleIdentifier, @"appName": appName ?: bundleIdentifier };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            TFPendingAppInfo = nil;
        });
    }
    if (TFOriginalShowActions) TFOriginalShowActions(self, selector, indexPath);
}

static void TFHookedDidSelect(id self, SEL selector, UITableView *tableView, NSIndexPath *indexPath) {
    id appInfo = TFAppInfoAtIndexPath(self, indexPath);
    NSString *bundleIdentifier = TFValidatedBundleIdentifier(appInfo);
    NSString *appName = TFStringFromObject(appInfo, NSSelectorFromString(@"displayName")) ?: bundleIdentifier;
    if (bundleIdentifier) {
        TFPendingAppInfo = @{ @"bundleIdentifier": bundleIdentifier,
                              @"appName": appName ?: bundleIdentifier };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            TFPendingAppInfo = nil;
        });
    }
    if (TFOriginalDidSelect) TFOriginalDidSelect(self, selector, tableView, indexPath);
}

static void TFInstallHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class controllerClass = NSClassFromString(@"TSAppTableViewController");
        SEL selector = NSSelectorFromString(@"showActionsForAppAtIndexPath:");
        Method method = controllerClass ? class_getInstanceMethod(controllerClass, selector) : NULL;
        if (method) {
            TFOriginalShowActions = (TFShowActionsIMP)method_setImplementation(method, (IMP)TFHookedShowActions);
            NSLog(@"[TrollFoolsIntegration] Installed custom app action hook.");
        } else {
            NSLog(@"[TrollFoolsIntegration] Custom app action entry was not found.");
        }

        SEL didSelectSelector = @selector(tableView:didSelectRowAtIndexPath:);
        Method didSelectMethod = controllerClass ? class_getInstanceMethod(controllerClass, didSelectSelector) : NULL;
        if (didSelectMethod) {
            TFOriginalDidSelect = (TFDidSelectIMP)method_setImplementation(didSelectMethod, (IMP)TFHookedDidSelect);
            NSLog(@"[TrollFoolsIntegration] Installed table selection fallback hook.");
        }

        Method presentMethod = class_getInstanceMethod(UIViewController.class,
                                                        @selector(presentViewController:animated:completion:));
        if (presentMethod) {
            TFOriginalPresent = (TFPresentIMP)method_setImplementation(presentMethod, (IMP)TFHookedPresent);
        }

        Class presentationDelegate = NSClassFromString(@"TSPresentationDelegate");
        Method delegatePresentMethod = presentationDelegate
            ? class_getClassMethod(presentationDelegate, @selector(presentViewController:animated:completion:))
            : NULL;
        if (delegatePresentMethod) {
            TFOriginalDelegatePresent = (TFPresentIMP)method_setImplementation(delegatePresentMethod,
                                                                                 (IMP)TFHookedDelegatePresent);
            NSLog(@"[TrollFoolsIntegration] Installed presentation delegate hook.");
        }

        if (!method && !didSelectMethod) {
            NSLog(@"[TrollFoolsIntegration] Compatible app selection entry was not found.");
        }
    });
}

static void TFReconcileIfNeeded(void) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - TFLastReconcileTime < 15) return;
    TFLastReconcileTime = now;
    TFRunCLI(@[@"reconcile"], ^(int exitCode, NSString *output) {
        if (exitCode != 0) NSLog(@"[TrollFoolsIntegration] Reconcile failed (%d): %@", exitCode, output);
    });
}

__attribute__((constructor)) static void TFIntegrationInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        TFInstallHook();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(__unused NSNotification *notification) {
            TFReconcileIfNeeded();
        }];
    });
}
