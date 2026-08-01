#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <float.h>

NS_ASSUME_NONNULL_BEGIN

@interface PIPSubtitleManager : NSObject
+ (instancetype)sharedManager;
- (BOOL)beginPictureInPictureForOriginalController:(AVPictureInPictureController *)controller
                                           fallback:(dispatch_block_t)fallback;
- (BOOL)stopPictureInPictureForOriginalController:(AVPictureInPictureController *)controller;
- (BOOL)isCustomPictureInPictureActiveForOriginalController:(AVPictureInPictureController *)controller;
@end

NS_ASSUME_NONNULL_END



static const NSTimeInterval kPIPPreparationTimeout = 4.0;
static const NSTimeInterval kPIPFrameInterval = 1.0 / 30.0;
static const NSTimeInterval kPIPSubtitlePollInterval = 0.10;
static void *kPIPRenderQueueSpecificKey = &kPIPRenderQueueSpecificKey;

#pragma mark - Safe runtime helpers

static Ivar PIPFindIvar(Class cls, const char *name) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        Ivar ivar = class_getInstanceVariable(current, name);
        if (ivar) {
            return ivar;
        }
    }
    return NULL;
}

static id _Nullable PIPReadObjectIvar(id object, const char *name) {
    if (!object || !name) {
        return nil;
    }

    Ivar ivar = PIPFindIvar(object_getClass(object), name);
    if (!ivar) {
        return nil;
    }

    @try {
        return object_getIvar(object, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL PIPClassNameMatches(id object, NSString *swiftName, const char *runtimeName) {
    if (!object) {
        return NO;
    }

    Class cls = object_getClass(object);
    NSString *name = NSStringFromClass(cls);
    const char *rawName = class_getName(cls);
    return [name isEqualToString:swiftName] ||
           (rawName && strcmp(rawName, runtimeName) == 0);
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
            if (windowScene.activationState != UISceneActivationStateForegroundActive &&
                windowScene.activationState != UISceneActivationStateForegroundInactive) {
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

static AVPlayerLayer * _Nullable PIPResolvePlayerLayerFromObject(id object) {
    if (!object) {
        return nil;
    }

    if ([object isKindOfClass:AVPlayerLayer.class]) {
        AVPlayerLayer *layer = (AVPlayerLayer *)object;
        return layer.player ? layer : nil;
    }

    id nestedLayer = PIPReadObjectIvar(object, "playerLayer");
    if ([nestedLayer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayerLayer *layer = (AVPlayerLayer *)nestedLayer;
        return layer.player ? layer : nil;
    }

    return nil;
}

static UILabel * _Nullable PIPResolveSubtitleLabelFromControlView(id controlView) {
    if (!controlView) {
        return nil;
    }

    id label = PIPReadObjectIvar(controlView, "subtitleLabel");
    return [label isKindOfClass:UILabel.class] ? (UILabel *)label : nil;
}

static void PIPCollectPlayerContextInView(UIView *view,
                                          AVPlayerLayer *__strong _Nullable *playerLayer,
                                          UILabel *__strong _Nullable *subtitleLabel,
                                          UIView *__strong _Nullable *hostParent) {
    if (!view || (*playerLayer && *subtitleLabel)) {
        return;
    }

    // Resolve the exact BMPlayer instance first so the video layer and subtitle
    // label always belong to the same player instead of two different views.
    if (PIPClassNameMatches(view,
                            @"BMPlayer.BMPlayer",
                            "_TtC8BMPlayer8BMPlayer")) {
        id layerView = PIPReadObjectIvar(view, "playerLayer");
        AVPlayerLayer *resolvedLayer = PIPResolvePlayerLayerFromObject(layerView);
        if (!resolvedLayer) {
            resolvedLayer = PIPResolvePlayerLayerFromObject(view);
        }

        id controlView = PIPReadObjectIvar(view, "controlView");
        UILabel *resolvedLabel = PIPResolveSubtitleLabelFromControlView(controlView);
        if (!resolvedLabel) {
            id customControlView = PIPReadObjectIvar(view, "customControlView");
            resolvedLabel = PIPResolveSubtitleLabelFromControlView(customControlView);
        }

        if (resolvedLayer) {
            *playerLayer = resolvedLayer;
            *hostParent = view;
        }
        if (resolvedLabel) {
            *subtitleLabel = resolvedLabel;
        }
    }

    if (!*subtitleLabel &&
        PIPClassNameMatches(view,
                            @"BMPlayer.BMPlayerControlView",
                            "_TtC8BMPlayer19BMPlayerControlView")) {
        UILabel *label = PIPResolveSubtitleLabelFromControlView(view);
        if (label) {
            *subtitleLabel = label;
        }
    }

    if (!*playerLayer &&
        PIPClassNameMatches(view,
                            @"BMPlayer.BMPlayerLayerView",
                            "_TtC8BMPlayer17BMPlayerLayerView")) {
        AVPlayerLayer *layer = PIPResolvePlayerLayerFromObject(view);
        if (layer) {
            *playerLayer = layer;
            *hostParent = view.superview ?: view;
        }
    }

    if (!*playerLayer) {
        NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithObject:view.layer];
        while (layers.count > 0 && !*playerLayer) {
            CALayer *layer = layers.lastObject;
            [layers removeLastObject];
            if ([layer isKindOfClass:AVPlayerLayer.class] && ((AVPlayerLayer *)layer).player) {
                *playerLayer = (AVPlayerLayer *)layer;
                *hostParent = view;
                break;
            }
            if (layer.sublayers.count > 0) {
                [layers addObjectsFromArray:layer.sublayers];
            }
        }
    }

    for (UIView *subview in view.subviews) {
        PIPCollectPlayerContextInView(subview, playerLayer, subtitleLabel, hostParent);
        if (*playerLayer && *subtitleLabel) {
            break;
        }
    }
}

static UILabel * _Nullable PIPFindVisibleSubtitleLabel(void) {
    AVPlayerLayer *unusedLayer = nil;
    UILabel *label = nil;
    UIView *unusedHost = nil;
    for (UIWindow *window in PIPApplicationWindows()) {
        if (window.hidden || window.alpha <= 0.0) {
            continue;
        }
        PIPCollectPlayerContextInView(window, &unusedLayer, &label, &unusedHost);
        if (label) {
            return label;
        }
    }
    return nil;
}

#pragma mark - Manager

@interface PIPSubtitleManager ()
<AVPictureInPictureSampleBufferPlaybackDelegate,
 AVPictureInPictureControllerDelegate>

@property (nonatomic, strong, nullable) AVPictureInPictureController *originalController;
@property (nonatomic, strong, nullable) AVPictureInPictureController *customController;
@property (nonatomic, strong, nullable) AVPictureInPictureControllerContentSource *contentSource API_AVAILABLE(ios(15.0));
@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, strong, nullable) AVPlayerItem *playerItem;
@property (nonatomic, strong, nullable) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, weak, nullable) UILabel *subtitleLabel;
@property (nonatomic, strong, nullable) UIView *sampleLayerHostView;
@property (nonatomic, strong, nullable) AVSampleBufferDisplayLayer *sampleLayer;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) dispatch_queue_t renderQueue;
@property (nonatomic, strong, nullable) dispatch_source_t renderTimer;
@property (nonatomic, strong, nullable) dispatch_source_t subtitleTimer;
@property (nonatomic, copy, nullable) dispatch_block_t fallbackBlock;
@property (nonatomic, copy, nullable) NSString *latestSubtitleText;
@property (nonatomic, assign) BOOL preparing;
@property (nonatomic, assign) BOOL customActive;
@property (nonatomic, assign) BOOL firstSampleEnqueued;
@property (nonatomic, assign) BOOL customStartRequested;
@property (nonatomic, assign) CFTimeInterval preparationDeadline;

@end

@implementation PIPSubtitleManager {
    CVPixelBufferPoolRef _pixelBufferPool;
    CMVideoFormatDescriptionRef _formatDescription;
    CGSize _pixelSize;
    CMTime _lastPresentationTime;
    NSString *_renderedSubtitleKey;
    CIImage *_renderedSubtitleOverlay;
}

+ (instancetype)sharedManager {
    static PIPSubtitleManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] initPrivate];
    });
    return manager;
}

- (instancetype)init {
    return [PIPSubtitleManager sharedManager];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _renderQueue = dispatch_queue_create("com.ikira.pipsubtitles.render", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_renderQueue,
                                    kPIPRenderQueueSpecificKey,
                                    kPIPRenderQueueSpecificKey,
                                    NULL);
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextCacheIntermediates: @YES
        }];
        _lastPresentationTime = kCMTimeInvalid;
    }
    return self;
}

- (BOOL)beginPictureInPictureForOriginalController:(AVPictureInPictureController *)controller
                                           fallback:(dispatch_block_t)fallback {
    if (!NSThread.isMainThread) {
        return NO;
    }

    if (!controller || self.preparing || self.customActive) {
        return self.preparing || self.customActive;
    }

    if (![AVPictureInPictureController isPictureInPictureSupported]) {
        return NO;
    }

    AVPlayerLayer *playerLayer = nil;
    UILabel *subtitleLabel = nil;
    UIView *hostParent = nil;

    for (UIWindow *window in PIPApplicationWindows()) {
        if (window.hidden || window.alpha <= 0.0) {
            continue;
        }
        PIPCollectPlayerContextInView(window, &playerLayer, &subtitleLabel, &hostParent);
        if (playerLayer && subtitleLabel) {
            break;
        }
    }

    AVPlayer *player = playerLayer.player;
    AVPlayerItem *item = player.currentItem;
    if (!player || !item || !hostParent ||
        item.status == AVPlayerItemStatusFailed || item.asset.hasProtectedContent) {
        NSLog(@"[PiPSubtitles] Context unavailable player=%@ item=%@ host=%@ protected=%d",
              player, item, hostParent, (int)item.asset.hasProtectedContent);
        return NO;
    }

    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    AVPlayerItemVideoOutput *videoOutput =
        [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixelAttributes];

    @try {
        [item addOutput:videoOutput];
    } @catch (__unused NSException *exception) {
        return NO;
    }

    if (![item.outputs containsObject:videoOutput]) {
        NSLog(@"[PiPSubtitles] AVPlayerItem rejected AVPlayerItemVideoOutput");
        return NO;
    }
    [videoOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:0.03];

    self.originalController = controller;
    self.player = player;
    self.playerItem = item;
    self.videoOutput = videoOutput;
    self.subtitleLabel = subtitleLabel;
    self.fallbackBlock = [fallback copy];
    self.preparing = YES;
    self.customActive = NO;
    self.firstSampleEnqueued = NO;
    self.customStartRequested = NO;
    self.preparationDeadline = CACurrentMediaTime() + kPIPPreparationTimeout;
    self.latestSubtitleText = @"";
    _lastPresentationTime = kCMTimeInvalid;

    UIView *hostView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 16.0, 9.0)];
    hostView.userInteractionEnabled = NO;
    hostView.alpha = 0.02;
    hostView.clipsToBounds = YES;
    hostView.backgroundColor = UIColor.clearColor;
    [hostParent addSubview:hostView];
    self.sampleLayerHostView = hostView;

    AVSampleBufferDisplayLayer *sampleLayer = [AVSampleBufferDisplayLayer layer];
    sampleLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    sampleLayer.backgroundColor = UIColor.blackColor.CGColor;
    sampleLayer.frame = CGRectMake(0.0, 0.0, 16.0, 9.0);
    [hostView.layer addSublayer:sampleLayer];
    self.sampleLayer = sampleLayer;

    if (@available(iOS 15.0, *)) {
        AVPictureInPictureControllerContentSource *source =
            [[AVPictureInPictureControllerContentSource alloc]
                initWithSampleBufferDisplayLayer:sampleLayer
                playbackDelegate:self];
        self.contentSource = source;
        AVPictureInPictureController *customController =
            [[AVPictureInPictureController alloc] initWithContentSource:source];
        customController.delegate = self;
        customController.requiresLinearPlayback = NO;
        self.customController = customController;
        [customController invalidatePlaybackState];
    } else {
        [self failPreparationAndUseFallback:YES];
        return YES;
    }

    [self startSubtitlePolling];
    [self startRendering];
    return YES;
}

- (BOOL)stopPictureInPictureForOriginalController:(AVPictureInPictureController *)controller {
    if (!NSThread.isMainThread) {
        return NO;
    }

    if (!controller || controller != self.originalController ||
        (!self.preparing && !self.customActive)) {
        return NO;
    }

    self.fallbackBlock = nil;
    if (self.customController.isPictureInPictureActive) {
        [self.customController stopPictureInPicture];
    } else {
        [self cleanup];
    }
    return YES;
}

- (BOOL)isCustomPictureInPictureActiveForOriginalController:(AVPictureInPictureController *)controller {
    return controller && controller == self.originalController &&
           (self.customActive || self.preparing);
}

#pragma mark - Timers

- (void)startSubtitlePolling {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0,
                                                     0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kPIPSubtitlePollInterval * NSEC_PER_SEC),
                              (uint64_t)(0.02 * NSEC_PER_SEC));

    __weak PIPSubtitleManager *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        PIPSubtitleManager *strongSelf = weakSelf;
        if (!strongSelf || (!strongSelf.preparing && !strongSelf.customActive)) {
            return;
        }

        UILabel *label = strongSelf.subtitleLabel;
        if (!label || !label.window) {
            label = PIPFindVisibleSubtitleLabel();
            strongSelf.subtitleLabel = label;
        }
        NSString *text = label.attributedText.string ?: label.text ?: @"";
        if (label.hidden || label.alpha <= 0.01) {
            text = @"";
        }
        text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

        @synchronized (strongSelf) {
            strongSelf.latestSubtitleText = text ?: @"";
        }

        static NSUInteger playbackStateTick = 0;
        playbackStateTick++;
        if (playbackStateTick % 5 == 0 && strongSelf.customController) {
            [strongSelf.customController invalidatePlaybackState];
        }
    });
    dispatch_resume(timer);
    self.subtitleTimer = timer;
}

- (void)startRendering {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0,
                                                     0,
                                                     self.renderQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kPIPFrameInterval * NSEC_PER_SEC),
                              (uint64_t)(0.004 * NSEC_PER_SEC));

    __weak PIPSubtitleManager *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            PIPSubtitleManager *strongSelf = weakSelf;
            if (!strongSelf || (!strongSelf.preparing && !strongSelf.customActive)) {
                return;
            }
            [strongSelf renderNextFrame];
        }
    });
    dispatch_resume(timer);
    self.renderTimer = timer;
}

#pragma mark - Rendering

- (void)renderNextFrame {
    AVPlayerItemVideoOutput *output = self.videoOutput;
    AVPlayer *player = self.player;
    if (!output || !player) {
        return;
    }

    CMTime itemTime = [output itemTimeForHostTime:CACurrentMediaTime()];
    if (!CMTIME_IS_NUMERIC(itemTime) || CMTIME_IS_INDEFINITE(itemTime)) {
        itemTime = player.currentTime;
    }

    CMTime displayTime = kCMTimeInvalid;
    CVPixelBufferRef sourceBuffer =
        [output copyPixelBufferForItemTime:itemTime itemTimeForDisplay:&displayTime];
    if (!sourceBuffer) {
        CMTime currentTime = player.currentTime;
        sourceBuffer = [output copyPixelBufferForItemTime:currentTime
                                           itemTimeForDisplay:&displayTime];
        if (sourceBuffer) {
            itemTime = CMTIME_IS_NUMERIC(displayTime) ? displayTime : currentTime;
        }
    } else if (CMTIME_IS_NUMERIC(displayTime)) {
        itemTime = displayTime;
    }

    if (!sourceBuffer) {
        if (self.preparing && CACurrentMediaTime() >= self.preparationDeadline) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self failPreparationAndUseFallback:YES];
            });
        }
        return;
    }

    const size_t width = CVPixelBufferGetWidth(sourceBuffer);
    const size_t height = CVPixelBufferGetHeight(sourceBuffer);
    if (width < 16 || height < 16) {
        CVPixelBufferRelease(sourceBuffer);
        return;
    }

    if (![self ensurePixelBufferPoolForWidth:width height:height]) {
        CVPixelBufferRelease(sourceBuffer);
        return;
    }

    CVPixelBufferRef destinationBuffer = NULL;
    CVReturn poolResult = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                             _pixelBufferPool,
                                                             &destinationBuffer);
    if (poolResult != kCVReturnSuccess || !destinationBuffer) {
        CVPixelBufferRelease(sourceBuffer);
        return;
    }

    CIImage *videoImage = [CIImage imageWithCVPixelBuffer:sourceBuffer];
    CIImage *finalImage = videoImage;

    NSString *subtitle = nil;
    @synchronized (self) {
        subtitle = [self.latestSubtitleText copy];
    }

    CIImage *overlay = [self subtitleOverlayForText:subtitle
                                              width:width
                                             height:height];
    if (overlay) {
        finalImage = [overlay imageByCompositingOverImage:videoImage];
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [self.ciContext render:finalImage
           toCVPixelBuffer:destinationBuffer
                    bounds:CGRectMake(0.0, 0.0, width, height)
                colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    [self enqueuePixelBuffer:destinationBuffer atTime:itemTime];

    CVPixelBufferRelease(destinationBuffer);
    CVPixelBufferRelease(sourceBuffer);
}

- (BOOL)ensurePixelBufferPoolForWidth:(size_t)width height:(size_t)height {
    CGSize requestedSize = CGSizeMake((CGFloat)width, (CGFloat)height);
    if (_pixelBufferPool && CGSizeEqualToSize(_pixelSize, requestedSize)) {
        return YES;
    }

    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }

    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES
    };

    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                              NULL,
                                              (__bridge CFDictionaryRef)attributes,
                                              &_pixelBufferPool);
    if (result != kCVReturnSuccess || !_pixelBufferPool) {
        return NO;
    }

    _pixelSize = requestedSize;
    _renderedSubtitleKey = nil;
    _renderedSubtitleOverlay = nil;
    return YES;
}

- (CIImage *)subtitleOverlayForText:(NSString *)text
                              width:(size_t)width
                             height:(size_t)height {
    if (text.length == 0) {
        _renderedSubtitleKey = nil;
        _renderedSubtitleOverlay = nil;
        return nil;
    }

    NSString *key = [NSString stringWithFormat:@"%zux%zu:%@", width, height, text];
    if ([_renderedSubtitleKey isEqualToString:key]) {
        return _renderedSubtitleOverlay;
    }

    CGSize canvasSize = CGSizeMake((CGFloat)width, (CGFloat)height);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = 1.0;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize format:format];

    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat fontSize = MAX(24.0, MIN(58.0, (CGFloat)width / 32.0));
        UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];

        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        paragraph.alignment = NSTextAlignmentCenter;
        paragraph.baseWritingDirection = NSWritingDirectionNatural;
        paragraph.lineBreakMode = NSLineBreakByWordWrapping;

        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.95];
        shadow.shadowOffset = CGSizeMake(0.0, MAX(1.0, fontSize * 0.06));
        shadow.shadowBlurRadius = MAX(2.0, fontSize * 0.12);

        NSDictionary<NSAttributedStringKey, id> *attributes = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: UIColor.whiteColor,
            NSParagraphStyleAttributeName: paragraph,
            NSShadowAttributeName: shadow
        };

        NSAttributedString *attributed =
            [[NSAttributedString alloc] initWithString:text attributes:attributes];

        CGFloat maximumWidth = (CGFloat)width * 0.88;
        CGSize maximumSize = CGSizeMake(maximumWidth, (CGFloat)height * 0.28);
        CGRect measured = [attributed boundingRectWithSize:maximumSize
                                                   options:(NSStringDrawingUsesLineFragmentOrigin |
                                                            NSStringDrawingUsesFontLeading)
                                                   context:nil];
        CGFloat paddingX = fontSize * 0.55;
        CGFloat paddingY = fontSize * 0.25;
        CGFloat boxWidth = MIN(maximumWidth, ceil(measured.size.width) + paddingX * 2.0);
        CGFloat boxHeight = ceil(measured.size.height) + paddingY * 2.0;
        CGFloat boxX = ((CGFloat)width - boxWidth) * 0.5;
        CGFloat bottomMargin = MAX((CGFloat)height * 0.075, fontSize * 1.4);
        CGFloat boxY = (CGFloat)height - bottomMargin - boxHeight;

        CGRect boxRect = CGRectMake(boxX, boxY, boxWidth, boxHeight);
        UIBezierPath *background =
            [UIBezierPath bezierPathWithRoundedRect:boxRect cornerRadius:fontSize * 0.25];
        [[UIColor colorWithWhite:0.0 alpha:0.58] setFill];
        [background fill];

        CGRect textRect = CGRectInset(boxRect, paddingX, paddingY);
        [attributed drawWithRect:textRect
                         options:(NSStringDrawingUsesLineFragmentOrigin |
                                  NSStringDrawingUsesFontLeading)
                         context:nil];
    }];

    if (!image.CGImage) {
        return nil;
    }

    _renderedSubtitleKey = key;
    _renderedSubtitleOverlay = [CIImage imageWithCGImage:image.CGImage];
    return _renderedSubtitleOverlay;
}

- (void)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)presentationTime {
    if (!pixelBuffer || !self.sampleLayer) {
        return;
    }

    if (!_formatDescription) {
        OSStatus descriptionStatus =
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                          pixelBuffer,
                                                          &_formatDescription);
        if (descriptionStatus != noErr || !_formatDescription) {
            return;
        }
    }

    if (CMTIME_IS_NUMERIC(_lastPresentationTime) &&
        CMTIME_IS_NUMERIC(presentationTime) &&
        CMTimeCompare(presentationTime, _lastPresentationTime) < 0) {
        [self.sampleLayer flushAndRemoveImage];
        _lastPresentationTime = kCMTimeInvalid;
    }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = presentationTime,
        .decodeTimeStamp = kCMTimeInvalid
    };

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus sampleStatus =
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                  pixelBuffer,
                                                  _formatDescription,
                                                  &timing,
                                                  &sampleBuffer);
    if (sampleStatus != noErr || !sampleBuffer) {
        return;
    }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef attachment =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(attachment,
                             kCMSampleAttachmentKey_DisplayImmediately,
                             kCFBooleanTrue);
    }

    if (self.sampleLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [self.sampleLayer flush];
    }

    [self.sampleLayer enqueueSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);

    _lastPresentationTime = presentationTime;
    self.firstSampleEnqueued = YES;

    if (self.preparing && !self.customStartRequested) {
        self.customStartRequested = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self requestCustomPictureInPictureStart];
        });
    }
}

#pragma mark - Starting, fallback and cleanup

- (void)requestCustomPictureInPictureStart {
    if (!self.preparing || !self.customController || !self.firstSampleEnqueued) {
        return;
    }

    if (self.customController.isPictureInPicturePossible) {
        [self.customController startPictureInPicture];
        return;
    }

    if (CACurrentMediaTime() >= self.preparationDeadline) {
        [self failPreparationAndUseFallback:YES];
        return;
    }

    self.customStartRequested = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.preparing && !self.customStartRequested) {
            self.customStartRequested = YES;
            [self requestCustomPictureInPictureStart];
        }
    });
}

- (void)failPreparationAndUseFallback:(BOOL)useFallback {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self failPreparationAndUseFallback:useFallback];
        });
        return;
    }

    if (!self.preparing && !self.customActive) {
        return;
    }

    dispatch_block_t fallback = useFallback ? [self.fallbackBlock copy] : nil;
    [self cleanup];
    if (fallback) {
        fallback();
    }
}

- (void)cleanup {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cleanup];
        });
        return;
    }

    self.preparing = NO;
    self.customActive = NO;
    self.customStartRequested = NO;
    self.fallbackBlock = nil;

    if (self.renderTimer) {
        dispatch_source_cancel(self.renderTimer);
        self.renderTimer = nil;
    }
    if (dispatch_get_specific(kPIPRenderQueueSpecificKey) != kPIPRenderQueueSpecificKey) {
        dispatch_sync(self.renderQueue, ^{});
    }
    if (self.subtitleTimer) {
        dispatch_source_cancel(self.subtitleTimer);
        self.subtitleTimer = nil;
    }

    AVPlayerItem *item = self.playerItem;
    AVPlayerItemVideoOutput *output = self.videoOutput;
    if (item && output && [item.outputs containsObject:output]) {
        [item removeOutput:output];
    }

    [self.sampleLayer stopRequestingMediaData];
    [self.sampleLayer flushAndRemoveImage];
    [self.sampleLayer removeFromSuperlayer];
    [self.sampleLayerHostView removeFromSuperview];

    self.contentSource = nil;
    self.customController.delegate = nil;
    self.customController = nil;
    self.originalController = nil;
    self.player = nil;
    self.playerItem = nil;
    self.videoOutput = nil;
    self.subtitleLabel = nil;
    self.sampleLayer = nil;
    self.sampleLayerHostView = nil;
    self.latestSubtitleText = @"";

    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }

    _pixelSize = CGSizeZero;
    _lastPresentationTime = kCMTimeInvalid;
    _renderedSubtitleKey = nil;
    _renderedSubtitleOverlay = nil;
}

#pragma mark - AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    self.preparing = NO;
    self.customActive = YES;
    self.fallbackBlock = nil;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
 failedToStartPictureInPictureWithError:(NSError *)error {
    [self failPreparationAndUseFallback:YES];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    [self cleanup];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
 restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL restored))completionHandler {
    if (completionHandler) {
        completionHandler(YES);
    }
}

#pragma mark - AVPictureInPictureSampleBufferPlaybackDelegate

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                        setPlaying:(BOOL)playing API_AVAILABLE(ios(15.0)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (playing) {
            [self.player play];
        } else {
            [self.player pause];
        }
        [pictureInPictureController invalidatePlaybackState];
    });
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:
    (AVPictureInPictureController *)pictureInPictureController API_AVAILABLE(ios(15.0)) {
    CMTime duration = self.playerItem.duration;
    if (CMTIME_IS_NUMERIC(duration) && CMTIME_IS_VALID(duration) && !CMTIME_IS_INDEFINITE(duration)) {
        return CMTimeRangeMake(kCMTimeZero, duration);
    }

    CMTime start = CMTimeMakeWithSeconds(-24.0 * 60.0 * 60.0, 600);
    CMTime longDuration = CMTimeMakeWithSeconds(48.0 * 60.0 * 60.0, 600);
    return CMTimeRangeMake(start, longDuration);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:
    (AVPictureInPictureController *)pictureInPictureController API_AVAILABLE(ios(15.0)) {
    return self.player.rate == 0.0;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler API_AVAILABLE(ios(15.0)) {
    AVPlayer *player = self.player;
    CMTime destination = CMTimeAdd(player.currentTime, skipInterval);
    if (CMTIME_COMPARE_INLINE(destination, <, kCMTimeZero)) {
        destination = kCMTimeZero;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [player seekToTime:destination
           toleranceBefore:CMTimeMakeWithSeconds(0.25, 600)
            toleranceAfter:CMTimeMakeWithSeconds(0.25, 600)
         completionHandler:^(__unused BOOL finished) {
            [self.sampleLayer flushAndRemoveImage];
            _lastPresentationTime = kCMTimeInvalid;
            if (completionHandler) {
                completionHandler();
            }
        }];
    });
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
       didTransitionToRenderSize:(CMVideoDimensions)newRenderSize API_AVAILABLE(ios(15.0)) {
    // The display layer uses ResizeAspect, so no manual resizing is required.
}

- (BOOL)pictureInPictureControllerShouldProhibitBackgroundAudioPlayback:
    (AVPictureInPictureController *)pictureInPictureController API_AVAILABLE(ios(15.0)) {
    return NO;
}

@end


typedef void (*PIPVoidIMP)(id, SEL);
typedef BOOL (*PIPBoolIMP)(id, SEL);

static PIPVoidIMP gOriginalStart = NULL;
static PIPVoidIMP gOriginalStop = NULL;
static PIPBoolIMP gOriginalIsActive = NULL;

static void PIPStartReplacement(AVPictureInPictureController *controller, SEL command) {
    if (!controller || !gOriginalStart) {
        return;
    }

    __weak AVPictureInPictureController *weakController = controller;
    BOOL handled = [[PIPSubtitleManager sharedManager]
        beginPictureInPictureForOriginalController:controller
        fallback:^{
            AVPictureInPictureController *strongController = weakController;
            if (strongController && gOriginalStart) {
                gOriginalStart(strongController, @selector(startPictureInPicture));
            }
        }];

    if (!handled) {
        gOriginalStart(controller, command);
    }
}

static void PIPStopReplacement(AVPictureInPictureController *controller, SEL command) {
    if (!controller || !gOriginalStop) {
        return;
    }

    BOOL handled = [[PIPSubtitleManager sharedManager]
        stopPictureInPictureForOriginalController:controller];
    if (!handled) {
        gOriginalStop(controller, command);
    }
}

static BOOL PIPIsActiveReplacement(AVPictureInPictureController *controller, SEL command) {
    if (controller && [[PIPSubtitleManager sharedManager]
        isCustomPictureInPictureActiveForOriginalController:controller]) {
        return YES;
    }

    return gOriginalIsActive ? gOriginalIsActive(controller, command) : NO;
}

static void PIPInstallMethodHook(Class cls, SEL selector, IMP replacement, IMP *originalStorage) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !replacement || !originalStorage) {
        return;
    }

    IMP original = method_getImplementation(method);
    if (!original || original == replacement) {
        return;
    }

    *originalStorage = original;
    method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void PIPSubtitlesEntry(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            Class pipClass = NSClassFromString(@"AVPictureInPictureController");
            if (!pipClass) {
                return;
            }

            PIPInstallMethodHook(pipClass,
                                 @selector(startPictureInPicture),
                                 (IMP)PIPStartReplacement,
                                 (IMP *)&gOriginalStart);
            PIPInstallMethodHook(pipClass,
                                 @selector(stopPictureInPicture),
                                 (IMP)PIPStopReplacement,
                                 (IMP *)&gOriginalStop);
            PIPInstallMethodHook(pipClass,
                                 @selector(isPictureInPictureActive),
                                 (IMP)PIPIsActiveReplacement,
                                 (IMP *)&gOriginalIsActive);
        });
    }
}
