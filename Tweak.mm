#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - Runtime helpers

static Ivar PIPFindIvar(Class cls, const char *name) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        Ivar ivar = class_getInstanceVariable(current, name);
        if (ivar != NULL) {
            return ivar;
        }
    }
    return NULL;
}

static id PIPReadObjectIvar(id object, const char *name) {
    if (object == nil || name == NULL) {
        return nil;
    }

    Ivar ivar = PIPFindIvar(object_getClass(object), name);
    if (ivar == NULL) {
        return nil;
    }

    @try {
        return object_getIvar(object, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL PIPClassNameMatches(id object, NSString *objcName, const char *runtimeName) {
    if (object == nil) {
        return NO;
    }

    NSString *name = NSStringFromClass(object_getClass(object));
    const char *rawName = class_getName(object_getClass(object));
    return [name isEqualToString:objcName] ||
           (rawName != NULL && strcmp(rawName, runtimeName) == 0);
}

static NSArray<UIWindow *> *PIPApplicationWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *application = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) {
                continue;
            }
            [windows addObjectsFromArray:windowScene.windows];
        }
    }

    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [windows addObjectsFromArray:application.windows];
#pragma clang diagnostic pop
    }

    [windows sortUsingComparator:^NSComparisonResult(UIWindow *first, UIWindow *second) {
        if (first.isKeyWindow != second.isKeyWindow) {
            return first.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        }
        if (first.windowLevel > second.windowLevel) {
            return NSOrderedAscending;
        }
        if (first.windowLevel < second.windowLevel) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    return windows;
}

static AVPlayerLayer *PIPPlayerLayerFromObject(id object) {
    if (object == nil) {
        return nil;
    }

    if ([object isKindOfClass:AVPlayerLayer.class]) {
        AVPlayerLayer *layer = (AVPlayerLayer *)object;
        return layer.player != nil ? layer : nil;
    }

    id nested = PIPReadObjectIvar(object, "playerLayer");
    if ([nested isKindOfClass:AVPlayerLayer.class]) {
        AVPlayerLayer *layer = (AVPlayerLayer *)nested;
        return layer.player != nil ? layer : nil;
    }

    return nil;
}

static UILabel *PIPSubtitleLabelFromControlView(id controlView) {
    if (controlView == nil) {
        return nil;
    }

    id label = PIPReadObjectIvar(controlView, "subtitleLabel");
    return [label isKindOfClass:UILabel.class] ? (UILabel *)label : nil;
}

#pragma mark - BMPlayer context

@interface PIPPlayerContext : NSObject
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *originalPlayerLayer;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) UILabel *subtitleLabel;
@end

@implementation PIPPlayerContext
@end

static PIPPlayerContext *PIPContextInView(UIView *view, AVPlayer *targetPlayer) {
    if (view == nil || targetPlayer == nil) {
        return nil;
    }

    if (PIPClassNameMatches(view, @"BMPlayer.BMPlayer", "_TtC8BMPlayer8BMPlayer")) {
        id layerView = PIPReadObjectIvar(view, "playerLayer");
        AVPlayerLayer *playerLayer = PIPPlayerLayerFromObject(layerView);
        if (playerLayer == nil) {
            playerLayer = PIPPlayerLayerFromObject(view);
        }

        if (playerLayer.player == targetPlayer) {
            id controlView = PIPReadObjectIvar(view, "controlView");
            UILabel *subtitleLabel = PIPSubtitleLabelFromControlView(controlView);
            if (subtitleLabel == nil) {
                id customControlView = PIPReadObjectIvar(view, "customControlView");
                subtitleLabel = PIPSubtitleLabelFromControlView(customControlView);
            }

            PIPPlayerContext *context = [PIPPlayerContext new];
            context.player = targetPlayer;
            context.originalPlayerLayer = playerLayer;
            context.sourceView = view;
            context.subtitleLabel = subtitleLabel;
            return context;
        }
    }

    for (UIView *subview in view.subviews) {
        PIPPlayerContext *context = PIPContextInView(subview, targetPlayer);
        if (context != nil) {
            return context;
        }
    }

    return nil;
}

static PIPPlayerContext *PIPFindContextForPlayer(AVPlayer *player) {
    if (player == nil) {
        return nil;
    }

    for (UIWindow *window in PIPApplicationWindows()) {
        if (window.hidden || window.alpha <= 0.01) {
            continue;
        }

        PIPPlayerContext *context = PIPContextInView(window, player);
        if (context != nil) {
            return context;
        }
    }

    return nil;
}

static AVPlayerLayer *PIPOriginalPlayerLayer(AVPictureInPictureController *controller) {
    if (controller == nil) {
        return nil;
    }

    if (@available(iOS 15.0, *)) {
        AVPlayerLayer *layer = controller.contentSource.playerLayer;
        if (layer.player != nil) {
            return layer;
        }
    }

    @try {
        id value = [controller valueForKey:@"playerLayer"];
        if ([value isKindOfClass:AVPlayerLayer.class] && ((AVPlayerLayer *)value).player != nil) {
            return (AVPlayerLayer *)value;
        }
    } @catch (__unused NSException *exception) {
    }

    return nil;
}

#pragma mark - Custom PiP view controller

@interface PIPVideoCallContentController : AVPictureInPictureVideoCallViewController
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *videoLayer;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *subtitleBackgroundView;
- (instancetype)initWithPlayer:(AVPlayer *)player
                  videoGravity:(AVLayerVideoGravity)videoGravity
                 preferredSize:(CGSize)preferredSize;
- (void)updateSubtitleFromSourceLabel:(UILabel *)sourceLabel;
@end

@implementation PIPVideoCallContentController

- (instancetype)initWithPlayer:(AVPlayer *)player
                  videoGravity:(AVLayerVideoGravity)videoGravity
                 preferredSize:(CGSize)preferredSize {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _player = player;
        _videoLayer = [AVPlayerLayer playerLayerWithPlayer:player];
        _videoLayer.videoGravity = videoGravity ?: AVLayerVideoGravityResizeAspect;

        if (preferredSize.width < 16.0 || preferredSize.height < 9.0) {
            preferredSize = CGSizeMake(1280.0, 720.0);
        }
        self.preferredContentSize = preferredSize;
    }
    return self;
}

- (void)loadView {
    UIView *rootView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 1280.0, 720.0)];
    rootView.backgroundColor = UIColor.blackColor;
    rootView.clipsToBounds = YES;
    self.view = rootView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self.view.layer addSublayer:self.videoLayer];

    UIView *backgroundView = [UIView new];
    backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    backgroundView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.58];
    backgroundView.layer.cornerRadius = 12.0;
    backgroundView.layer.masksToBounds = YES;
    backgroundView.hidden = YES;
    [self.view addSubview:backgroundView];
    self.subtitleBackgroundView = backgroundView;

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 3;
    label.textAlignment = NSTextAlignmentCenter;
    label.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont boldSystemFontOfSize:42.0];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.58;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.backgroundColor = UIColor.clearColor;
    [backgroundView addSubview:label];
    self.subtitleLabel = label;

    [NSLayoutConstraint activateConstraints:@[
        [backgroundView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:46.0],
        [backgroundView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-46.0],
        [backgroundView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [backgroundView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-34.0],

        [label.leadingAnchor constraintEqualToAnchor:backgroundView.leadingAnchor constant:22.0],
        [label.trailingAnchor constraintEqualToAnchor:backgroundView.trailingAnchor constant:-22.0],
        [label.topAnchor constraintEqualToAnchor:backgroundView.topAnchor constant:10.0],
        [label.bottomAnchor constraintEqualToAnchor:backgroundView.bottomAnchor constant:-12.0]
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.videoLayer.frame = self.view.bounds;
    [CATransaction commit];
}

- (void)updateSubtitleFromSourceLabel:(UILabel *)sourceLabel {
    if (!NSThread.isMainThread) {
        __weak PIPVideoCallContentController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateSubtitleFromSourceLabel:sourceLabel];
        });
        return;
    }

    NSString *text = sourceLabel.attributedText.string ?: sourceLabel.text ?: @"";
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    BOOL visible = sourceLabel != nil &&
                   !sourceLabel.hidden &&
                   sourceLabel.alpha > 0.01 &&
                   text.length > 0;

    self.subtitleLabel.text = visible ? text : @"";
    self.subtitleBackgroundView.hidden = !visible;
}

- (void)dealloc {
    _videoLayer.player = nil;
}

@end

#pragma mark - Manager

static void *kPIPCustomControllerMarker = &kPIPCustomControllerMarker;

typedef void (*PIPVoidControllerIMP)(id, SEL);
typedef BOOL (*PIPBoolControllerIMP)(id, SEL);

static PIPVoidControllerIMP PIPOriginalStartIMP = NULL;
static PIPVoidControllerIMP PIPOriginalStopIMP = NULL;
static PIPBoolControllerIMP PIPOriginalIsActiveIMP = NULL;
static PIPBoolControllerIMP PIPOriginalIsPossibleIMP = NULL;

@interface PIPVideoCallManager : NSObject <AVPictureInPictureControllerDelegate>
@property (nonatomic, strong) AVPictureInPictureController *originalController;
@property (nonatomic, strong) AVPictureInPictureController *customController;
@property (nonatomic, strong) AVPictureInPictureControllerContentSource *contentSource API_AVAILABLE(ios(15.0));
@property (nonatomic, strong) PIPVideoCallContentController *contentController API_AVAILABLE(ios(15.0));
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *originalPlayerLayer;
@property (nonatomic, weak) UILabel *sourceSubtitleLabel;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) id<AVPictureInPictureControllerDelegate> originalDelegate;
@property (nonatomic, strong) id periodicTimeObserver;
@property (nonatomic, strong) dispatch_source_t subtitleTimer;
@property (nonatomic, assign) BOOL starting;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL fallingBack;
+ (instancetype)sharedManager;
- (BOOL)beginForOriginalController:(AVPictureInPictureController *)controller;
- (BOOL)stopForOriginalController:(AVPictureInPictureController *)controller;
- (BOOL)isManagingOriginalController:(AVPictureInPictureController *)controller;
@end

@implementation PIPVideoCallManager

+ (instancetype)sharedManager {
    static PIPVideoCallManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [PIPVideoCallManager new];
    });
    return manager;
}

- (BOOL)beginForOriginalController:(AVPictureInPictureController *)controller {
    if (!NSThread.isMainThread || controller == nil) {
        return NO;
    }

    if (@available(iOS 15.0, *)) {
        if (self.starting || self.active) {
            return controller == self.originalController;
        }

        AVPlayerLayer *originalLayer = PIPOriginalPlayerLayer(controller);
        AVPlayer *player = originalLayer.player;
        if (player == nil || player.currentItem == nil) {
            return NO;
        }

        PIPPlayerContext *context = PIPFindContextForPlayer(player);
        if (context == nil || context.sourceView == nil || context.sourceView.window == nil) {
            return NO;
        }

        CGSize preferredSize = player.currentItem.presentationSize;
        if (preferredSize.width < 16.0 || preferredSize.height < 9.0) {
            preferredSize = context.sourceView.bounds.size;
        }
        if (preferredSize.width < 16.0 || preferredSize.height < 9.0) {
            preferredSize = CGSizeMake(1280.0, 720.0);
        }

        AVLayerVideoGravity gravity = originalLayer.videoGravity;
        if (gravity.length == 0) {
            gravity = AVLayerVideoGravityResizeAspect;
        }

        PIPVideoCallContentController *contentController =
            [[PIPVideoCallContentController alloc] initWithPlayer:player
                                                    videoGravity:gravity
                                                   preferredSize:preferredSize];
        [contentController loadViewIfNeeded];
        [contentController updateSubtitleFromSourceLabel:context.subtitleLabel];

        AVPictureInPictureControllerContentSource *source =
            [[AVPictureInPictureControllerContentSource alloc]
                initWithActiveVideoCallSourceView:context.sourceView
                contentViewController:contentController];

        AVPictureInPictureController *customController =
            [[AVPictureInPictureController alloc] initWithContentSource:source];
        if (customController == nil) {
            return NO;
        }

        objc_setAssociatedObject(customController,
                                 kPIPCustomControllerMarker,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        customController.delegate = self;
        customController.canStartPictureInPictureAutomaticallyFromInline = NO;

        self.originalController = controller;
        self.customController = customController;
        self.contentSource = source;
        self.contentController = contentController;
        self.player = player;
        self.originalPlayerLayer = originalLayer;
        self.sourceSubtitleLabel = context.subtitleLabel;
        self.sourceView = context.sourceView;
        self.originalDelegate = controller.delegate;
        self.starting = YES;
        self.active = NO;
        self.fallingBack = NO;

        [self startSubtitleMirroring];

        __weak PIPVideoCallManager *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PIPVideoCallManager *strongSelf = weakSelf;
            if (strongSelf == nil || !strongSelf.starting || strongSelf.customController == nil) {
                return;
            }

            if (PIPOriginalStartIMP != NULL) {
                PIPOriginalStartIMP(strongSelf.customController,
                                    @selector(startPictureInPicture));
            } else {
                [strongSelf fallbackToOriginalController];
            }
        });

        return YES;
    }

    return NO;
}

- (BOOL)stopForOriginalController:(AVPictureInPictureController *)controller {
    if (!NSThread.isMainThread || controller == nil || controller != self.originalController) {
        return NO;
    }

    if (!self.starting && !self.active) {
        return NO;
    }

    if (self.customController != nil && PIPOriginalStopIMP != NULL) {
        PIPOriginalStopIMP(self.customController, @selector(stopPictureInPicture));
    } else {
        [self cleanup];
    }
    return YES;
}

- (BOOL)isManagingOriginalController:(AVPictureInPictureController *)controller {
    return controller != nil &&
           controller == self.originalController &&
           (self.starting || self.active);
}

- (void)startSubtitleMirroring {
    [self stopSubtitleMirroring];

    __weak PIPVideoCallManager *weakSelf = self;
    self.periodicTimeObserver =
        [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.10, 600)
                                                 queue:dispatch_get_main_queue()
                                            usingBlock:^(__unused CMTime time) {
        PIPVideoCallManager *strongSelf = weakSelf;
        [strongSelf copySubtitleNow];
    }];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0,
                                                     0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.15 * NSEC_PER_SEC),
                              (uint64_t)(0.03 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        PIPVideoCallManager *strongSelf = weakSelf;
        [strongSelf copySubtitleNow];
    });
    dispatch_resume(timer);
    self.subtitleTimer = timer;
}

- (void)copySubtitleNow {
    if (!NSThread.isMainThread) {
        __weak PIPVideoCallManager *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf copySubtitleNow];
        });
        return;
    }

    UILabel *sourceLabel = self.sourceSubtitleLabel;
    if (sourceLabel == nil || sourceLabel.window == nil) {
        PIPPlayerContext *context = PIPFindContextForPlayer(self.player);
        self.sourceSubtitleLabel = context.subtitleLabel;
        sourceLabel = context.subtitleLabel;
    }

    [self.contentController updateSubtitleFromSourceLabel:sourceLabel];
}

- (void)stopSubtitleMirroring {
    if (self.subtitleTimer != nil) {
        dispatch_source_cancel(self.subtitleTimer);
        self.subtitleTimer = nil;
    }

    if (self.periodicTimeObserver != nil && self.player != nil) {
        @try {
            [self.player removeTimeObserver:self.periodicTimeObserver];
        } @catch (__unused NSException *exception) {
        }
        self.periodicTimeObserver = nil;
    }
}

- (void)fallbackToOriginalController {
    if (!NSThread.isMainThread) {
        __weak PIPVideoCallManager *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf fallbackToOriginalController];
        });
        return;
    }

    if (self.fallingBack) {
        return;
    }
    self.fallingBack = YES;

    AVPictureInPictureController *originalController = self.originalController;
    [self cleanup];

    if (originalController != nil && PIPOriginalStartIMP != NULL) {
        PIPOriginalStartIMP(originalController, @selector(startPictureInPicture));
    }
}

- (void)cleanup {
    [self stopSubtitleMirroring];

    AVPlayer *player = self.player;
    AVPlayerLayer *originalLayer = self.originalPlayerLayer;

    self.contentController.videoLayer.player = nil;

    // AVFoundation displays video only on the most recently associated
    // AVPlayerLayer for a player. Re-associate the app's original layer so
    // normal playback returns immediately after custom PiP stops or fails.
    if (originalLayer != nil && player != nil) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        originalLayer.player = nil;
        originalLayer.player = player;
        [CATransaction commit];
    }

    self.customController.delegate = nil;

    self.starting = NO;
    self.active = NO;
    self.fallingBack = NO;
    self.originalController = nil;
    self.customController = nil;
    self.contentSource = nil;
    self.contentController = nil;
    self.player = nil;
    self.originalPlayerLayer = nil;
    self.sourceSubtitleLabel = nil;
    self.sourceView = nil;
    self.originalDelegate = nil;
}

#pragma mark AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    id<AVPictureInPictureControllerDelegate> delegate = self.originalDelegate;
    if ([delegate respondsToSelector:@selector(pictureInPictureControllerWillStartPictureInPicture:)]) {
        [delegate pictureInPictureControllerWillStartPictureInPicture:self.originalController];
    }
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    self.starting = NO;
    self.active = YES;
    [self copySubtitleNow];

    id<AVPictureInPictureControllerDelegate> delegate = self.originalDelegate;
    if ([delegate respondsToSelector:@selector(pictureInPictureControllerDidStartPictureInPicture:)]) {
        [delegate pictureInPictureControllerDidStartPictureInPicture:self.originalController];
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
 failedToStartPictureInPictureWithError:(NSError *)error {
    NSLog(@"[PiPVideoCall] Custom PiP failed: %@", error);
    [self fallbackToOriginalController];
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    id<AVPictureInPictureControllerDelegate> delegate = self.originalDelegate;
    if ([delegate respondsToSelector:@selector(pictureInPictureControllerWillStopPictureInPicture:)]) {
        [delegate pictureInPictureControllerWillStopPictureInPicture:self.originalController];
    }
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    AVPictureInPictureController *originalController = self.originalController;
    id<AVPictureInPictureControllerDelegate> delegate = self.originalDelegate;

    self.starting = NO;
    self.active = NO;

    if ([delegate respondsToSelector:@selector(pictureInPictureControllerDidStopPictureInPicture:)]) {
        [delegate pictureInPictureControllerDidStopPictureInPicture:originalController];
    }

    [self cleanup];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
 restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL restored))completionHandler {
    id<AVPictureInPictureControllerDelegate> delegate = self.originalDelegate;
    AVPictureInPictureController *originalController = self.originalController;

    if ([delegate respondsToSelector:@selector(pictureInPictureController:restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:)]) {
        [delegate pictureInPictureController:originalController
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:completionHandler];
    } else {
        completionHandler(YES);
    }
}

@end

#pragma mark - AVPictureInPictureController interception

static BOOL PIPIsMarkedCustomController(AVPictureInPictureController *controller) {
    return [objc_getAssociatedObject(controller, kPIPCustomControllerMarker) boolValue];
}

static void PIPSwizzledStartPictureInPicture(AVPictureInPictureController *controller, SEL selector) {
    if (controller == nil || PIPOriginalStartIMP == NULL) {
        return;
    }

    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PIPSwizzledStartPictureInPicture(controller, selector);
        });
        return;
    }

    if (PIPIsMarkedCustomController(controller)) {
        PIPOriginalStartIMP(controller, selector);
        return;
    }

    if (![[PIPVideoCallManager sharedManager] beginForOriginalController:controller]) {
        PIPOriginalStartIMP(controller, selector);
    }
}

static void PIPSwizzledStopPictureInPicture(AVPictureInPictureController *controller, SEL selector) {
    if (controller == nil || PIPOriginalStopIMP == NULL) {
        return;
    }

    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PIPSwizzledStopPictureInPicture(controller, selector);
        });
        return;
    }

    if (PIPIsMarkedCustomController(controller)) {
        PIPOriginalStopIMP(controller, selector);
        return;
    }

    if (![[PIPVideoCallManager sharedManager] stopForOriginalController:controller]) {
        PIPOriginalStopIMP(controller, selector);
    }
}

static BOOL PIPSwizzledIsPictureInPictureActive(AVPictureInPictureController *controller, SEL selector) {
    if (!PIPIsMarkedCustomController(controller) &&
        [[PIPVideoCallManager sharedManager] isManagingOriginalController:controller]) {
        return [PIPVideoCallManager sharedManager].active;
    }

    return PIPOriginalIsActiveIMP != NULL ? PIPOriginalIsActiveIMP(controller, selector) : NO;
}

static BOOL PIPSwizzledIsPictureInPicturePossible(AVPictureInPictureController *controller, SEL selector) {
    if (!PIPIsMarkedCustomController(controller) &&
        [[PIPVideoCallManager sharedManager] isManagingOriginalController:controller]) {
        AVPictureInPictureController *custom = [PIPVideoCallManager sharedManager].customController;
        return custom != nil &&
               (PIPOriginalIsPossibleIMP == NULL ||
                PIPOriginalIsPossibleIMP(custom, selector));
    }

    return PIPOriginalIsPossibleIMP != NULL ? PIPOriginalIsPossibleIMP(controller, selector) : NO;
}

static void PIPInstallHook(Class cls, SEL selector, IMP replacement, IMP *originalStorage) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL || replacement == NULL || originalStorage == NULL) {
        return;
    }

    IMP current = method_getImplementation(method);
    if (current == replacement) {
        return;
    }

    *originalStorage = current;
    method_setImplementation(method, replacement);
}

static void PIPInstallHooks(void) {
    Class cls = AVPictureInPictureController.class;
    if (cls == Nil) {
        return;
    }

    PIPInstallHook(cls,
                   @selector(startPictureInPicture),
                   (IMP)PIPSwizzledStartPictureInPicture,
                   (IMP *)&PIPOriginalStartIMP);
    PIPInstallHook(cls,
                   @selector(stopPictureInPicture),
                   (IMP)PIPSwizzledStopPictureInPicture,
                   (IMP *)&PIPOriginalStopIMP);
    PIPInstallHook(cls,
                   @selector(isPictureInPictureActive),
                   (IMP)PIPSwizzledIsPictureInPictureActive,
                   (IMP *)&PIPOriginalIsActiveIMP);
    PIPInstallHook(cls,
                   @selector(isPictureInPicturePossible),
                   (IMP)PIPSwizzledIsPictureInPicturePossible,
                   (IMP *)&PIPOriginalIsPossibleIMP);
}

__attribute__((constructor))
static void PIPVideoCallEntryPoint(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (@available(iOS 15.0, *)) {
                PIPInstallHooks();
                NSLog(@"[PiPVideoCall] Loaded safely");
            }
        });
    }
}
