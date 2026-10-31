#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <substrate.h>
#import "MediaManager.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <pthread.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <errno.h>
#import <stdarg.h>

// ============================================================================
// MARK: - 全局状态
// ============================================================================

static BOOL g_vcamEnabled = NO;
static UIWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;

static NSString *kSharedVideo = @"/var/mobile/Media/Downloads/vcam_video.mp4";
static NSString *kFlagFile   = @"/var/mobile/Media/Downloads/.vcam_on";

// Stream KYCF: SpringBoard recibe por TCP y comparte por shm con la app Camara
static const uint32_t kStreamMagic = 0x4B594346; // 'KYCF'
static const int kStreamPort = 9876;
static volatile int g_streamActive = 0;
static CMSampleBufferRef g_latestStreamFrame = NULL;
static pthread_mutex_t g_frameMutex = PTHREAD_MUTEX_INITIALIZER;

// ---- memoria compartida NV12 ----
#define VSHM_MAGIC 0x5653484D
#define VSHM_SLOT  (3 * 1024 * 1024)
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t seq;
    uint32_t w;
    uint32_t h;
    uint32_t len;
    uint32_t pad[3];
} VShmHeader;
#define VSHM_SIZE (sizeof(VShmHeader) + VSHM_SLOT * 2)
static const char *kShmPath = "/var/mobile/Media/Downloads/vcam_stream.shm";

// ============================================================================
// MARK: - Log
// ============================================================================

static void vcam_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char buf[512];
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSString *logPath = @"/var/mobile/Media/Downloads/.vcam_ctor_log";
    NSString *entry = [NSString stringWithFormat:@"%s\n", buf];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:logPath
                                                contents:[NSData data] attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [fh seekToEndOfFile];
    [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// ============================================================================
// MARK: - Conversion RGBA -> NV12 (sin dependencias)
// ============================================================================

static uint8_t *vcam_rgba_to_nv12(const uint8_t *rgba, uint32_t w, uint32_t h, size_t *outLen) {
    if (!rgba || w == 0 || h == 0 || w > 8192 || h > 8192) return NULL;
    size_t ySize = (size_t)w * h;
    size_t uvSize = (size_t)w * h / 2;
    uint8_t *nv12 = (uint8_t *)malloc(ySize + uvSize);
    if (!nv12) return NULL;
    uint8_t *y = nv12;
    uint8_t *uv = nv12 + ySize;

    for (uint32_t row = 0; row < h; ++row) {
        const uint8_t *src = rgba + (size_t)row * w * 4;
        uint8_t *yRow = y + (size_t)row * w;
        for (uint32_t col = 0; col < w; ++col) {
            int r = src[col * 4 + 0];
            int g = src[col * 4 + 1];
            int b = src[col * 4 + 2];
            yRow[col] = (uint8_t)((66 * r + 129 * g + 25 * b + 128) >> 8);
        }
    }
    for (uint32_t row = 0; row < h / 2; ++row) {
        const uint8_t *s0 = rgba + (size_t)(row * 2) * w * 4;
        const uint8_t *s1 = rgba + (size_t)(row * 2 + 1) * w * 4;
        uint8_t *uvRow = uv + (size_t)row * w;
        for (uint32_t col = 0; col < w / 2; ++col) {
            int r = (s0[col * 8 + 0] + s0[col * 8 + 4] + s1[col * 8 + 0] + s1[col * 8 + 4]) / 4;
            int g = (s0[col * 8 + 1] + s0[col * 8 + 5] + s1[col * 8 + 1] + s1[col * 8 + 5]) / 4;
            int b = (s0[col * 8 + 2] + s0[col * 8 + 6] + s1[col * 8 + 2] + s1[col * 8 + 6]) / 4;
            uvRow[col * 2 + 0] = (uint8_t)((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            uvRow[col * 2 + 1] = (uint8_t)((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
        }
    }
    *outLen = ySize + uvSize;
    return nv12;
}

static CMSampleBufferRef vcam_sample_from_nv12(const uint8_t *nv12, uint32_t w, uint32_t h) {
    if (!nv12 || w == 0 || h == 0) return NULL;

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVReturn st = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      (__bridge CFDictionaryRef)attrs, &pb);
    if (st != kCVReturnSuccess || !pb) return NULL;

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *yDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *uvDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    size_t ySize = (size_t)w * h;

    for (uint32_t row = 0; row < h; ++row) {
        memcpy(yDst + row * yStride, nv12 + (size_t)row * w, w);
    }
    for (uint32_t row = 0; row < h / 2; ++row) {
        memcpy(uvDst + row * uvStride, nv12 + ySize + (size_t)row * w, w);
    }
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

// ============================================================================
// MARK: - Shm (escritor: SpringBoard / lector: app Camara)
// ============================================================================

static void vcam_shm_write(const uint8_t *nv12, size_t len, uint32_t w, uint32_t h) {
    static int fd = -1;
    static uint8_t *map = NULL;
    if (fd < 0) {
        fd = open(kShmPath, O_RDWR | O_CREAT, 0644);
        if (fd < 0) { vcam_log("shm open fallo errno=%d", errno); return; }
        ftruncate(fd, VSHM_SIZE);
        map = (uint8_t *)mmap(NULL, VSHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (map == MAP_FAILED) { vcam_log("shm mmap fallo errno=%d", errno); return; }
    }
    if (len > VSHM_SLOT) return;
    VShmHeader *hdr = (VShmHeader *)map;
    uint32_t seq = hdr->seq + 1;
    hdr->magic = VSHM_MAGIC;
    hdr->w = w;
    hdr->h = h;
    hdr->len = (uint32_t)len;
    memcpy(map + sizeof(VShmHeader) + (seq % 2) * VSHM_SLOT, nv12, len);
    __sync_synchronize();
    hdr->seq = seq;
}

static CMSampleBufferRef vcam_shm_read_latest(void) {
    static int fd = -1;
    static uint8_t *map = NULL;
    static uint32_t lastSeq = 0;
    if (fd < 0) {
        fd = open(kShmPath, O_RDONLY);
        if (fd < 0) return NULL;
        map = (uint8_t *)mmap(NULL, VSHM_SIZE, PROT_READ, MAP_SHARED, fd, 0);
        if (map == MAP_FAILED) return NULL;
    }
    VShmHeader *hdr = (VShmHeader *)map;
    if (hdr->magic != VSHM_MAGIC) return NULL;
    if (hdr->seq == lastSeq) return NULL;
    lastSeq = hdr->seq;
    if (hdr->w == 0 || hdr->h == 0 || hdr->len == 0 || hdr->len > VSHM_SLOT) return NULL;
    return vcam_sample_from_nv12(map + sizeof(VShmHeader) + (hdr->seq % 2) * VSHM_SLOT,
                                 hdr->w, hdr->h);
}

// ============================================================================
// MARK: - Stream TCP (solo SpringBoard — la Camara tiene sandbox sin sockets)
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

static void *vcam_stream_thread(void *arg) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) {
        vcam_log("socket() fallo errno=%d", errno);
        return NULL;
    }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(kStreamPort);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(srv, 4) != 0) {
        vcam_log("bind/listen fallo errno=%d", errno);
        close(srv);
        return NULL;
    }
    vcam_log("listener 9876 OK pid=%d", getpid());

    while (1) {
        int cli = accept(srv, NULL, NULL);
        if (cli < 0) continue;
        g_streamActive = 1;

        uint8_t hdr[24];
        while (vcam_recv_full(cli, hdr, 24)) {
            uint32_t magic = *(uint32_t *)(hdr + 0);
            uint32_t w = *(uint32_t *)(hdr + 4);
            uint32_t h = *(uint32_t *)(hdr + 8);
            uint32_t len = *(uint32_t *)(hdr + 20);
            if (magic != kStreamMagic || w == 0 || h == 0 || len == 0 || len > 32 * 1024 * 1024)
                break;
            uint8_t *rgba = (uint8_t *)malloc(len);
            if (!rgba) break;
            if (!vcam_recv_full(cli, rgba, len)) {
                free(rgba);
                break;
            }
            size_t nv12Len = 0;
            uint8_t *nv12 = vcam_rgba_to_nv12(rgba, w, h, &nv12Len);
            free(rgba);
            if (!nv12) break;
            vcam_shm_write(nv12, nv12Len, w, h);
            free(nv12);
        }

        g_streamActive = 0;
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
// MARK: - 悬浮按钮 UI (ventana pasante + tap por bloque)
// ============================================================================

@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end

@implementation VCamFloatButton
@end

@interface VCamPassthroughWindow : UIWindow
@property (nonatomic, weak) UIView *passthroughTarget;
@end

@implementation VCamPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self.passthroughTarget ||
        (hit && [hit isDescendantOfView:self.passthroughTarget])) {
        return hit;
    }
    return nil;
}
@end

static void setupFloatButton(void);
static void setSharedFlag(BOOL on);

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

    // Tap directo por BLOQUE — sin gestures, sin alerta, sin selectors
    [g_floatButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *act) {
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
    }] forControlEvents:UIControlEventTouchUpInside];

    g_overlayWindow = [[VCamPassthroughWindow alloc] initWithFrame:screen];
    ((VCamPassthroughWindow *)g_overlayWindow).passthroughTarget = g_floatButton;
    // iOS 13+: asignar la escena activa o no se renderiza
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

// ============================================================================
// MARK: - Hooks
// ============================================================================

%group VCamHooks

%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {

    // 1) Frame fresco desde la memoria compartida (stream en vivo del daemon)
    CMSampleBufferRef shmFrame = vcam_shm_read_latest();
    if (shmFrame) {
        %orig(output, shmFrame, connection);
        CFRelease(shmFrame);
        return;
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

%end // VCamHooks group

// ============================================================================
// MARK: - Constructor
// ============================================================================

%ctor {
    @autoreleasepool {
        vcam_log("ctor pid=%d bundle=%s", getpid(),
                 [[[NSBundle mainBundle] bundleIdentifier] UTF8String]);

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            // SpringBoard: listener TCP (puede bindear) + boton flotante
            vcam_start_stream_listener();
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
        } else {
            // apps de camara: hooks + auto-habilitado por bandera (sin sockets)
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:kFlagFile] && [fm fileExistsAtPath:kSharedVideo]) {
                g_vcamEnabled = YES;
                [[MediaManager sharedManager] loadMediaFromURL:[NSURL fileURLWithPath:kSharedVideo]];
                [[MediaManager sharedManager] start];
            }
            %init(VCamHooks);
        }
    }
}
