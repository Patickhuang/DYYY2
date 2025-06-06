//
//  FLEXRuntimeClient.m
//  FLEX
//
//  由 Tanner 创建于 3/22/17.
//  版权所有 © 2017 Tanner Bennett. 保留所有权利。
//

#import "FLEXRuntimeClient.h"
#import "NSObject+FLEX_Reflection.h"
#import "FLEXMethod.h"
#import "NSArray+FLEX.h"
#import "FLEXRuntimeSafety.h"
#include <dlfcn.h>

#define Equals(a, b)    ([a compare:b options:NSCaseInsensitiveSearch] == NSOrderedSame)
#define Contains(a, b)  ([a rangeOfString:b options:NSCaseInsensitiveSearch].location != NSNotFound)
#define HasPrefix(a, b) ([a rangeOfString:b options:NSCaseInsensitiveSearch].location == 0)
#define HasSuffix(a, b) ([a rangeOfString:b options:NSCaseInsensitiveSearch].location == (a.length - b.length))


@interface FLEXRuntimeClient () {
    NSMutableArray<NSString *> *_imageDisplayNames;
}

@property (nonatomic) NSMutableDictionary *bundles_pathToShort;
@property (nonatomic) NSMutableDictionary *bundles_shortToPath;
@property (nonatomic) NSCache *bundles_pathToClassNames;
@property (nonatomic) NSMutableArray<NSString *> *imagePaths;

@end

/// @return 如果映射通过则返回 success。
static inline NSString * TBWildcardMap_(NSString *token, NSString *candidate, NSString *success, TBWildcardOptions options) {
    switch (options) {
        case TBWildcardOptionsNone:
            // 仅当"相等"时
            if (Equals(candidate, token)) {
                return success;
            }
        default: {
            // 仅当"包含"时
            if (options & TBWildcardOptionsPrefix &&
                options & TBWildcardOptionsSuffix) {
                if (Contains(candidate, token)) {
                    return success;
                }
            }
            // 仅当"候选者以 token 结尾"时
            else if (options & TBWildcardOptionsPrefix) {
                if (HasSuffix(candidate, token)) {
                    return success;
                }
            }
            // 仅当"候选者以 token 开头"时
            else if (options & TBWildcardOptionsSuffix) {
                // 类似 "Bundle." 的情况，我们希望 "" 匹配任何内容
                if (!token.length) {
                    return success;
                }
                if (HasPrefix(candidate, token)) {
                    return success;
                }
            }
        }
    }

    return nil;
}

/// @return 如果映射通过则返回候选者。
static inline NSString * TBWildcardMap(NSString *token, NSString *candidate, TBWildcardOptions options) {
    return TBWildcardMap_(token, candidate, candidate, options);
}

@implementation FLEXRuntimeClient

#pragma mark - 初始化

+ (instancetype)runtime {
    static FLEXRuntimeClient *runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime = [self new];
        [runtime reloadLibrariesList];
    });

    return runtime;
}

- (id)init {
    self = [super init];
    if (self) {
        _imagePaths = [NSMutableArray new];
        _bundles_pathToShort = [NSMutableDictionary new];
        _bundles_shortToPath = [NSMutableDictionary new];
        _bundles_pathToClassNames = [NSCache new];
    }

    return self;
}

#pragma mark - 私有方法

- (void)reloadLibrariesList {
    unsigned int imageCount = 0;
    const char **imageNames = objc_copyImageNames(&imageCount);

    if (imageNames) {
        NSMutableArray *imageNameStrings = [NSMutableArray flex_forEachUpTo:imageCount map:^NSString *(NSUInteger i) {
            return @(imageNames[i]);
        }];

        self.imagePaths = imageNameStrings;
        free(imageNames);

        // 按字母顺序排序
        [imageNameStrings sortUsingComparator:^NSComparisonResult(NSString *name1, NSString *name2) {
            NSString *shortName1 = [self shortNameForImageName:name1];
            NSString *shortName2 = [self shortNameForImageName:name2];
            return [shortName1 caseInsensitiveCompare:shortName2];
        }];

        // 缓存图像显示名称
        _imageDisplayNames = [imageNameStrings flex_mapped:^id(NSString *path, NSUInteger idx) {
            return [self shortNameForImageName:path];
        }];
    }
}

- (NSString *)shortNameForImageName:(NSString *)imageName {
    // 缓存
    NSString *shortName = _bundles_pathToShort[imageName];
    if (shortName) {
        return shortName;
    }

    NSArray *components = [imageName componentsSeparatedByString:@"/"];
    if (components.count >= 2) {
        NSString *parentDir = components[components.count - 2];
        if ([parentDir hasSuffix:@".framework"] || [parentDir hasSuffix:@".axbundle"]) {
            if ([imageName hasSuffix:@".dylib"]) {
                shortName = imageName.lastPathComponent;
            } else {
                shortName = parentDir;
            }
        }
    }

    if (!shortName) {
        shortName = imageName.lastPathComponent;
    }

    _bundles_pathToShort[imageName] = shortName;
    _bundles_shortToPath[shortName] = imageName;
    return shortName;
}

- (NSString *)imageNameForShortName:(NSString *)imageName {
    return _bundles_shortToPath[imageName];
}

- (NSMutableArray<NSString *> *)classNamesInImageAtPath:(NSString *)path {
    // 检查缓存
    NSMutableArray *classNameStrings = [_bundles_pathToClassNames objectForKey:path];
    if (classNameStrings) {
        return classNameStrings.mutableCopy;
    }

    unsigned int classCount = 0;
    const char **classNames = objc_copyClassNamesForImage(path.UTF8String, &classCount);

    if (classNames) {
        classNameStrings = [NSMutableArray flex_forEachUpTo:classCount map:^id(NSUInteger i) {
            return @(classNames[i]);
        }];

        free(classNames);

        [classNameStrings sortUsingSelector:@selector(caseInsensitiveCompare:)];
        [_bundles_pathToClassNames setObject:classNameStrings forKey:path];

        return classNameStrings.mutableCopy;
    }

    return [NSMutableArray new];
}

#pragma mark - 公共方法

+ (void)initializeWebKitLegacy {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/WebKitLegacy.framework/WebKitLegacy",
            RTLD_LAZY
        );
        void (*WebKitInitialize)(void) = dlsym(handle, "WebKitInitialize");
        if (WebKitInitialize) {
            NSAssert(NSThread.isMainThread,
                @"WebKitInitialize 只能在主线程上调用"
            );
            WebKitInitialize();
        }
    });
}

- (NSArray<Class> *)copySafeClassList {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    return [NSArray flex_forEachUpTo:count map:^id(NSUInteger i) {
        Class cls = classes[i];
        return FLEXClassIsSafe(cls) ? cls : nil;
    }];
}

- (NSArray<Protocol *> *)copyProtocolList {
    unsigned int count = 0;
    Protocol *__unsafe_unretained *protocols = objc_copyProtocolList(&count);
    return [NSArray arrayWithObjects:protocols count:count];
}

- (NSMutableArray<NSString *> *)bundleNamesForToken:(FLEXSearchToken *)token {
    if (self.imagePaths.count) {
        TBWildcardOptions options = token.options;
        NSString *query = token.string;

        // 优化，避免循环
        if (options == TBWildcardOptionsAny) {
            return _imageDisplayNames;
        }

        // 不使用点语法，因为 imageDisplayNames 只在内部可变
        return [_imageDisplayNames flex_mapped:^id(NSString *binary, NSUInteger idx) {
//            NSString *UIName = [self shortNameForImageName:binary];
            return TBWildcardMap(query, binary, options);
        }];
    }

    return [NSMutableArray new];
}

- (NSMutableArray<NSString *> *)bundlePathsForToken:(FLEXSearchToken *)token {
    if (self.imagePaths.count) {
        TBWildcardOptions options = token.options;
        NSString *query = token.string;

        // 优化，避免循环
        if (options == TBWildcardOptionsAny) {
            return self.imagePaths;
        }

        return [self.imagePaths flex_mapped:^id(NSString *binary, NSUInteger idx) {
            NSString *UIName = [self shortNameForImageName:binary];
            // 如果 query == UIName，-> binary
            return TBWildcardMap_(query, UIName, binary, options);
        }];
    }

    return [NSMutableArray new];
}

- (NSMutableArray<NSString *> *)classesForToken:(FLEXSearchToken *)token inBundles:(NSMutableArray<NSString *> *)bundles {
    // 边缘情况，token 已经是我们想要的类；返回父类
    if (token.isAbsolute) {
        if (FLEXClassIsSafe(NSClassFromString(token.string))) {
            return [NSMutableArray arrayWithObject:token.string];
        }

        return [NSMutableArray new];
    }

    if (bundles.count) {
        // 获取类名，移除不安全的类
        NSMutableArray<NSString *> *names = [self _classesForToken:token inBundles:bundles];
        return [names flex_mapped:^NSString *(NSString *name, NSUInteger idx) {
            Class cls = NSClassFromString(name);
            BOOL safe = FLEXClassIsSafe(cls);
            return safe ? name : nil;
        }];
    }

    return [NSMutableArray new];
}

- (NSMutableArray<NSString *> *)_classesForToken:(FLEXSearchToken *)token inBundles:(NSMutableArray<NSString *> *)bundles {
    TBWildcardOptions options = token.options;
    NSString *query = token.string;

    // 优化，避免不必要的排序
    if (bundles.count == 1) {
        // 优化，避免循环
        if (options == TBWildcardOptionsAny) {
            return [self classNamesInImageAtPath:bundles.firstObject];
        }

        return [[self classNamesInImageAtPath:bundles.firstObject] flex_mapped:^id(NSString *className, NSUInteger idx) {
            return TBWildcardMap(query, className, options);
        }];
    }
    else {
        // 优化，避免循环
        if (options == TBWildcardOptionsAny) {
            return [[bundles flex_flatmapped:^NSArray *(NSString *bundlePath, NSUInteger idx) {
                return [self classNamesInImageAtPath:bundlePath];
            }] flex_sortedUsingSelector:@selector(caseInsensitiveCompare:)];
        }

        return [[bundles flex_flatmapped:^NSArray *(NSString *bundlePath, NSUInteger idx) {
            return [[self classNamesInImageAtPath:bundlePath] flex_mapped:^id(NSString *className, NSUInteger idx) {
                return TBWildcardMap(query, className, options);
            }];
        }] flex_sortedUsingSelector:@selector(caseInsensitiveCompare:)];
    }
}

- (NSArray<NSMutableArray<FLEXMethod *> *> *)methodsForToken:(FLEXSearchToken *)token
                                                    instance:(NSNumber *)checkInstance
                                                   inClasses:(NSArray<NSString *> *)classes {
    if (classes.count) {
        TBWildcardOptions options = token.options;
        BOOL instance = checkInstance.boolValue;
        NSString *selector = token.string;

        switch (options) {
            // 实际上，我认为这种情况在方法中从未使用过，
            // 因为它们总是在末尾有一个后缀通配符
            case TBWildcardOptionsNone: {
                SEL sel = (SEL)selector.UTF8String;
                return @[[classes flex_mapped:^id(NSString *name, NSUInteger idx) {
                    Class cls = NSClassFromString(name);
                    // 如果不是实例方法则使用元类
                    if (!instance) {
                        cls = object_getClass(cls);
                    }
                    
                    // 方法是绝对的
                    return [FLEXMethod selector:sel class:cls];
                }]];
            }
            case TBWildcardOptionsAny: {
                return [classes flex_mapped:^NSArray *(NSString *name, NSUInteger idx) {
                    // Any 表示未指定 `instance`
                    Class cls = NSClassFromString(name);
                    return [cls flex_allMethods];
                }];
            }
            default: {
                // 仅当"包含"时
                if (options & TBWildcardOptionsPrefix &&
                    options & TBWildcardOptionsSuffix) {
                    return [classes flex_mapped:^NSArray *(NSString *name, NSUInteger idx) {
                        Class cls = NSClassFromString(name);
                        return [[cls flex_allMethods] flex_mapped:^id(FLEXMethod *method, NSUInteger idx) {

                            // 方法是前缀-后缀通配符
                            if (Contains(method.selectorString, selector)) {
                                return method;
                            }
                            return nil;
                        }];
                    }];
                }
                // 仅当"方法以选择器结尾"时
                else if (options & TBWildcardOptionsPrefix) {
                    return [classes flex_mapped:^NSArray *(NSString *name, NSUInteger idx) {
                        Class cls = NSClassFromString(name);

                        return [[cls flex_allMethods] flex_mapped:^id(FLEXMethod *method, NSUInteger idx) {
                            // 方法是前缀通配符
                            if (HasSuffix(method.selectorString, selector)) {
                                return method;
                            }
                            return nil;
                        }];
                    }];
                }
                // 仅当"方法以选择器开头"时
                else if (options & TBWildcardOptionsSuffix) {
                    assert(checkInstance);

                    return [classes flex_mapped:^NSArray *(NSString *name, NSUInteger idx) {
                        Class cls = NSClassFromString(name);

                        // 类似 "Bundle.class.-" 的情况，我们希望 "-" 匹配任何内容
                        if (!selector.length) {
                            if (instance) {
                                return [cls flex_allInstanceMethods];
                            } else {
                                return [cls flex_allClassMethods];
                            }
                        }

                        id mapping = ^id(FLEXMethod *method) {
                            // 方法是后缀通配符
                            if (HasPrefix(method.selectorString, selector)) {
                                return method;
                            }
                            return nil;
                        };

                        if (instance) {
                            return [[cls flex_allInstanceMethods] flex_mapped:mapping];
                        } else {
                            return [[cls flex_allClassMethods] flex_mapped:mapping];
                        }
                    }];
                }
            }
        }
    }
    
    return [NSMutableArray new];
}

@end
