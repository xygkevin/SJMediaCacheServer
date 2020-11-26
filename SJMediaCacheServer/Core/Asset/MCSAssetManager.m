//
//  MCSAssetManager.m
//  SJMediaCacheServer_Example
//
//  Created by 畅三江 on 2020/6/3.
//  Copyright © 2020 changsanjiang@gmail.com. All rights reserved.
//

#import "MCSAssetManager.h"
#import <objc/message.h>
#import <SJUIKit/SJSQLite3.h>
#import <SJUIKit/SJSQLite3+QueryExtended.h>
#import <SJUIKit/SJSQLite3+RemoveExtended.h>

#import "MCSAssetUsageLog.h"
#import "NSFileManager+MCS.h"
 
#import "FILEReader.h"
#import "FILEAsset.h"
 
#import "HLSReader.h"
#import "HLSAsset.h"

#import "MCSRootDirectory.h"
#import "MCSConsts.h"

static NSString *kReadwriteCount = @"readwriteCount";

typedef NS_ENUM(NSUInteger, MCSLimit) {
    MCSLimitNone,
    MCSLimitCount,
    MCSLimitCacheDiskSpace,
    MCSLimitFreeDiskSpace,
    MCSLimitExpires,
};

@interface MCSAssetUsageLog (MCSPrivate)
@property (nonatomic) NSInteger id;
@property (nonatomic) NSUInteger usageCount;

@property (nonatomic) NSTimeInterval updatedTime;
@property (nonatomic) NSTimeInterval createdTime;

@property (nonatomic) NSInteger asset;
@property (nonatomic) MCSAssetType assetType;
@end

#pragma mark -

@interface MCSAssetManager () {
    unsigned long long _cacheSize;
    unsigned long long _freeSize;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<MCSAsset> > *assets;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MCSAssetUsageLog *> *usageLogs;
@property (nonatomic, strong) SJSQLite3 *sqlite3;
@property (nonatomic) NSUInteger count;
@end

@implementation MCSAssetManager
+ (instancetype)shared {
    static id obj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        obj = [[self alloc] init];
    });
    return obj;
}

- (instancetype)init {
    self = [super init];
    if ( self ) {
        _sqlite3 = [SJSQLite3.alloc initWithDatabasePath:[MCSRootDirectory databasePath]];
        _count = [_sqlite3 countOfObjectsForClass:MCSAssetUsageLog.class conditions:nil error:NULL];
        _assets = NSMutableDictionary.dictionary;
        _usageLogs = NSMutableDictionary.dictionary;
        _checkInterval = 30;
        [self _checkRecursively];
        
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_assetMetadataDidLoadWithNote:) name:MCSAssetMetadataDidLoadNotification object:nil];
    }
    return self;
}

#pragma mark -

@synthesize cacheCountLimit = _cacheCountLimit;
- (void)setCacheCountLimit:(NSUInteger)cacheCountLimit {
    dispatch_barrier_async(dispatch_get_global_queue(0, 0), ^{
        if ( cacheCountLimit != self->_cacheCountLimit ) {
            self->_cacheCountLimit = cacheCountLimit;
            if ( cacheCountLimit != 0 ) {
                [self _removeAssetsForLimit:MCSLimitCount];
            }
        }
    });
}

- (NSUInteger)cacheCountLimit {
    __block NSUInteger cacheCountLimit = 0;
    dispatch_sync(dispatch_get_global_queue(0, 0), ^{
        cacheCountLimit = self->_cacheCountLimit;
    });
    return cacheCountLimit;
}

@synthesize maxDiskAgeForCache = _maxDiskAgeForCache;
- (void)setMaxDiskAgeForCache:(NSTimeInterval)maxDiskAgeForCache {
    dispatch_barrier_async(dispatch_get_global_queue(0, 0), ^{
        if ( maxDiskAgeForCache != self->_maxDiskAgeForCache ) {
            self->_maxDiskAgeForCache = maxDiskAgeForCache;
            if ( maxDiskAgeForCache != 0 ) {
                [self _removeAssetsForLimit:MCSLimitExpires];
            }
        }
    });
}

- (NSTimeInterval)maxDiskAgeForCache {
    __block NSTimeInterval maxDiskAgeForCache = 0;
    dispatch_sync(dispatch_get_global_queue(0, 0), ^{
        maxDiskAgeForCache = _maxDiskAgeForCache;
    });
    return maxDiskAgeForCache;
}

@synthesize maxDiskSizeForCache = _maxDiskSizeForCache;
- (void)setMaxDiskSizeForCache:(NSUInteger)maxDiskSizeForCache {
    dispatch_barrier_async(dispatch_get_global_queue(0, 0), ^{
        if ( maxDiskSizeForCache != self->_maxDiskSizeForCache ) {
            self->_maxDiskSizeForCache = maxDiskSizeForCache;
            if ( maxDiskSizeForCache != 0 ) {
                [self _removeAssetsForLimit:MCSLimitCacheDiskSpace];
            }
        }
    });
}
- (NSUInteger)maxDiskSizeForCache {
    __block NSUInteger maxDiskSizeForCache = 0;
    dispatch_sync(dispatch_get_global_queue(0, 0), ^{
        maxDiskSizeForCache = self->_maxDiskSizeForCache;
    });
    return maxDiskSizeForCache;
}

@synthesize reservedFreeDiskSpace = _reservedFreeDiskSpace;
- (void)setReservedFreeDiskSpace:(NSUInteger)reservedFreeDiskSpace {
    dispatch_barrier_async(dispatch_get_global_queue(0, 0), ^{
        if ( reservedFreeDiskSpace != self->_reservedFreeDiskSpace ) {
            self->_reservedFreeDiskSpace = reservedFreeDiskSpace;
            if ( reservedFreeDiskSpace != 0 ) {
                [self _removeAssetsForLimit:MCSLimitFreeDiskSpace];
            }
        }
    });
}

- (NSUInteger)reservedFreeDiskSpace {
    __block NSUInteger reservedFreeDiskSpace = 0;
    dispatch_sync(dispatch_get_global_queue(0, 0), ^{
        reservedFreeDiskSpace = self->_reservedFreeDiskSpace;
    });
    return reservedFreeDiskSpace;
}

@synthesize checkInterval = _checkInterval;
- (void)setCheckInterval:(NSTimeInterval)checkInterval {
    dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
        if ( checkInterval != self->_checkInterval ) {
            self->_checkInterval = checkInterval;
        }
    });
}

- (NSTimeInterval)checkInterval {
    __block NSUInteger checkInterval = 0;
    dispatch_sync(dispatch_get_global_queue(0, 0), ^{
        checkInterval = self->_checkInterval;
    });
    return checkInterval;
}

#pragma mark -

- (__kindof id<MCSAsset> )assetWithURL:(NSURL *)URL {
    __block id<MCSAsset> asset = nil;
    dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
        MCSAssetType type = [MCSURLRecognizer.shared assetTypeForURL:URL];
        NSString *name = [MCSURLRecognizer.shared assetNameForURL:URL];
        if ( _assets[name] == nil ) {
            Class cls = [self _assetClassForType:type];
            // query
            id<MCSAsset> r = (id)[_sqlite3 objectsForClass:cls conditions:@[
                [SJSQLite3Condition conditionWithColumn:@"name" value:name]
            ] orderBy:nil error:NULL].firstObject;
            
            // create
            if ( r == nil ) {
                r = [cls.alloc initWithName:name];
                [self _syncAssetToDatabase:r]; // save asset
                _count += 1;
            }
            
            MCSAssetUsageLog *log = _usageLogs[name];
            if ( log == nil ) {
                log = (id)[_sqlite3 objectsForClass:MCSAssetUsageLog.class conditions:@[[SJSQLite3Condition conditionWithColumn:@"asset" value:@(r.id)]] orderBy:nil error:NULL].firstObject;
                
                if ( log == nil ) {
                    log = [MCSAssetUsageLog.alloc initWithAsset:r];
                    [self _syncUsageLogToDatabase:log]; // save log
                }
                
                _usageLogs[name] = log;
            }
            
            // contents
            [r prepare];
            [self _registerAsObserverForAsset:r];
            _assets[name] = r;
        }
        asset  = _assets[name];
    });
    return asset;
}
 
- (id<MCSAssetReader>)readerWithRequest:(NSURLRequest *)request {
    id<MCSAsset> asset = [self assetWithURL:request.URL];
    id<MCSAssetReader> reader = [asset readerWithRequest:request];
    reader.readDataDecoder = _readDataDecoder;
    return reader;
}

- (void)removeAllAssets {
    dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
        [_assets removeAllObjects];
        [_usageLogs removeAllObjects];
        NSArray<FILEAsset *> *FILEAssets = [_sqlite3 objectsForClass:FILEAsset.class conditions:nil orderBy:nil error:NULL];
        [self _removeAssets:FILEAssets];
        NSArray<HLSAsset *> *HLSAssets = [_sqlite3 objectsForClass:HLSAsset.class conditions:nil orderBy:nil error:NULL];
        [self _removeAssets:HLSAssets];
    });
}

- (void)removeAssetForURL:(NSURL *)URL {
    if ( URL.absoluteString.length == 0 )
        return;
    dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
        MCSAssetType type = [MCSURLRecognizer.shared assetTypeForURL:URL];
        NSString *name = [MCSURLRecognizer.shared assetNameForURL:URL];
        Class cls = [self _assetClassForType:type];
        if ( cls == nil ) return;
        id<MCSAsset> asset = (id)[_sqlite3 objectsForClass:cls conditions:@[
            [SJSQLite3Condition conditionWithColumn:@"name" value:name]
        ] orderBy:nil error:NULL].firstObject;
        if ( asset != nil ) [self _removeAssets:@[asset]];
    });
}

- (NSUInteger)cachedSizeForAssets {
    return MCSRootDirectory.size;
}

#pragma mark - mark

- (void)_checkRecursively {
    if ( _checkInterval == 0 ) return;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_checkInterval * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        dispatch_barrier_async(dispatch_get_global_queue(0, 0), ^{
            [self _syncDiskSpace];
            [self _removeAssetsForLimit:MCSLimitFreeDiskSpace];
            [self _removeAssetsForLimit:MCSLimitCacheDiskSpace];
            [self _removeAssetsForLimit:MCSLimitExpires];
            [self _syncUsageLogsToDatabase];
        });
        
        [self _checkRecursively];
    });
}

- (void)_syncUsageLogsToDatabase {
    if ( _usageLogs.count != 0 ) {
        [_sqlite3 updateObjects:self->_usageLogs.allValues forKeys:@[@"usageCount", @"updatedTime"] error:NULL];
        [_usageLogs removeAllObjects];
    }
}

- (void)_syncDiskSpace {
    _freeSize = [NSFileManager.defaultManager mcs_freeDiskSpace];
    _cacheSize = [MCSRootDirectory size];
}

- (void)_syncAssetToDatabase:(id<MCSAsset>)asset {
    [_sqlite3 save:asset error:NULL];
}

- (void)_syncUsageLogToDatabase:(MCSAssetUsageLog *)log {
    [_sqlite3 save:log error:NULL];
}

#pragma mark - mark

- (void)_registerAsObserverForAsset:(id<MCSAsset>)asset {
    [(id)asset addObserver:self forKeyPath:kReadwriteCount options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew context:&kReadwriteCount];
}

- (void)_unregisterAsObserverForAssets:(NSArray<id<MCSAsset>> *)assets {
    for ( id<MCSAsset> asset in assets ) {
        [(id)asset removeObserver:self forKeyPath:kReadwriteCount context:&kReadwriteCount];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ( context == &kReadwriteCount ) {
        id oldValue = change[NSKeyValueChangeOldKey];
        id newValue = change[NSKeyValueChangeNewKey];
        NSInteger oldCount = [oldValue isKindOfClass:NSNumber.class] ? [oldValue integerValue] : 0;
        NSInteger newCount = [newValue isKindOfClass:NSNumber.class] ? [newValue integerValue] : 0;
        if      ( newCount > oldCount ) {
            id<MCSAsset> asset = object;
            dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
                MCSAssetUsageLog *log = _usageLogs[asset.name];
                log.usageCount += 1;
                log.updatedTime = NSDate.date.timeIntervalSince1970;
            });
        }
        else if ( oldCount == 0 ) {
            dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
                if ( _cacheCountLimit == 0 || _count < _cacheCountLimit )
                    return;
                [self _removeAssetsForLimit:MCSLimitCount];
            });
        }
    }
}

#pragma mark - mark

- (void)_assetMetadataDidLoadWithNote:(NSNotification *)note {
    dispatch_barrier_async(dispatch_get_global_queue(0, 0), ^{
        [self _syncAssetToDatabase:note.object];
    });
}

#pragma mark -

- (void)_removeAssetsForLimit:(MCSLimit)limit {
    switch ( limit ) {
        case MCSLimitNone:
            break;
        case MCSLimitCount: {
            if ( _cacheCountLimit == 0 )
                return;
            
            if ( _count == 1 )
                return;
            
            // 资源数量少于限制的个数
            if ( _cacheCountLimit > _count )
                return;
        }
            break;
        case MCSLimitFreeDiskSpace: {
            if ( _reservedFreeDiskSpace == 0 )
                return;
            
            if ( _freeSize > _reservedFreeDiskSpace )
                return;
        }
            break;
        case MCSLimitExpires: {
            if ( _maxDiskAgeForCache == 0 )
                return;
        }
            break;
        case MCSLimitCacheDiskSpace: {
            if ( _maxDiskSizeForCache == 0 )
                return;
            
            // 获取已缓存的数据大小
            if ( _maxDiskSizeForCache > _cacheSize )
                return;
        }
            break;
    }
    
    NSMutableArray<NSNumber *> *usingAssets = NSMutableArray.alloc.init;
    [_assets enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, id<MCSAsset>  _Nonnull obj, BOOL * _Nonnull stop) {
        if ( obj.readwriteCount > 0 )
            [usingAssets addObject:@(obj.id)];
    }];

    // 全部处于使用中
    if ( usingAssets.count == _count )
        return;

    NSArray<MCSAssetUsageLog *> *logs = nil;
    switch ( limit ) {
        case MCSLimitNone:
            break;
        case MCSLimitCount:
        case MCSLimitCacheDiskSpace:
        case MCSLimitFreeDiskSpace: {
            // 清理60s之前的
            NSTimeInterval before = NSDate.date.timeIntervalSince1970 - 60;
            // 清理一半
            NSInteger length = (NSInteger)ceil((_count - usingAssets.count) * 0.5);
            logs = [_sqlite3 objectsForClass:MCSAssetUsageLog.class conditions:@[
                // 检索60s之前未被使用的资源
                [SJSQLite3Condition conditionWithColumn:@"asset" notIn:usingAssets],
                [SJSQLite3Condition conditionWithColumn:@"updatedTime" relatedBy:SJSQLite3RelationLessThanOrEqual value:@(before)],
            ] orderBy:@[
                // 按照更新的时间与使用次数进行排序
                [SJSQLite3ColumnOrder orderWithColumn:@"updatedTime" ascending:YES],
                [SJSQLite3ColumnOrder orderWithColumn:@"usageCount" ascending:YES],
            ] range:NSMakeRange(0, length) error:NULL];
        }
            break;
        case MCSLimitExpires: {
            NSTimeInterval time = NSDate.date.timeIntervalSince1970 - _maxDiskAgeForCache;
            logs = [_sqlite3 objectsForClass:MCSAssetUsageLog.class conditions:@[
                [SJSQLite3Condition conditionWithColumn:@"asset" notIn:usingAssets],
                [SJSQLite3Condition conditionWithColumn:@"updatedTime" relatedBy:SJSQLite3RelationLessThanOrEqual value:@(time)],
            ] orderBy:nil error:NULL];
        }
            break;
    }

    if ( logs.count == 0 )
        return;

    // 删除
    NSMutableArray<id<MCSAsset> > *results = NSMutableArray.array;
    [logs enumerateObjectsUsingBlock:^(MCSAssetUsageLog * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        id<MCSAsset> asset = [self.sqlite3 objectForClass:[self _assetClassForType:obj.assetType] primaryKeyValue:@(obj.asset) error:NULL];
        if ( asset != nil ) [results addObject:asset];
    }];
    
    [self _removeAssets:results];
}

- (void)_removeAssets:(NSArray<id<MCSAsset> > *)assets {
    if ( assets.count == 0 )
        return;

    [assets enumerateObjectsUsingBlock:^(id<MCSAsset>  _Nonnull r, NSUInteger idx, BOOL * _Nonnull stop) {
        [NSNotificationCenter.defaultCenter postNotificationName:MCSAssetWillRemoveAssetNotification object:r];
        [NSFileManager.defaultManager removeItemAtPath:r.path error:NULL];
        [self.sqlite3 removeObjectForClass:r.class primaryKeyValue:@(r.id) error:NULL];
        [self.sqlite3 removeAllObjectsForClass:MCSAssetUsageLog.class conditions:@[
            [SJSQLite3Condition conditionWithColumn:@"asset" value:@(r.id)],
            [SJSQLite3Condition conditionWithColumn:@"assetType" value:@(r.type)],
        ] error:NULL];
        [self.assets removeObjectForKey:r.name];
        [self.usageLogs removeObjectForKey:r.name];
        [NSNotificationCenter.defaultCenter postNotificationName:MCSAssetDidRemoveAssetNotification object:r];
    }];
    
    _count -= assets.count;
}

- (Class)_assetClassForType:(MCSAssetType)type {
    return type == MCSAssetTypeFILE ? FILEAsset.class : HLSAsset.class;
}
@end