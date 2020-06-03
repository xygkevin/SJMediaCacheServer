//
//  SJResourceReader.m
//  SJMediaCacheServer_Example
//
//  Created by BlueDancer on 2020/6/3.
//  Copyright © 2020 changsanjiang@gmail.com. All rights reserved.
//

#import "SJResourceReader.h"

@interface SJResourceReader ()<NSLocking, SJResourceDataReaderDelegate>
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
@property (nonatomic) NSRange range;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, copy) NSArray<id<SJResourceDataReader>> *readers;
@property (nonatomic) BOOL isCalledPrepare;
@property (nonatomic) BOOL isClosed;

@property (nonatomic) NSInteger currentIndex;
@property (nonatomic, strong) id<SJResourceDataReader> currentReader;
@property (nonatomic) NSUInteger offset;
@end

@implementation SJResourceReader
- (instancetype)initWithRange:(NSRange)range readers:(NSArray<id<SJResourceDataReader>> *)readers {
    self = [super init];
    if ( self ) {
        _delegateQueue = dispatch_get_global_queue(0, 0);
        _semaphore = dispatch_semaphore_create(1);
        _range = range;
        _readers = readers.copy;
        _currentIndex = NSNotFound;
    }
    return self;
}

- (void)prepare {
    [self lock];
    @try {
        if ( self.isClosed || self.isCalledPrepare )
            return;
        
        self.isCalledPrepare = YES;
        [self prepareNextReader];
    } @catch (__unused NSException *exception) {
        
    } @finally {
        [self unlock];
    }
}

- (NSUInteger)contentLength {
    return self.range.length;
}
 
- (NSData *)readDataOfLength:(NSUInteger)length {
    [self lock];
    @try {
        if ( self.isClosed || self.currentIndex == NSNotFound )
            return nil;
        
        NSData *data = [self.currentReader readDataOfLength:length];
        self.offset += data.length;
        if ( self.currentReader.isDone )
            [self prepareNextReader];
        return data;
    } @catch (__unused NSException *exception) {
        
    } @finally {
        [self unlock];
    }
}

- (BOOL)isReadingEndOfData {
    [self lock];
    @try {
        return self.readers.lastObject.isDone;
    } @catch (__unused NSException *exception) {
        
    } @finally {
        [self unlock];
    }
}

- (void)close {
    [self lock];
    @try {
        if ( self.isClosed )
            return;
        
        self.isClosed = YES;
        for ( id<SJResourceDataReader> reader in self.readers ) {
            [reader close];
        }
    } @catch (__unused NSException *exception) {
        
    } @finally {
        [self unlock];
    }
}

#pragma mark -

- (void)prepareNextReader {
    [self.currentReader close];
    if ( self.currentIndex == NSNotFound )
        self.currentIndex = 0;
    else
        self.currentIndex += 1;
    [self.currentReader setDelegate:self delegateQueue:self.delegateQueue];
    [self.currentReader prepare];
}

- (nullable id<SJResourceDataReader>)currentReader {
    if ( self.currentIndex != NSNotFound && self.currentIndex < self.readers.count ) {
        return self.readers[_currentIndex];
    }
    return nil;
}

- (void)lock {
    dispatch_semaphore_wait(_semaphore, DISPATCH_TIME_FOREVER);
}

- (void)unlock {
    dispatch_semaphore_signal(_semaphore);
}

- (void)callbackWithBlock:(void(^)(void))block {
    dispatch_async(_delegateQueue, ^{
        if ( block ) block();
    });
}

- (void)readerPrepareDidFinish:(id<SJResourceDataReader>)reader {
    [self lock];
    @try {
        if ( self.currentIndex == 0 ) {
            [self callbackWithBlock:^{
                [self.delegate readerPrepareDidFinish:self];
            }];
        }
    } @catch (__unused NSException *exception) {
        
    } @finally {
        [self unlock];
    }
}

- (void)readerHasAvailableData:(id<SJResourceDataReader>)reader {
    [self callbackWithBlock:^{
        [self.delegate readerHasAvailableData:self];
    }];
}

- (void)reader:(id<SJResourceDataReader>)reader anErrorOccurred:(NSError *)error {
    [self callbackWithBlock:^{
        [self.delegate reader:self anErrorOccurred:error];
    }];
}
@end