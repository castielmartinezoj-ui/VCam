// jbhide.m — ocultamiento de jailbreak con MSHookFunction (substrate/ElleKit)
// El hooker naive no puede escribir paginas r-x del shared cache en iOS 16;
// MSHookFunction usa el backend privilegiado de ElleKit y si puede.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>
#import <errno.h>
#import <sys/attr.h>
#import <stdarg.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

// ============================ deteccion de rutas ============================
static bool jb_path(const char *p) {
    if (!p) return false;
    if (strstr(p, "/var/jb")) return true;
    if (strstr(p, "frida")) return true;
    if (strstr(p, "substrate")) return true;
    if (strstr(p, "TweakInject")) return true;
    if (strstr(p, "ellekit")) return true;
    if (strstr(p, "Cydia")) return true;
    if (strstr(p, "Sileo")) return true;
    if (strstr(p, "Zebra")) return true;
    if (strstr(p, "palera1n")) return true;
    if (strstr(p, "/bin/bash")) return true;
    if (strstr(p, "/usr/sbin/sshd")) return true;
    if (strstr(p, "/var/lib/apt")) return true;
    if (strstr(p, "/etc/apt")) return true;
    if (strstr(p, "undecimus")) return true;
    if (strstr(p, "electra")) return true;
    if (strstr(p, "checkra1n")) return true;
    if (strstr(p, "unc0ver")) return true;
    return false;
}

// ============================ wrappers libc ============================
static int (*real_open)(const char *, int, mode_t);
static int hook_open(const char *path, int flags, mode_t mode) {
    if (jb_path(path)) { errno = ENOENT; return -1; }
    return real_open(path, flags, mode);
}

static FILE *(*real_fopen)(const char *, const char *);
static FILE *hook_fopen(const char *path, const char *mode) {
    if (jb_path(path)) { errno = ENOENT; return NULL; }
    return real_fopen(path, mode);
}

static int (*real_access)(const char *, int);
static int hook_access(const char *path, int mode) {
    if (jb_path(path)) { errno = ENOENT; return -1; }
    return real_access(path, mode);
}

static int (*real_stat)(const char *, struct stat *);
static int hook_stat(const char *path, struct stat *sb) {
    if (jb_path(path)) { errno = ENOENT; return -1; }
    return real_stat(path, sb);
}

static int (*real_lstat)(const char *, struct stat *);
static int hook_lstat(const char *path, struct stat *sb) {
    if (jb_path(path)) { errno = ENOENT; return -1; }
    return real_lstat(path, sb);
}

static int (*real_fstatat)(int, const char *, struct stat *, int);
static int hook_fstatat(int fd, const char *path, struct stat *sb, int flags) {
    if (jb_path(path)) { errno = ENOENT; return -1; }
    return real_fstatat(fd, path, sb, flags);
}

static int (*real_getattrlist)(const char *, struct attrlist *, void *, size_t, unsigned long);
static int hook_getattrlist(const char *path, struct attrlist *al, void *buf, size_t size, unsigned long opts) {
    if (jb_path(path)) { errno = ENOENT; return -1; }
    return real_getattrlist(path, al, buf, size, opts);
}

static DIR *(*real_opendir)(const char *);
static DIR *hook_opendir(const char *path) {
    if (jb_path(path)) { errno = ENOENT; return NULL; }
    return real_opendir(path);
}

static int (*real_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                       void *newp, size_t newlen) {
    int r = real_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (r == 0 && oldp && namelen >= 2 && name[0] == CTL_KERN && name[1] == KERN_PROC) {
        for (size_t off = 0x38; off <= 0x50; off += 4) {
            uint32_t *v = (uint32_t *)((uint8_t *)oldp + off);
            if (*v & 0x800) *v &= ~0x800u;
        }
    }
    return r;
}

// ============================ wrappers ObjC ============================
static BOOL (*g_origFileExists)(id, SEL, NSString *) = NULL;
static BOOL jb_fileExists(id self, SEL _cmd, NSString *path) {
    const char *c = path ? [path UTF8String] : NULL;
    if (c && jb_path(c)) return NO;
    if (!g_origFileExists) return NO;
    return g_origFileExists(self, _cmd, path);
}

static BOOL (*g_origIsReadable)(id, SEL, NSString *) = NULL;
static BOOL jb_isReadable(id self, SEL _cmd, NSString *path) {
    const char *c = path ? [path UTF8String] : NULL;
    if (c && jb_path(c)) return NO;
    if (!g_origIsReadable) return NO;
    return g_origIsReadable(self, _cmd, path);
}

static BOOL (*g_origIsExec)(id, SEL, NSString *) = NULL;
static BOOL jb_isExec(id self, SEL _cmd, NSString *path) {
    const char *c = path ? [path UTF8String] : NULL;
    if (c && jb_path(c)) return NO;
    if (!g_origIsExec) return NO;
    return g_origIsExec(self, _cmd, path);
}

static id (*g_origContents)(id, SEL, NSString *, NSError **) = NULL;
static id jb_contents(id self, SEL _cmd, NSString *path, NSError **err) {
    const char *c = path ? [path UTF8String] : NULL;
    if (c && jb_path(c)) return nil;
    if (!g_origContents) return nil;
    return g_origContents(self, _cmd, path, err);
}

static id (*g_origAttrs)(id, SEL, NSString *, NSError **) = NULL;
static id jb_attrs(id self, SEL _cmd, NSString *path, NSError **err) {
    const char *c = path ? [path UTF8String] : NULL;
    if (c && jb_path(c)) return nil;
    if (!g_origAttrs) return nil;
    return g_origAttrs(self, _cmd, path, err);
}

static BOOL (*g_origCanOpen)(id, SEL, NSURL *) = NULL;
static BOOL jb_canOpenURL(id self, SEL _cmd, NSURL *url) {
    NSString *s = [url absoluteString];
    if (s) {
        NSString *low = [s lowercaseString];
        if ([low hasPrefix:@"cydia://"] || [low hasPrefix:@"sileo://"] ||
            [low hasPrefix:@"zebra://"] || [low hasPrefix:@"filza://"] ||
            [low hasPrefix:@"undecimus://"] || [low hasPrefix:@"electra://"]) {
            return NO;
        }
    }
    if (!g_origCanOpen) return NO;
    return g_origCanOpen(self, _cmd, url);
}

// ============================ dyld: ocultar dylibs de jailbreak ============================
static const char kFakeImageName[] = "/usr/lib/libSystem.B.dylib";
static const char *(*real_dyld_image_name)(uint32_t);
static const char *hook_dyld_image_name(uint32_t index) {
    const char *n = real_dyld_image_name(index);
    if (n) {
        if (strstr(n, "Cydia") || strstr(n, "substrate") || strstr(n, "Substrate") ||
            strstr(n, "ellekit") || strstr(n, "ElleKit") || strstr(n, "TweakInject") ||
            strstr(n, "frida") || strstr(n, "Frida")) {
            return kFakeImageName;
        }
    }
    return n;
}

// ============================ fork/system: comportamiento sandbox ============================
static pid_t (*real_fork)(void);
static pid_t hook_fork(void) {
    return -1;
}
static FILE *(*real_popen)(const char *, const char *);
static FILE *hook_popen(const char *cmd, const char *mode) {
    return NULL;
}

// ============================ constructor ============================
__attribute__((constructor))
static void jbhide_init(void) {
    // SOLO en la app objetivo — jamas en SpringBoard/Camara
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid || ![bid isEqualToString:@"com.interbank.bancamovil"]) {
        return;
    }

    MSHookFunction((void *)open, (void *)hook_open, (void **)&real_open);
    MSHookFunction((void *)fopen, (void *)hook_fopen, (void **)&real_fopen);
    MSHookFunction((void *)access, (void *)hook_access, (void **)&real_access);
    MSHookFunction((void *)stat, (void *)hook_stat, (void **)&real_stat);
    MSHookFunction((void *)lstat, (void *)hook_lstat, (void **)&real_lstat);
    MSHookFunction((void *)fstatat, (void *)hook_fstatat, (void **)&real_fstatat);
    MSHookFunction((void *)getattrlist, (void *)hook_getattrlist, (void **)&real_getattrlist);
    MSHookFunction((void *)opendir, (void *)hook_opendir, (void **)&real_opendir);
    MSHookFunction((void *)sysctl, (void *)hook_sysctl, (void **)&real_sysctl);
    MSHookFunction((void *)fork, (void *)hook_fork, (void **)&real_fork);
    MSHookFunction((void *)popen, (void *)hook_popen, (void **)&real_popen);
    MSHookFunction((void *)_dyld_get_image_name, (void *)hook_dyld_image_name, (void **)&real_dyld_image_name);

    Class nsFileMgr = objc_getClass("NSFileManager");
    if (nsFileMgr) {
        Method m1 = class_getInstanceMethod(nsFileMgr, sel_registerName("fileExistsAtPath:"));
        if (m1) {
            g_origFileExists = (BOOL (*)(id, SEL, NSString *))method_getImplementation(m1);
            method_setImplementation(m1, (IMP)jb_fileExists);
        }
        Method m2 = class_getInstanceMethod(nsFileMgr, sel_registerName("isReadableFileAtPath:"));
        if (m2) {
            g_origIsReadable = (BOOL (*)(id, SEL, NSString *))method_getImplementation(m2);
            method_setImplementation(m2, (IMP)jb_isReadable);
        }
        Method m3 = class_getInstanceMethod(nsFileMgr, sel_registerName("isExecutableFileAtPath:"));
        if (m3) {
            g_origIsExec = (BOOL (*)(id, SEL, NSString *))method_getImplementation(m3);
            method_setImplementation(m3, (IMP)jb_isExec);
        }
        Method m4 = class_getInstanceMethod(nsFileMgr, sel_registerName("contentsOfDirectoryAtPath:error:"));
        if (m4) {
            g_origContents = (id (*)(id, SEL, NSString *, NSError **))method_getImplementation(m4);
            method_setImplementation(m4, (IMP)jb_contents);
        }
        Method m5 = class_getInstanceMethod(nsFileMgr, sel_registerName("attributesOfItemAtPath:error:"));
        if (m5) {
            g_origAttrs = (id (*)(id, SEL, NSString *, NSError **))method_getImplementation(m5);
            method_setImplementation(m5, (IMP)jb_attrs);
        }
    }

    Class uiApp = objc_getClass("UIApplication");
    if (uiApp) {
        Method cm = class_getInstanceMethod(uiApp, sel_registerName("canOpenURL:"));
        if (cm) {
            g_origCanOpen = (BOOL (*)(id, SEL, NSURL *))method_getImplementation(cm);
            method_setImplementation(cm, (IMP)jb_canOpenURL);
        }
    }
}
