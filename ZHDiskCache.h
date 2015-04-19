#import <Foundation/Foundation.h>

#define CACHE_BAT_PREFIX            @"CACHE_BAT_PREFIX"
#define CACHE_COLOR_PREFIX          @"CACHE_COLOR_PREFIX"

@interface ZHDiskCache : NSObject {
    NSString *_rootPath;
}

@property (nonatomic, readonly) NSString *rootPath;
@property (nonatomic) NSInteger limitOfSize; // bytes

+ (instancetype)sharedCache;

- (NSString *)filePathForKey:(NSString *)key;
- (BOOL)hasObjectForKey:(NSString *)key;
- (id)objectForKey:(NSString *)key;

- (void)cacheObject:(NSData*)data forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;

- (void)removeAllObjects; // will be called automatically when currentSize > limitOfSize.
- (void)removeObjectsByAccessedDate:(NSDate *)accessedDate;
- (void)removeObjectsUsingBlock:(BOOL (^)(NSString *filePath))block;

@end
