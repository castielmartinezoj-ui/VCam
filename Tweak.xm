#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <substrate.h>
#import "MediaManager.h"
#import <Accelerate/Accelerate.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <pthread.h>
#import <atomic>
#import <vector>
#import <mutex>

// ============================================================================
// MARK: - 全局状态
// ============================================================================

static BOOL g_vcamEnabled = NO;
static UIWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;

// Estado compartido entre procesos (SpringBoard y apps de camara)
static NSString *kSharedVideo = @"/var/mobile/Media/Downloads/vcam_video.mp4";
static NSString *kFlagFile   = @"/var/mobile/Media/Downloads/.vcam_on";

// Stream en vivo (protocolo KYCF del daemon): header 24B + RGBA
static const uint32_t kStreamMagic = 0x4B594346; // 'KYCF'
static const int kStreamPort = 9876;
static std::atomic<int> g_streamActive{0};
static CMSampleBufferRef g_latestStreamFrame = NULL;
static std::mutex g_frameMutex;

// ============================================================================
// MARK: - Stream TCP (recibe frames del daemon NASA BGHA)
// ============================================================================

static bool vcam_recv_full(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n <= 0) return false;
        got += (size_t)n;
    }
    return true;
}

static CMSampleBufferRef vcam_sample_from_rgba(const uint8_t *rgba, uint32_t w, uint32_t h) {
    if (!rgba || w == 0 || h == 0 || w > 8192 || h > 8192) return NULL;

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVReturn st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      (__bridge CFDictionaryRef)attrs, &pb);
    if (st != kCVReturnSuccess || !pb) return NULL;

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *y  = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t yStride  = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);

    vImage_Buffer src = { (void *)rgba, (vImagePixelCount)h, (vImagePixelCount)w, (size_t)w * 4 };
    vImage_Buffer dstY = { y, (vImagePixelCount)h, (vImagePixelCount)w, yStride };
    vImage_Buffer dstUV = { uv, (vImagePixelCount)(h / 2), (vImagePixelCount)(w / 2), uvStride };
    vImageConvert_RGBA8888To420Yp8_CbCr8(&src, &dstY, &dstUV, kvImageNoFlags);

    CVPixelBufferUnlockBaseAddress(pb, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt);

    CMSampleBufferRef sb = NULL;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
        .decodeTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
    };
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, YES, NULL, NULL,
                                       fmt, &timing, &sb);
    if (fmt) CFRelease(fmt);
    CVPixelBufferRelease(pb);
    return sb;
}

static void *vcam_stream_thread(void *arg) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) return NULL;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(kStreamPort);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(srv, 4) != 0) {
        close(srv);
        return NULL;
    }

    while (1) {
        int cli = accept(srv, NULL, NULL);
        if (cli < 0) continue;
        g_streamActive.store(1);

        uint8_t hdr[24];
        while (vcam_recv_full(cli, hdr, 24)) {
            uint32_t magic = *(uint32_t *)(hdr + 0);
            uint32_t w = *(uint32_t *)(hdr + 4);
            uint32_t h = *(uint32_t *)(hdr + 8);
            uint32_t len = *(uint32_t *)(hdr + 20);
            if (magic != kStreamMagic || w == 0 || h == 0 || len == 0 || len > 32 * 1024 * 1024)
                break;
            std::vector<uint8_t> rgba(len);
            if (!vcam_recv_full(cli, rgba.data(), len)) break;

            CMSampleBufferRef sb = vcam_sample_from_rgba(rgba.data(), w, h);
            if (sb) {
                std::lock_guard<std::mutex> lk(g_frameMutex);
                if (g_latestStreamFrame) CFRelease(g_latestStreamFrame);
                g_latestStreamFrame = sb;
            }
        }

        g_streamActive.store(0);
        close(cli);
    }
    return NULL;
}

static void vcam_start_stream_listener(void) {
    pthread_t th;
    pthread_create(&th, NULL, vcam_stream_thread, NULL);
    pthread_detach(th);
}

// ============================================================================
// MARK: - 悬浮按钮 UI
// ============================================================================

@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end

@implementation VCamFloatButton
@end

static void setupFloatButton(void);
static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);

static void setupFloatButton() {
    if (g_floatButton) return;

    CGFloat btnSize = 50;
    CGRect screen = [UIScreen mainScreen].bounds;

    g_floatButton = [VCamFloatButton buttonWithType:UIButtonTypeSystem];
    g_floatButton.frame = CGRectMake(screen.size.width - btnSize - 15, 100, btnSize, btnSize);
    g_floatButton.layer.cornerRadius = btnSize / 2.0;
    g_floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatButton.layer.shadowOpacity = 0.3;
    g_floatButton.layer.shadowRadius = 4;
    g_floatButton.backgroundColor = g_vcamEnabled
        ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
        : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];

    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal];
    g_floatButton.titleLabel.font = [UIFont systemFontOfSize:24];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:g_floatButton action:@selector(handlePan:)];
    [g_floatButton addGestureRecognizer:pan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:g_floatButton action:@selector(handleTap:)];
    [g_floatButton addGestureRecognizer:tap];

    g_overlayWindow = [[UIWindow alloc] initWithFrame:screen];
    // iOS 13+: una UIWindow sin windowScene NO se renderiza — asignar la escena activa
    UIWindowScene *activeScene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)s;
            break;
        }
    }
    if (activeScene) {
        g_overlayWindow.windowScene = activeScene;
    }
    g_overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    g_overlayWindow.hidden = NO;
    g_overlayWindow.backgroundColor = [UIColor clearColor];

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    [rootVC.view addSubview:g_floatButton];
    g_overlayWindow.rootViewController = rootVC;

    class_addMethod([g_floatButton class], @selector(handlePan:),
                    (IMP)handlePanGesture, "v@:@");
    class_addMethod([g_floatButton class], @selector(handleTap:),
                    (IMP)handleTapGesture, "v@:@");
}

static void handlePanGesture(UIPanGestureRecognizer *gesture) {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];

    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat x = btn.center.x < screen.size.width / 2 ? 35 : screen.size.width - 35;
        [UIView animateWithDuration:0.2 animations:^{
            btn.center = CGPointMake(x, btn.center.y);
        }];
    }
}

static UIViewController *findTopViewController(void) {
    UIViewController *topVC = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) {
                    topVC = w.rootViewController;
                    break;
                }
            }
        }
    }
    while (topVC && topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

static void setSharedFlag(BOOL on) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (on) {
        if (![fm fileExistsAtPath:kFlagFile]) {
            [fm createFileAtPath:kFlagFile contents:[NSData data] attributes:nil];
        }
    } else {
        [fm removeItemAtPath:kFlagFile error:nil];
    }
}

@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;

    NSURL *sharedURL = [NSURL fileURLWithPath:kSharedVideo];
    [[NSFileManager defaultManager] removeItemAtURL:sharedURL error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:sharedURL error:nil];

    setSharedFlag(YES);
    [[MediaManager sharedManager] loadMediaFromURL:sharedURL];
    g_vcamEnabled = YES;
    [[MediaManager sharedManager] start];
    if (g_floatButton) {
        g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

static VCamImagePickerControllerDelegate *g_pickerDelegate = nil;

static void handleTapGesture(UITapGestureRecognizer *gesture) {
    UIViewController *topVC = findTopViewController();
    if (!topVC) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"VCam"
        message:g_vcamEnabled ? @"虚拟相机已启用" : @"虚拟相机已关闭"
        preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"选择视频"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {

        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum]) {
            return;
        }
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = g_pickerDelegate;
        [topVC presentViewController:picker animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:g_vcamEnabled ? @"关闭虚拟相机" : @"开启虚拟相机"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        g_vcamEnabled = !g_vcamEnabled;
        setSharedFlag(g_vcamEnabled);
        if (g_floatButton) {
            g_floatButton.backgroundColor = g_vcamEnabled
                ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
                : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        }
        if (g_vcamEnabled) {
            [[MediaManager sharedManager] loadMediaFromURL:[NSURL fileURLWithPath:kSharedVideo]];
            [[MediaManager sharedManager] start];
        } else {
            [[MediaManager sharedManager] stop];
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = gesture.view;
        alert.popoverPresentationController.sourceRect = gesture.view.bounds;
    }

    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// MARK: - Hook AVCaptureSession / Video Output
// ============================================================================

%group VCamHooks

%hook AVCaptureSession
- (void)startRunning {
    %orig;
}
- (void)stopRunning {
    %orig;
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    %orig;
}
%end

// Intercept frame delegate callback -> substitute with fake frames
%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {

    // 1) Stream en vivo del daemon (protocolo KYCF)
    if (g_streamActive.load() == 1) {
        CMSampleBufferRef copy = NULL;
        {
            std::lock_guard<std::mutex> lk(g_frameMutex);
            if (g_latestStreamFrame) {
                CMSampleBufferCreateCopy(kCFAllocatorDefault, g_latestStreamFrame, &copy);
            }
        }
        if (copy) {
            CMSampleBufferSetOutputPresentationTimeStamp(
                copy, CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000));
            %orig(output, copy, connection);
            CFRelease(copy);
            return;
        }
    }

    // 2) Modo archivo (video del boton)
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            %orig(output, fakeFrame, connection);
            CFRelease(fakeFrame);
            return;
        }
    }
    %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)setSession:(AVCaptureSession *)session {
    %orig;
}
%end

%end // VCamHooks group

// ============================================================================
// MARK: - Constructor
// ============================================================================

%ctor {
    @autoreleasepool {
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        if (![bundleID isEqualToString:@"com.apple.springboard"]) {
            // apps de camara: listener del stream + hooks + auto-habilitado por bandera
            vcam_start_stream_listener();
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:kFlagFile] && [fm fileExistsAtPath:kSharedVideo]) {
                g_vcamEnabled = YES;
                [[MediaManager sharedManager] loadMediaFromURL:[NSURL fileURLWithPath:kSharedVideo]];
                [[MediaManager sharedManager] start];
            }
            %init(VCamHooks);
        }

        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:kFlagFile] && [fm fileExistsAtPath:kSharedVideo]) {
                g_vcamEnabled = YES;
                [[MediaManager sharedManager] loadMediaFromURL:[NSURL fileURLWithPath:kSharedVideo]];
                [[MediaManager sharedManager] start];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        setupFloatButton();
                    }
                });
        }
    }
}
