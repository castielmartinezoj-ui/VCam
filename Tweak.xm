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
#import <sys/stat.h>
#import <string.h>

// ============================================================================
// MARK: - 全局状态
// ============================================================================

static BOOL g_vcamEnabled = NO;
static UIWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;
static UIButton *g_imgButton = nil;
static UIView *g_panel = nil;

static NSString *kSharedVideo = @"/var/mobile/Media/Downloads/vcam_video.mp4";
static NSString *kFlagFile   = @"/var/mobile/Media/Downloads/.vcam_on";
static NSString *kCfgPath    = @"/var/mobile/Media/Downloads/vcam_image.cfg";

// Configuración compartida SpringBoard <-> app de cámara
// Formato: modo\nruta\nzoom\noffX\noffY
// modo: 0=off  1=stream/video  2=imagen
static int   g_cfgMode = 0;
static char  g_cfgImage[1024];
static float g_cfgZoom = 1.0;
static float g_cfgOffX = 0.0;
static float g_cfgOffY = 0.0;

// Stream KYCF: SpringBoard recibe por TCP y comparte por shm con la app Camara
static const uint32_t kStreamMagic = 0x4B594346; // 'KYCF'
static const int kStreamPort = 9876;
static volatile int g_streamActive = 0;

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
// MARK: - Config compartida (archivo)
// ============================================================================

static void vcam_cfg_write(void) {
    NSString *s = [NSString stringWithFormat:@"%d\n%s\n%.3f\n%.3f\n%.3f",
                   g_cfgMode, g_cfgImage, g_cfgZoom, g_cfgOffX, g_cfgOffY];
    [s writeToFile:kCfgPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void vcam_cfg_read(void) {
    NSString *s = [NSString stringWithContentsOfFile:kCfgPath
                                            encoding:NSUTF8StringEncoding error:nil];
    if (!s) return;
    NSArray *lines = [s componentsSeparatedByString:@"\n"];
    if (lines.count >= 1) g_cfgMode = [lines[0] intValue];
    if (lines.count >= 2) {
        const char *c = [lines[1] UTF8String] ?: "";
        strlcpy(g_cfgImage, c, sizeof(g_cfgImage));
    }
    if (lines.count >= 3) g_cfgZoom = [lines[2] floatValue];
    if (lines.count >= 4) g_cfgOffX = [lines[3] floatValue];
    if (lines.count >= 5) g_cfgOffY = [lines[4] floatValue];
    if (g_cfgZoom < 0.2) g_cfgZoom = 1.0;
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
// MARK: - Modo imagen: foto elegida + ajuste (zoom / offset)
// ============================================================================

static UIImage *g_cachedImage = nil;
static char g_cachedPath[1024];
static struct timespec g_cachedMtime = {0};

static UIImage *vcam_image_load(void) {
    if (g_cfgMode != 2 || g_cfgImage[0] == '\0') {
        return nil;
    }
    NSString *path = [NSString stringWithUTF8String:g_cfgImage];
    struct stat st = {0};
    if (stat(g_cfgImage, &st) != 0) {
        return nil;
    }
    if (g_cachedImage &&
        strcmp(g_cachedPath, g_cfgImage) == 0 &&
        g_cachedMtime.tv_sec == st.st_mtimespec.tv_sec &&
        g_cachedMtime.tv_nsec == st.st_mtimespec.tv_nsec) {
        return g_cachedImage;
    }
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) return nil;
    g_cachedImage = img;
    strlcpy(g_cachedPath, g_cfgImage, sizeof(g_cachedPath));
    g_cachedMtime = st.st_mtimespec;
    return img;
}

// Dibuja la imagen con zoom+offset en un buffer RGBA de W x H
static uint8_t *vcam_image_to_rgba(uint32_t W, uint32_t H, uint32_t *outW, uint32_t *outH) {
    UIImage *img = vcam_image_load();
    if (!img) return NULL;
    if (W == 0 || H == 0 || W > 4096 || H > 4096) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    // ByteOrder32Big + PremultipliedLast => memoria RGBA
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGContextSetFillColorWithColor(ctx, [UIColor blackColor].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, W, H));

    CGFloat iw = img.size.width, ih = img.size.height;
    if (iw <= 0 || ih <= 0) { CGContextRelease(ctx); return NULL; }
    CGFloat scale = MIN((CGFloat)W / iw, (CGFloat)H / ih) * g_cfgZoom;
    CGFloat dw = iw * scale, dh = ih * scale;
    CGFloat ox = ((CGFloat)W - dw) / 2.0 + g_cfgOffX * W;
    CGFloat oy = ((CGFloat)H - dh) / 2.0 + g_cfgOffY * H;
    CGContextDrawImage(ctx, CGRectMake(ox, oy, dw, dh), img.CGImage);

    uint8_t *data = (uint8_t *)CGBitmapContextGetData(ctx);
    size_t len = (size_t)W * H * 4;
    uint8_t *copy = (uint8_t *)malloc(len);
    if (copy) memcpy(copy, data, len);
    CGContextRelease(ctx);

    *outW = W;
    *outH = H;
    return copy;
}

static CMSampleBufferRef vcam_image_sample(uint32_t W, uint32_t H) {
    uint32_t w = 0, h = 0;
    uint8_t *rgba = vcam_image_to_rgba(W, H, &w, &h);
    if (!rgba) return NULL;
    size_t nv12Len = 0;
    uint8_t *nv12 = vcam_rgba_to_nv12(rgba, w, h, &nv12Len);
    free(rgba);
    if (!nv12) return NULL;
    CMSampleBufferRef sb = vcam_sample_from_nv12(nv12, w, h);
    free(nv12);
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
// MARK: - UI: boton flotante + boton imagen + panel de ajuste
// ============================================================================

@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end

@implementation VCamFloatButton
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self.superview];
    CGPoint prev = [t previousLocationInView:self.superview];
    CGPoint c = self.center;
    c.x += p.x - prev.x;
    c.y += p.y - prev.y;
    CGFloat half = self.bounds.size.width / 2.0;
    CGRect bounds = self.superview.bounds;
    if (c.x < half) c.x = half;
    if (c.y < half + 20) c.y = half + 20;
    if (c.x > bounds.size.width - half) c.x = bounds.size.width - half;
    if (c.y > bounds.size.height - half) c.y = bounds.size.height - half;
    self.center = c;
}
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
    if (hit && [hit isDescendantOfView:g_panel]) {
        return hit;
    }
    // controles sueltos (botones, sliders, tablas) fuera del panel
    UIView *v = hit;
    while (v) {
        if ([v isKindOfClass:[UIControl class]] ||
            [v isKindOfClass:[UITableView class]]) {
            return hit;
        }
        v = v.superview;
    }
    return nil;
}
@end

static void setupFloatButton(void);
static void setSharedFlag(BOOL on);

// ============================================================================
// MARK: - Tabla de seleccion de imagen (data source real)
// ============================================================================

@interface VCamTableDS : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray *files;
@end

@implementation VCamTableDS
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.files.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"c"];
    }
    cell.textLabel.text = self.files[(NSUInteger)ip.row];
    cell.textLabel.font = [UIFont systemFontOfSize:13];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *name = self.files[(NSUInteger)ip.row];
    NSString *full = [@"/var/mobile/Media/Downloads/" stringByAppendingString:name];
    strlcpy(g_cfgImage, [full UTF8String] ?: "", sizeof(g_cfgImage));
    g_cfgMode = 2;
    vcam_cfg_write();
    setSharedFlag(YES);
    g_vcamEnabled = YES;
    if (g_floatButton) {
        g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
    }
    [tv deselectRowAtIndexPath:ip animated:YES];
    vcam_log("imagen seleccionada: %s", g_cfgImage);
}
@end

static VCamTableDS *g_tableDS = nil;

// Panel de selección de imagen + ajuste (SpringBoard)
static void setupImagePanel(void) {
    vcam_log("panel: abriendo (modo=%d)", g_cfgMode);
    if (g_panel) {
        // refrescar lista de archivos
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *files = [fm contentsOfDirectoryAtPath:@"/var/mobile/Media/Downloads" error:nil];
        NSMutableArray *images = [NSMutableArray array];
        for (NSString *f in files) {
            NSString *ext = [[f pathExtension] lowercaseString];
            if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] ||
                [ext isEqualToString:@"png"] || [ext isEqualToString:@"heic"]) {
                [images addObject:f];
            }
        }
        if (g_tableDS) {
            g_tableDS.files = images;
            UITableView *table = (UITableView *)[g_panel viewWithTag:9001];
            if (table) [table reloadData];
        }
        UISwitch *sw = (UISwitch *)[g_panel viewWithTag:9005];
        if (sw) sw.on = (g_cfgMode == 1);
        g_panel.hidden = NO;
        return;
    }

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat pw = screen.size.width - 40;
    CGFloat ph = 380;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(20, 80, pw, ph)];
    g_panel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
    g_panel.layer.cornerRadius = 14;
    g_panel.clipsToBounds = YES;

    // Switch stream/video
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 70, 8, 50, 30)];
    sw.tag = 9005;
    sw.on = (g_cfgMode == 1);
    [sw addAction:[UIAction actionWithHandler:^(__kindof UIAction *act) {
        UISwitch *s = (UISwitch *)[g_panel viewWithTag:9005];
        if (s.on) {
            g_cfgMode = 1;
            g_vcamEnabled = YES;
            setSharedFlag(YES);
            [[MediaManager sharedManager] loadMediaFromURL:[NSURL fileURLWithPath:kSharedVideo]];
            [[MediaManager sharedManager] start];
            vcam_log("switch: stream/video ON");
        } else {
            g_cfgMode = 0;
            g_vcamEnabled = NO;
            setSharedFlag(NO);
            [[MediaManager sharedManager] stop];
            vcam_log("switch: off");
        }
        vcam_cfg_write();
        if (g_floatButton) {
            g_floatButton.backgroundColor = g_vcamEnabled
                ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
                : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        }
    }] forControlEvents:UIControlEventValueChanged];
    [g_panel addSubview:sw];

    UILabel *swLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, pw - 100, 24)];
    swLbl.text = @"Stream / video (modo 1)";
    swLbl.font = [UIFont systemFontOfSize:13];
    swLbl.textColor = [UIColor whiteColor];
    [g_panel addSubview:swLbl];

    // Lista de imagenes de Downloads
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectMake(8, 44, pw - 16, 120)
                                                       style:UITableViewStylePlain];
    table.tag = 9001;
    table.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    table.rowHeight = 36;
    [g_panel addSubview:table];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:@"/var/mobile/Media/Downloads" error:nil];
    NSMutableArray *images = [NSMutableArray array];
    for (NSString *f in files) {
        NSString *ext = [[f pathExtension] lowercaseString];
        if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] ||
            [ext isEqualToString:@"png"] || [ext isEqualToString:@"heic"]) {
            [images addObject:f];
        }
    }

    // Sliders de ajuste
    UISlider *zoom = [[UISlider alloc] initWithFrame:CGRectMake(16, 176, pw - 32, 30)];
    zoom.tag = 9002;
    zoom.minimumValue = 0.5;
    zoom.maximumValue = 3.0;
    zoom.value = g_cfgZoom;
    [g_panel addSubview:zoom];

    UISlider *offX = [[UISlider alloc] initWithFrame:CGRectMake(16, 212, pw - 32, 30)];
    offX.tag = 9003;
    offX.minimumValue = -0.5;
    offX.maximumValue = 0.5;
    offX.value = g_cfgOffX;
    [g_panel addSubview:offX];

    UISlider *offY = [[UISlider alloc] initWithFrame:CGRectMake(16, 248, pw - 32, 30)];
    offY.tag = 9004;
    offY.minimumValue = -0.5;
    offY.maximumValue = 0.5;
    offY.value = g_cfgOffY;
    [g_panel addSubview:offY];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 168, pw - 32, 14)];
    lbl.text = @"Zoom / Posición X / Posición Y";
    lbl.font = [UIFont systemFontOfSize:11];
    lbl.textColor = [UIColor whiteColor];
    [g_panel addSubview:lbl];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.frame = CGRectMake(16, 288, pw - 32, 42);
    [apply setTitle:@"Aplicar imagen a la cámara" forState:UIControlStateNormal];
    apply.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
    [apply setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    apply.layer.cornerRadius = 8;
    [apply addAction:[UIAction actionWithHandler:^(__kindof UIAction *act) {
        UISlider *z = (UISlider *)[g_panel viewWithTag:9002];
        UISlider *x = (UISlider *)[g_panel viewWithTag:9003];
        UISlider *y = (UISlider *)[g_panel viewWithTag:9004];
        g_cfgZoom = z.value;
        g_cfgOffX = x.value;
        g_cfgOffY = y.value;
        if (g_cfgImage[0] != '\0') {
            g_cfgMode = 2; // modo imagen
        }
        vcam_cfg_write();
        setSharedFlag(YES);
        g_vcamEnabled = YES;
        vcam_log("apply: modo=%d img=%s zoom=%.2f x=%.2f y=%.2f",
                 g_cfgMode, g_cfgImage, g_cfgZoom, g_cfgOffX, g_cfgOffY);
        if (g_floatButton) {
            g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
        }
        g_panel.hidden = YES;
    }] forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:apply];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(pw - 48, 336, 44, 30);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close addAction:[UIAction actionWithHandler:^(__kindof UIAction *act) {
        vcam_log("panel: cerrado");
        g_panel.hidden = YES;
    }] forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:close];

    // Delegado real de la tabla
    g_tableDS = [[VCamTableDS alloc] init];
    g_tableDS.files = images;
    table.dataSource = g_tableDS;
    table.delegate = g_tableDS;
    [table reloadData];

    UIView *root = g_overlayWindow.rootViewController.view;
    [root addSubview:g_panel];
    vcam_log("panel: construido con %lu imagenes", (unsigned long)images.count);
}

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

    // Tap: abre/cierra el panel unico (stream + imagen + ajustes)
    [g_floatButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *act) {
        vcam_cfg_read();
        if (g_panel && !g_panel.hidden) {
            g_panel.hidden = YES;
            vcam_log("boton: panel cerrado");
        } else {
            setupImagePanel();
        }
    }] forControlEvents:UIControlEventTouchUpInside];

    g_overlayWindow = [[VCamPassthroughWindow alloc] initWithFrame:screen];
    ((VCamPassthroughWindow *)g_overlayWindow).passthroughTarget = g_floatButton;
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

    vcam_log("boton: flotante creado y arrastrable");
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
// MARK: - Overlay de imagen para Apple Camera (muestra la foto ajustada)
// ============================================================================

static UIWindow *g_camWindow = nil;
static UIImageView *g_camImageView = nil;
static NSTimer *g_camTimer = nil;

static void vcam_cam_update(void) {
    vcam_cfg_read();
    if (g_cfgMode != 2 || g_cfgImage[0] == '\0') {
        if (g_camWindow && !g_camWindow.hidden) {
            g_camWindow.hidden = YES;
            vcam_log("cam-overlay: oculto (modo=%d)", g_cfgMode);
        }
        return;
    }
    UIImage *img = vcam_image_load();
    if (!img) {
        if (g_camWindow && !g_camWindow.hidden) {
            g_camWindow.hidden = YES;
        }
        vcam_log("cam-overlay: imagen no carga: %s", g_cfgImage);
        return;
    }
    if (!g_camWindow) {
        CGRect screen = [UIScreen mainScreen].bounds;
        g_camWindow = [[VCamPassthroughWindow alloc] initWithFrame:screen];
        ((VCamPassthroughWindow *)g_camWindow).passthroughTarget = nil; // todo pasa
        UIWindowScene *activeScene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)s;
                break;
            }
        }
        if (activeScene) g_camWindow.windowScene = activeScene;
        g_camWindow.windowLevel = UIWindowLevelAlert - 1; // encima de la app, bajo alertas
        g_camWindow.backgroundColor = [UIColor blackColor];
        g_camWindow.userInteractionEnabled = NO;

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor blackColor];
        g_camImageView = [[UIImageView alloc] initWithFrame:g_camWindow.bounds];
        g_camImageView.contentMode = UIViewContentModeScaleAspectFill;
        g_camImageView.clipsToBounds = YES;
        [vc.view addSubview:g_camImageView];
        g_camWindow.rootViewController = vc;
        vcam_log("cam-overlay: ventana creada");
    }
    g_camImageView.image = img;
    // Ajuste: zoom + offset sobre el llenado
    g_camImageView.transform = CGAffineTransformMakeTranslation(g_cfgOffX * g_camWindow.bounds.size.width,
                                                                 g_cfgOffY * g_camWindow.bounds.size.height);
    g_camImageView.transform = CGAffineTransformScale(g_camImageView.transform, g_cfgZoom, g_cfgZoom);
    if (g_camWindow.hidden) {
        vcam_log("cam-overlay: mostrando %s zoom=%.2f", g_cfgImage, g_cfgZoom);
    }
    g_camWindow.hidden = NO;
}

// ============================================================================
// MARK: - Hooks
// ============================================================================

%group VCamHooks

%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {

    static int logCount = 0;
    if (logCount < 5) {
        vcam_log("hook: captureOutput disparado en %s (frame %d)",
                 [[[NSBundle mainBundle] bundleIdentifier] UTF8String], logCount);
        logCount++;
    }

    vcam_cfg_read();

    // 1) Modo imagen: la foto elegida con ajuste
    if (g_cfgMode == 2) {
        static int imgLog = 0;
        if (imgLog < 3) {
            vcam_log("hook: modo imagen activo, img=%s zoom=%.2f", g_cfgImage, g_cfgZoom);
            imgLog++;
        }
        CVPixelBufferRef inPB = CMSampleBufferGetImageBuffer(sampleBuffer);
        size_t W = inPB ? CVPixelBufferGetWidth(inPB) : 540;
        size_t H = inPB ? CVPixelBufferGetHeight(inPB) : 405;
        if (W == 0) W = 540;
        if (H == 0) H = 405;
        CMSampleBufferRef imgFrame = vcam_image_sample((uint32_t)W, (uint32_t)H);
        if (imgFrame) {
            %orig(output, imgFrame, connection);
            CFRelease(imgFrame);
            return;
        }
    }

    // 2) Stream en vivo (shm del daemon)
    CMSampleBufferRef shmFrame = vcam_shm_read_latest();
    if (shmFrame) {
        %orig(output, shmFrame, connection);
        CFRelease(shmFrame);
        return;
    }

    // 3) Modo video (boton flotante)
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
        vcam_cfg_read();

        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            // SpringBoard: listener TCP + botones + panel
            vcam_start_stream_listener();
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:kFlagFile] && [fm fileExistsAtPath:kSharedVideo] && g_cfgMode != 2) {
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
            // apps de camara: hooks + overlay para Apple Camera
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:kFlagFile] && g_cfgMode != 2) {
                g_vcamEnabled = YES;
                [[MediaManager sharedManager] loadMediaFromURL:[NSURL fileURLWithPath:kSharedVideo]];
                [[MediaManager sharedManager] start];
            }
            %init(VCamHooks);

            if ([bundleID isEqualToString:@"com.apple.camera"]) {
                // Apple Camera usa pipeline privado: la imagen va por overlay
                g_camTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                              repeats:YES
                                                                block:^(NSTimer *t) {
                    @autoreleasepool {
                        vcam_cam_update();
                    }
                }];
                vcam_log("cam-overlay: timer 0.5s armado en com.apple.camera");
            }
        }
    }
}
