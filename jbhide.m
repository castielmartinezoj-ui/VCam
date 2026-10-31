// jbhide.m — ocultamiento de jailbreak SIN frida, SIN substrate
// Inline hooker arm64 propio + interposicion de las funciones que la app usa.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/mman.h>
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>
#import <errno.h>
#import <sys/attr.h>
#import <stdarg.h>
#import <dlfcn.h>

// ============================ inline hooker (arm64) ============================
static void arm64_patch(void *target, void *replacement, uint8_t *saved) {
    memcpy(saved, target, 16);
    uint32_t *p = (uint32_t *)target;
    uintptr_t addr = (uintptr_t)replacement;
    p[0] = 0x58000050;                          // ldr x16, #8
    p[1] = 0xD61F0200;                          // br x16
    *(uintptr_t *)(p + 2) = addr;
    typedef void (*ic_fn)(void *, size_t);
    static ic_fn ic = NULL;
    if (!ic) ic = (ic_fn)dlsym(RTLD_DEFAULT, "sys_icache_invalidate");
    if (ic) ic((char *)target, 16);
}

#define MAX_HOOKS 24
typedef struct {
    void *orig;
    uint8_t saved[16];
    void *tramp;
} HookEntry;

static HookEntry g_hooks[MAX_HOOKS];
static int g_hookCount = 0;

static void *make_hook(void *target, void *replacement) {
    for (int i = 0; i < g_hookCount; i++) {
        if (g_hooks[i].orig == target) return g_hooks[i].tramp;
    }
    if (g_hookCount >= MAX_HOOKS) return target;
    HookEntry *e = &g_hooks[g_hookCount++];
    e->orig = target;
    arm64_patch(target, replacement, e->saved);
    void *mem = mmap(NULL, 64, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    memcpy(mem, e->saved, 16);
    uint32_t *tp = (uint32_t *)((uint8_t *)mem + 16);
    tp[0] = 0x58000050;
    tp[1] = 0xD61F0200;
    *(uintptr_t *)(tp + 2) = (uintptr_t)((uint8_t *)target + 16);
    mprotect(mem, 64, PROT_READ | PROT_EXEC);
    e->tramp = mem;
    return mem;
}

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

// ============================ constructor ============================
__attribute__((constructor))
static void jbhide_init(void) {
    real_open = make_hook((void *)open, (void *)hook_open);
    real_fopen = make_hook((void *)fopen, (void *)hook_fopen);
    real_access = make_hook((void *)access, (void *)hook_access);
    real_stat = make_hook((void *)stat, (void *)hook_stat);
    real_lstat = make_hook((void *)lstat, (void *)hook_lstat);
    real_fstatat = make_hook((void *)fstatat, (void *)hook_fstatat);
    real_getattrlist = make_hook((void *)getattrlist, (void *)hook_getattrlist);
    real_opendir = make_hook((void *)opendir, (void *)hook_opendir);
    real_sysctl = make_hook((void *)sysctl, (void *)hook_sysctl);

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
