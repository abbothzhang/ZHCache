#import "ZHDiskCache.h"
#import <CommonCrypto/CommonCrypto.h>

static NSString *const ISDiskCacheException = @"ISDiskCacheException";

#define TBMIRROR_CACHE_DIRECTORY    @"TBMIRROR_CACHE_DIRECTORY"
#define TBMIRROR_USERDEFAULT_DATA_YETCACHEDKEY_DIC  @"TBMIRROR_USERDEFAULT_DATA_YETCACHEDKEY_DIC"
#define TBMIRROR_USERDEFAULT_DATA_RETAINCOUNT_DIC  @"TBMIRROR_USERDEFAULT_DATA_RETAINCOUNT_DIC"
#define TBMIRROR_USERDEFAULT_KEY_YETCACHEDKEY_DIC  @"TBMIRROR_USERDEFAULT_KEY_YETCACHEDKEY_DIC"

@interface ZHDiskCache ()

#if OS_OBJECT_USE_OBJC
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
#else
@property (nonatomic, assign) dispatch_semaphore_t semaphore;
#endif

@property (nonatomic, readonly) NSOperationQueue    *calculationQueue;
@property (nonatomic, strong) NSUserDefaults        *defaults;
@property (nonatomic, strong) NSMutableDictionary   *dataMD5_yetCachedKeyDic;
@property (nonatomic, strong) NSMutableDictionary   *key_yetCachedKeyDic;

@property (nonatomic, strong) NSMutableDictionary   *dataMD5_RetainCountDic;

@end

@implementation ZHDiskCache

+ (instancetype)sharedCache
{
    static ZHDiskCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[ZHDiskCache alloc] init];
    });
    return cache;
}

- (id)init
{
    self = [super init];
    if (self) {
        _calculationQueue = [[NSOperationQueue alloc] init];
        _semaphore = dispatch_semaphore_create(1);//使用semaphore来控制多线程
        _limitOfSize = 16 * 1024 * 1024; // 100MB
        _defaults = [NSUserDefaults standardUserDefaults];
//        [self performSelectorInBackground:@selector(calculateCurrentSize) withObject:nil];
    }
    return self;
}

- (void)dealloc
{
#if !OS_OBJECT_USE_OBJC
    dispatch_release(_semaphore);
#endif
}

#pragma mark - initDate
-(NSMutableDictionary *)dataMD5_yetCachedKeyDic{
    NSDictionary *dic = [_defaults objectForKey:TBMIRROR_USERDEFAULT_DATA_YETCACHEDKEY_DIC];
    if(dic == nil){
        if(!_dataMD5_yetCachedKeyDic){
            _dataMD5_yetCachedKeyDic = [[NSMutableDictionary alloc] initWithCapacity:10];
        }
        [_defaults setValue:_dataMD5_yetCachedKeyDic forKey:TBMIRROR_USERDEFAULT_DATA_YETCACHEDKEY_DIC];
    }else{
        _dataMD5_yetCachedKeyDic = [[NSMutableDictionary alloc] initWithDictionary:dic];
    }
    return _dataMD5_yetCachedKeyDic;
}

-(NSMutableDictionary *)dataMD5_RetainCountDic{
    NSDictionary *dic = [_defaults objectForKey:TBMIRROR_USERDEFAULT_DATA_RETAINCOUNT_DIC];
    if(dic == nil){
        if(!_dataMD5_RetainCountDic){
            _dataMD5_RetainCountDic = [[NSMutableDictionary alloc] initWithCapacity:10];
        }
        [_defaults setValue:_dataMD5_RetainCountDic forKey:TBMIRROR_USERDEFAULT_DATA_RETAINCOUNT_DIC];
    }else{
        _dataMD5_RetainCountDic = [[NSMutableDictionary alloc] initWithDictionary:dic];
    }
    return _dataMD5_RetainCountDic;
}

-(NSMutableDictionary *)key_yetCachedKeyDic{
    NSDictionary *dic = [_defaults objectForKey:TBMIRROR_USERDEFAULT_KEY_YETCACHEDKEY_DIC];
    if(dic == nil){
        if(!_key_yetCachedKeyDic){
            _key_yetCachedKeyDic = [[NSMutableDictionary alloc] initWithCapacity:10];
        }
        [_defaults setValue:_key_yetCachedKeyDic forKey:TBMIRROR_USERDEFAULT_KEY_YETCACHEDKEY_DIC];
    }else{
        _key_yetCachedKeyDic = [[NSMutableDictionary alloc] initWithDictionary:dic];
    }
    return _key_yetCachedKeyDic;

}


#pragma mark - paths

- (NSString *)rootPath
{
    if (_rootPath) {
        return _rootPath;
    }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    _rootPath = [[paths objectAtIndex:0] stringByAppendingPathComponent:TBMIRROR_CACHE_DIRECTORY];
    return _rootPath;
}

//用keyMD5加密后的字符串作为文件名，给出文件路径
- (NSString *)filePathForKey:(NSString *)key
{
    NSString *yetCachedKey = [_key_yetCachedKeyDic objectForKey:key];
    if (yetCachedKey) {
        key = yetCachedKey;
    }
    
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:key];
    if ([data length] == 0) {
        return nil;
    }
    
    NSString *cacheKey = [self getObjectMD5:key];
    NSString *prefix = [cacheKey substringToIndex:2];
    NSString *directoryPath = [self.rootPath stringByAppendingPathComponent:prefix];
    return [directoryPath stringByAppendingPathComponent:cacheKey];
}

- (NSArray *)validFilePathsUnderPath:(NSString *)parentPath
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray *paths = [@[] mutableCopy];
    for (NSString *subpath in [fileManager subpathsAtPath:parentPath]) {
        NSString *path = [parentPath stringByAppendingPathComponent:subpath];
        [paths addObject:path];
    }
    
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        NSString *path = (NSString *)evaluatedObject;
        BOOL isHidden = [[path lastPathComponent] hasPrefix:@"."];
        BOOL isDirectory;
        BOOL exists = [fileManager fileExistsAtPath:path isDirectory:&isDirectory];
        return !isHidden && !isDirectory && exists;
    }];
    
    return [paths filteredArrayUsingPredicate:predicate];
}

#pragma mark - key
//通过NSFileManager fileExistsAtPath判断这个文件是否存在
- (BOOL)hasObjectForKey:(NSString *)key
{
//    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    
    NSString *path = [self filePathForKey:key];
    BOOL hasObject = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:NULL];
//    dispatch_semaphore_signal(self.semaphore);
    return hasObject;
}

- (id)objectForKey:(NSString *)key
{
   //test
//    [self calculateCurrentSize];
    
    
    if (![self hasObjectForKey:key]) {
        return nil;
    }
    
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    NSString *path = [self filePathForKey:key];
    NSMutableDictionary *attributes = [[self attributesForFilePath:path] mutableCopy];
    if (attributes) {
        [attributes setObject:[NSDate date] forKey:NSFileModificationDate];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSError *error = nil;
        if (![fileManager setAttributes:[attributes copy] ofItemAtPath:path error:&error]) {
//            [NSException raise:ISDiskCacheException format:@"%@", error];
        }
    }
    
    NSData *data = [NSData dataWithContentsOfFile:path];
    //引用计数加一
    if (data != nil) {
        NSString *dataMD5 = [self getObjectMD5:data];
        NSInteger retainCount = [[self.dataMD5_RetainCountDic objectForKey:dataMD5] intValue];
        //如果retainCount没有会有什么问题todomark
        retainCount++;
        [_dataMD5_RetainCountDic setObject:@(retainCount) forKey:dataMD5];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setValue:_dataMD5_RetainCountDic forKey:TBMIRROR_USERDEFAULT_DATA_RETAINCOUNT_DIC];
    }
    dispatch_semaphore_signal(self.semaphore);
    return data;
}

- (void)cacheObject:(NSData*)data forKey:(NSString *)key
{
    //test
//    [self calculateCurrentSize];
    
    if ([self hasObjectForKey:key]) {
        return;
    }

    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
//    //如果本地已经有object，则不重复缓存，用object的md5做标识
    NSString *md5 = [self getObjectMD5:data];
    NSString *yetCachedKey = [self.dataMD5_yetCachedKeyDic objectForKey:md5];
    //如果yetCachedKey且文件确实存在，那么object已经存储不再进行缓存，将key对应的缓存路径指向已经存在的object
    if (yetCachedKey && [self hasObjectForKey:yetCachedKey]) {

        [self.key_yetCachedKeyDic setObject:yetCachedKey forKey:key];
        [_defaults setValue:_key_yetCachedKeyDic forKey:TBMIRROR_USERDEFAULT_KEY_YETCACHEDKEY_DIC];
        
        dispatch_semaphore_signal(self.semaphore);
        return;
    }
    
    NSString *path = [self filePathForKey:key];
    NSString *directoryPath = [path stringByDeletingLastPathComponent];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:directoryPath isDirectory:NULL]) {
        NSError *error = nil;
        if (![fileManager createDirectoryAtPath:directoryPath withIntermediateDirectories:YES attributes:nil error:&error]) {
//            [NSException raise:ISDiskCacheException format:@"%@", error];
        }
    }
    
    
    [data writeToFile:path atomically:YES];
    
    [_dataMD5_yetCachedKeyDic setValue:key forKey:md5];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue:_dataMD5_yetCachedKeyDic forKey:TBMIRROR_USERDEFAULT_DATA_YETCACHEDKEY_DIC];
    //给这个data的md5文件一个1的初始引用
    [self.dataMD5_RetainCountDic setValue:@(1) forKey:md5];
    [defaults setValue:_dataMD5_RetainCountDic forKey:TBMIRROR_USERDEFAULT_DATA_RETAINCOUNT_DIC];
    dispatch_semaphore_signal(self.semaphore);
    [self calculateCurrentSize];
}

-(NSString *)getObjectMD5:(id <NSCoding>)object{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object];
    if ([data length] == 0) {
        return nil;
    }
    unsigned char result[16];
    CC_MD5([data bytes], (CC_LONG)[data length], result);
    NSString *objectMD5 = [NSString stringWithFormat:@"%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X",
                           result[0], result[1], result[2], result[3], result[4], result[5], result[6], result[7],
                           result[8], result[9], result[10], result[11],result[12], result[13], result[14], result[15]];
    return objectMD5;
}

#pragma mark - remove
- (void)removeObjectForKey:(id)key
{
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    NSString *yetCachedKey = [_key_yetCachedKeyDic objectForKey:key];
    if (yetCachedKey) {
        key = yetCachedKey;//重定向到之前有缓存的key
    }
    NSString *filePath = [self filePathForKey:key];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:filePath isDirectory:NULL]) {
        NSError *error = nil;
        if (![fileManager removeItemAtPath:filePath error:&error]) {
//            [NSException raise:NSInvalidArgumentException format:@"%@", error];
        }
    }
    
    NSString *directoryPath = [filePath stringByDeletingLastPathComponent];
    [self removeDirectoryIfEmpty:directoryPath];
    dispatch_semaphore_signal(self.semaphore);
}

- (void)removeDirectoryIfEmpty:(NSString *)directoryPath
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:directoryPath]) {
        return;
    }
        
    if (![[self validFilePathsUnderPath:directoryPath] count]) {
        NSError *error = nil;
        if (![fileManager removeItemAtPath:directoryPath error:&error]) {
//            [NSException raise:ISDiskCacheException format:@"%@", error];
        }
    }
}

- (void)removeObjectsByAccessedDate:(NSDate *)borderDate
{
    [self removeObjectsUsingBlock:^BOOL(NSString *filePath) {
        NSDictionary *attributes = [self attributesForFilePath:filePath];
        NSDate *modificationDate = [attributes objectForKey:NSFileModificationDate];
        return [modificationDate timeIntervalSinceDate:borderDate] < 0.0;
    }];
}

- (void)removeObjectsUsingBlock:(BOOL (^)(NSString *))block
{
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in [fileManager subpathsAtPath:self.rootPath]) {
        NSString *filePath = [self.rootPath stringByAppendingPathComponent:path];
        if ([[filePath lastPathComponent] hasPrefix:@"."]) {
            continue;
        }
        
        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:filePath isDirectory:&isDirectory] && !isDirectory) {
            if (block(filePath)) {
                NSError *error = nil;
                if (![fileManager removeItemAtPath:filePath error:&error]) {
//                    [NSException raise:ISDiskCacheException format:@"%@", error];
                }
                
                NSString *directoryPath = [filePath stringByDeletingLastPathComponent];
                [self removeDirectoryIfEmpty:directoryPath];
            }
        }
    }
    dispatch_semaphore_signal(self.semaphore);
}

- (void)removeAllObjects
{
    //会把文件夹下缓存的所有文件删掉
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    static NSString *ISDiskCacheFilePathKey = @"ISDiskCacheFilePathKey";
    
    NSMutableArray *attributesArray = [@[] mutableCopy];
    for (NSString *filePath in [self validFilePathsUnderPath:self.rootPath]) {
        NSMutableDictionary *attributes = [[self attributesForFilePath:filePath] mutableCopy];
        [attributes setObject:filePath forKey:ISDiskCacheFilePathKey];
        [attributesArray addObject:attributes];
    }
    
    [attributesArray sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        NSDate *date1 = [obj1 objectForKey:NSFileModificationDate];
        NSDate *date2 = [obj2 objectForKey:NSFileModificationDate];
        return [date2 compare:date1];
    }];
    
    NSInteger sum = 0;
    for (NSDictionary *attributes in [attributesArray copy]) {
        sum += [[attributes objectForKey:NSFileSize] integerValue];
        if (sum >= self.limitOfSize / 2) {
            break;
        }
        [attributesArray removeObject:attributes];
    }
    dispatch_semaphore_signal(self.semaphore);
    
    NSArray *filePathsToRemove = [attributesArray valueForKey:ISDiskCacheFilePathKey];
    
    [self removeObjectsUsingBlock:^BOOL(NSString *filePath) {
        return [filePathsToRemove containsObject:filePath];
    }];
    
    [self.dataMD5_yetCachedKeyDic removeAllObjects];
    [self.key_yetCachedKeyDic removeAllObjects];
    [self.dataMD5_RetainCountDic removeAllObjects];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue:_dataMD5_yetCachedKeyDic forKey:TBMIRROR_USERDEFAULT_DATA_YETCACHEDKEY_DIC];
    [defaults setValue:_dataMD5_RetainCountDic forKey:TBMIRROR_USERDEFAULT_DATA_RETAINCOUNT_DIC];
    [defaults setValue:_dataMD5_yetCachedKeyDic forKey:TBMIRROR_USERDEFAULT_KEY_YETCACHEDKEY_DIC];
    
    
}

//删除一半文件(不常用的那一半文件)
-(void)removeOldObjects{
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    //dataMD5按照引用数进行排序,排完序后key值会根据引用数进行升序排列
    [self.dataMD5_RetainCountDic keysSortedByValueUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        if ([obj1 integerValue] > [obj2 integerValue]) {
            return (NSComparisonResult)NSOrderedAscending;
        }
        if ([obj1 integerValue] < [obj2 integerValue]) {
            return (NSComparisonResult)NSOrderedDescending;
        }
        return (NSComparisonResult)NSOrderedSame;
    }];
    
    NSArray *key_yetCachedKeyDicKeys = [self.key_yetCachedKeyDic allKeys];
    
    NSArray *dataMD5Array = [self.dataMD5_RetainCountDic allKeys];
    NSMutableArray *filePathArray = [[NSMutableArray alloc] initWithCapacity:dataMD5Array.count/2];
    for (NSUInteger i = dataMD5Array.count-1; i > dataMD5Array.count/2-1; i--) {
        NSString *yetCachedKey = [self.dataMD5_yetCachedKeyDic objectForKey:[dataMD5Array objectAtIndex:i]];
        NSString *filePath = [self filePathForKey:yetCachedKey];
        [filePathArray addObject:filePath];
        //清理defaults中缓存的值todomark
//        self.dataMD5_yetCachedKeyDic removeObjectForKey:
        //删除key_yetCachedKeyDic中的值
        for (NSString *key in key_yetCachedKeyDicKeys) {
            if ([[self.key_yetCachedKeyDic objectForKey:key] isEqualToString:yetCachedKey]) {
                [_key_yetCachedKeyDic removeObjectForKey:key];
                [_defaults setValue:_key_yetCachedKeyDic forKey:TBMIRROR_USERDEFAULT_KEY_YETCACHEDKEY_DIC];
            }
        }
        
        [self.dataMD5_yetCachedKeyDic removeObjectForKey:[dataMD5Array objectAtIndex:i]];
        [self.dataMD5_RetainCountDic removeObjectForKey:[dataMD5Array objectAtIndex:i]];
        [_defaults setValue:_dataMD5_yetCachedKeyDic forKey:TBMIRROR_USERDEFAULT_DATA_YETCACHEDKEY_DIC];
        [_defaults setValue:_dataMD5_RetainCountDic forKey:TBMIRROR_USERDEFAULT_DATA_RETAINCOUNT_DIC];
    }
    
    dispatch_semaphore_signal(self.semaphore);
    
    [self removeObjectsUsingBlock:^BOOL(NSString *filePath) {
        return [filePathArray containsObject:filePath];
    }];
    
    
    
}


- (NSDictionary *)attributesForFilePath:(NSString *)filePath
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSMutableDictionary *attributes = [[fileManager attributesOfItemAtPath:filePath error:&error] mutableCopy];
    if (error) {
        if (error.code == NSFileReadNoSuchFileError) {
            return nil;
        } else {
//            [NSException raise:ISDiskCacheException format:@"%@", error];
        }
    }
    return attributes;
}

- (void)calculateCurrentSize
{
    __weak __typeof(self) weakSelf = self;
    [self.calculationQueue cancelAllOperations];
    [self.calculationQueue addOperationWithBlock:^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        dispatch_semaphore_wait(strongSelf.semaphore, DISPATCH_TIME_FOREVER);
        NSInteger sum = 0;
        for (NSString *filePath in [strongSelf validFilePathsUnderPath:strongSelf.rootPath]) {
            NSDictionary *attributes = [strongSelf attributesForFilePath:filePath];
            sum += [[attributes objectForKey:NSFileSize] integerValue];
        }
        
        dispatch_semaphore_signal(strongSelf.semaphore);
        
        if (sum >= strongSelf.limitOfSize) {
            [strongSelf removeOldObjects];
        }
        

    }];
}




@end
