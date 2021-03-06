//
//  DownLoader.m
//  IdiotAVPlayer
//
//  Created by 老板 on 2017/12/30.
//  Copyright © 2017年 mht. All rights reserved.
//
#import <AVFoundation/AVFoundation.h>

#import "IdiotDownLoader.h"
#import "IdiotFileManager.h"
#import "NSURL+IdiotURL.h"
#import "IdiotResource.h"

static NSString * IdiotBackgroundTaskId = @"IdiotBackgroundTaskId";
static NSString * Content_Range = @"Content-Range";

@interface IdiotDownLoader () <NSURLSessionDelegate>

@property(nonatomic , strong) NSURLSession * session;
@property(nonatomic , strong) NSOperationQueue * queue;
@property(nonatomic , strong) NSMutableDictionary * taskDic;
@property(nonatomic , strong) NSMutableArray * resources;
@property(nonatomic ,   weak) NSURLSessionDataTask * currentDataTask;
@property(nonatomic ,   weak) IdiotResource * currentResource;
@property(nonatomic ,   weak) IdiotResource * currentTask;
@property(   atomic , assign) BOOL writing;

@end

@implementation IdiotDownLoader

#pragma mark -
+ (IdiotDownLoader *)share
{
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init{
    self = [super init];
    if (!self) { return nil; }
    [self session];
    self.taskDic = [[NSMutableDictionary alloc] init];
    self.writing = NO;
    return self;
}

- (void)start:(IdiotResource *)task {
    
    if (self.currentDataTask) {
        [self.currentDataTask cancel];
    }
    
    [self.taskDic setObject:task forKey:[NSString stringWithFormat:@"%zd",task.requestOffset]];
    
    //获取本地资源
    BOOL refresh = NO;
    while (!self.writing&&!refresh) {
        self.resources = [IdiotFileManager getResourceWithUrl:task.requestURL];
        refresh = YES;
    }
    
    IdiotResource * resource = nil;//找出对应的资源
    
    if (!self.resources.count) {//本地无资源
        resource = [[IdiotResource alloc] init];
        resource.requestURL = task.requestURL;
        resource.requestOffset = task.requestOffset;
        resource.fileLength = task.fileLength;
        resource.cachePath = task.cachePath;
        resource.cacheLength = 0;
        resource.resourceType = IdiotResourceTypeNet;//网络资源
        [self.resources addObject:resource];
    }else{//本地有资源
        
        for (IdiotResource * obj in self.resources) {
            if (task.requestOffset >= obj.requestOffset&&
                task.requestOffset < obj.requestOffset+obj.cacheLength) {
                resource = obj;
                break;
            }
        }
        
        if (task.requestOffset > resource.requestOffset&&
            resource.resourceType == IdiotResourceTypeNet) {
            
            long long adjustCacheLength = task.requestOffset - resource.requestOffset;
            
            IdiotResource * net = [[IdiotResource alloc] init];
            net.requestURL = task.requestURL;
            net.requestOffset = task.requestOffset;
            net.fileLength = task.fileLength;
            net.cachePath = task.cachePath;
            net.cacheLength = resource.cacheLength - adjustCacheLength;
            net.resourceType = IdiotResourceTypeNet;//网络资源
            
            resource.cacheLength = adjustCacheLength;
            
            NSInteger index = [self.resources indexOfObject:resource]+1;
            
            [self.resources insertObject:net atIndex:index];
            
            resource = net;
        }
        
    }
    
    self.currentResource = resource;
    
    [self fetchDataWith:task Resource:self.currentResource];
    
}

- (void)cancel{
    if (self.currentDataTask) {
        [self.currentDataTask cancel];
    }
}

- (void)resume{
    if (!self.currentTask) {
        return;
    }
    
    if (self.currentTask.requestOffset+self.currentTask.cacheLength < self.currentResource.requestOffset+self.currentResource.cacheLength) {
        [self fetchFromNetwork:self.currentTask withResource:self.currentResource];
    }else{
        [self willNextResource:self.currentTask];
    }
    
}


#pragma mark -
- (NSURLSession *)session{
    if (!_session) {//创建支持后台的NSURLSession
        NSURLSessionConfiguration * configure = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:IdiotBackgroundTaskId];
        _session = [NSURLSession sessionWithConfiguration:configure delegate:self delegateQueue:self.queue];
    }
    return _session;
}

- (NSOperationQueue *)queue{
    if (_queue) {
        _queue = [[NSOperationQueue alloc] init];
        _queue.maxConcurrentOperationCount = 1;
    }
    return _queue;
}

#pragma mark - 获取资源
- (void)fetchDataWith:(IdiotResource *)sliceRequest Resource:(IdiotResource *)resource {
    switch (resource.resourceType) {
            case IdiotResourceTypeNet:
        {
            [self fetchFromNetwork:sliceRequest withResource:resource];
        } break;
            
            case IdiotResourceTypeLocal:
        {
            [self fetchFromLocal:sliceRequest withResource:resource];
        } break;
            
        default:
            break;
    }
}

- (void)fetchFromNetwork:(IdiotResource *)task withResource:(IdiotResource *)resource{
    
    NSMutableURLRequest * request = [NSMutableURLRequest requestWithURL:[resource.requestURL originalSchemeURL] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10];
    if (resource.cacheLength > 0) {
        [request addValue:[NSString stringWithFormat:@"bytes=%lld-%lld", MAX(resource.requestOffset, task.requestOffset + task.cacheLength), resource.requestOffset+resource.cacheLength-1] forHTTPHeaderField:@"Range"];
    }else{
        [request addValue:[NSString stringWithFormat:@"bytes=%lld-", resource.requestOffset] forHTTPHeaderField:@"Range"];
    }
    NSURLSessionDataTask * datatask = [self.session dataTaskWithRequest:request];
    datatask.taskDescription = [NSString stringWithFormat:@"%lld",task.requestOffset];
    [datatask resume];
    
    self.currentDataTask = datatask;
}

- (void)fetchFromLocal:(IdiotResource *)sliceRequest withResource:(IdiotResource *)resource{
    
    if (sliceRequest.requestOffset == resource.requestOffset) {
        
        sliceRequest.cachePath = resource.cachePath;
        sliceRequest.fileLength = resource.fileLength;
        sliceRequest.cacheLength = resource.cacheLength;
        
        //直接开始下一个资源获取
        if (self.delegate && [self.delegate respondsToSelector:@selector(didReceiveData:)]) {
            [self.delegate didReceiveData:self];
        }
        
        [self willNextResource:sliceRequest];
        
        return;
    }
    
    NSFileHandle * readHandle = [IdiotFileManager fileHandleForReadingAtPath:resource.cachePath];
    
    unsigned long long seekOffset = sliceRequest.requestOffset < resource.requestOffset?0:sliceRequest.requestOffset-resource.requestOffset;
    
    [readHandle seekToFileOffset:seekOffset];
    
    //文件过大可分次读取
    long long canReadLength = resource.cacheLength-seekOffset;
    NSUInteger bufferLength = 5242880; //长度大于5M分次返回数据
    
    while (canReadLength >= bufferLength) {//长度大于1M分次返回数据
        
        canReadLength -= bufferLength;
        
        NSData * responseData = [readHandle readDataOfLength:bufferLength];
        
        [self didReceiveLocalData:responseData requestTask:sliceRequest complete:canReadLength==0?YES:NO];
        
    }
    
    if (canReadLength != 0) {
        NSData * responseData = [readHandle readDataOfLength:[[NSNumber numberWithLongLong:canReadLength] unsignedIntegerValue]];
        [readHandle closeFile];
        
        [self didReceiveLocalData:responseData requestTask:sliceRequest complete:YES];
    }else{
        [readHandle closeFile];
    }
    
}

- (void)didReceiveLocalData:(NSData *)data requestTask:(IdiotResource *)task complete:(BOOL)complete {
    
    if (task.cancel) return;
    
    self.writing = YES;
    
    if (!task.cachePath.length && !task.cachePath) {
        task.cachePath = [IdiotFileManager createSliceWithUrl:task.requestURL sliceName:[NSString stringWithFormat:@"%zd-%zd",task.requestOffset,task.fileLength]];
    }
    
    NSFileHandle * handle = [IdiotFileManager fileHandleForWritingAtPath:task.cachePath];
    [handle seekToEndOfFile];
    [handle writeData:data];
    
    [handle synchronizeFile];
    [handle closeFile];
    
    task.cacheLength += data.length;
    if (self.delegate && [self.delegate respondsToSelector:@selector(didReceiveData:)]) {
        [self.delegate didReceiveData:self];
    }
    self.writing = NO;
    if (complete) {//开始下一个资源获取
        [self willNextResource:task];
    }
    
}

- (void)willNextResource:(IdiotResource *)task {
    
    if (!self.resources.count||!_currentResource) {
        return;
    }
    
    NSInteger index = [self.resources indexOfObject:_currentResource];
    
    if (index >= self.resources.count - 1) {
        return;
    }
    
    IdiotResource * resource = [self.resources objectAtIndex:++index];
    
    self.currentResource = resource;
    
    [self fetchDataWith:task Resource:self.currentResource];
    
}

#pragma mark - NSURLSessionDataDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    
    IdiotResource * task = [self.taskDic objectForKey:dataTask.taskDescription];
    
    if (task.cancel) return;
    
    if (task.fileLength <= 0) {
        NSHTTPURLResponse * httpResponse = (NSHTTPURLResponse *)response;
        NSString * contentRange = [[httpResponse allHeaderFields] objectForKey:@"Content-Range"];
        NSString * fileLength = [[contentRange componentsSeparatedByString:@"/"] lastObject];
        task.fileLength = fileLength.integerValue > 0 ? fileLength.integerValue : response.expectedContentLength;
    }
    
    if (self.currentResource.fileLength <= 0) {
        self.currentResource.fileLength = task.fileLength;
    }
    
    if (!task.cachePath.length) {
        task.cachePath = [IdiotFileManager createSliceWithUrl:task.requestURL sliceName:[NSString stringWithFormat:@"%lld-%lld",task.requestOffset,task.fileLength]];
    }
    
    if (self.currentResource.cacheLength <= 0) {
        self.currentResource.cacheLength = task.fileLength - task.requestOffset;
    }
    
    completionHandler(NSURLSessionResponseAllow);
}

//服务器返回数据 可能会调用多次
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    
    IdiotResource * task = [self.taskDic objectForKey:dataTask.taskDescription];
    
    if (task.cancel) return;
    
    self.writing = YES;
    NSFileHandle * handle = [IdiotFileManager fileHandleForWritingAtPath:task.cachePath];
    [handle seekToEndOfFile];
    [handle writeData:data];
    
    [handle synchronizeFile];
    [handle closeFile];
    self.writing = NO;
    
    task.cacheLength += data.length;
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(didReceiveData:)]) {
        [self.delegate didReceiveData:self];
        DLogInfo(@"接受到数据");
    }
}

//请求完成会调用该方法，请求失败则error有值
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    
    IdiotResource * datatask = [self.taskDic objectForKey:task.taskDescription];
    
    if (datatask.cancel) {
        DLogDebug(@"下载取消");
    }else {
        
        if (!error) {
            
            DLogDebug(@"开始下一个资源获取");
            [self willNextResource:datatask];
            
        }else{
            DLogError(@"%@",error);
            
            if (error.code == -997) {//Lost connection to background transfer service
                self.currentTask = datatask;
            }
            
        }
        
    }
    
    DLogDebug(@"didCompleteWithError");
}

//最终处理
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    
    if (self.backgroundSessionCompletionHandler) {
        __weak typeof(self) weakself = self;
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            __strong typeof(weakself) strongself = weakself;
            strongself.backgroundSessionCompletionHandler();
        }];
    }
    
}
@end
