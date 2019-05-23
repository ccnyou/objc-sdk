//
//  QNFormUpload.m
//  QiniuSDK
//
//  Created by bailong on 15/1/4.
//  Copyright (c) 2015年 Qiniu. All rights reserved.
//

#import "QNFormUpload.h"
#import "QNConfiguration.h"
#import "QNCrc32.h"
#import "QNRecorderDelegate.h"
#import "QNResponseInfo.h"
#import "QNUploadManager.h"
#import "QNUploadOption+Private.h"
#import "QNUrlSafeBase64.h"

@interface QNFormUpload ()
@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) id<QNHttpDelegate> httpManager;
@property (nonatomic) int retryTimes;
@property (nonatomic, strong) NSString *key;
@property (nonatomic, strong) QNUpToken *token;
@property (nonatomic, strong) QNUploadOption *option;
@property (nonatomic, strong) QNUpCompletionHandler complete;
@property (nonatomic, strong) QNConfiguration *config;
@property (nonatomic, strong) NSString *fileName;
@property (nonatomic) float previousPercent;
@property (nonatomic, strong) NSString *access; //AK
@end

@implementation QNFormUpload

- (instancetype)initWithData:(NSData *)data
                     withKey:(NSString *)key
                withFileName:(NSString *)fileName
                   withToken:(QNUpToken *)token
       withCompletionHandler:(QNUpCompletionHandler)block
                  withOption:(QNUploadOption *)option
             withHttpManager:(id<QNHttpDelegate>)http
           withConfiguration:(QNConfiguration *)config {
    if (self = [super init]) {
        self.data = data;
        self.key = key;
        self.token = token;
        self.option = option != nil ? option : [QNUploadOption defaultOptions];
        self.complete = block;
        self.httpManager = http;
        self.config = config;
        self.fileName = fileName != nil ? fileName : @"?";
        self.previousPercent = 0;
        self.access = token.access;
    }
    return self;
}

- (void)put {
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    if (self.key) {
        parameters[@"key"] = self.key;
    }
    parameters[@"token"] = self.token.token;
    [parameters addEntriesFromDictionary:self.option.params];
    parameters[@"crc32"] = [NSString stringWithFormat:@"%u", (unsigned int)[QNCrc32 data:self.data]];
    QNInternalProgressBlock p = ^(long long totalBytesWritten, long long totalBytesExpectedToWrite) {
        float percent = (float)totalBytesWritten / (float)totalBytesExpectedToWrite;
        if (percent > 0.95) {
            percent = 0.95;
        }
        if (percent > self.previousPercent) {
            self.previousPercent = percent;
        } else {
            percent = self.previousPercent;
        }
        self.option.progressHandler(self.key, percent);
    };
    __block NSString *upHost = [self.config.zone up:self.token isHttps:self.config.useHttps frozenDomain:nil];
    QNCompleteBlock complete = ^(QNResponseInfo *info, NSDictionary *resp) {
        if (info.isOK) {
            self.option.progressHandler(self.key, 1.0);
        }
        if (info.isOK || !info.couldRetry) {
            self.complete(info, self.key, resp);
            return;
        }
        if (self.option.cancellationSignal()) {
            self.complete([QNResponseInfo cancel], self.key, nil);
            return;
        }
        __block NSString *nextHost = upHost;
        if (info.isConnectionBroken || info.needSwitchServer) {
            nextHost = [self.config.zone up:self.token isHttps:self.config.useHttps frozenDomain:nextHost];
        }
        QNCompleteBlock retriedComplete = ^(QNResponseInfo *info, NSDictionary *resp) {
            if (info.isOK) {
                self.option.progressHandler(self.key, 1.0);
            }
            if (info.isOK || !info.couldRetry) {
                self.complete(info, self.key, resp);
                return;
            }
            if (self.option.cancellationSignal()) {
                self.complete([QNResponseInfo cancel], self.key, nil);
                return;
            }
            NSString *thirdHost = nextHost;
            if (info.isConnectionBroken || info.needSwitchServer) {
                thirdHost = [self.config.zone up:self.token isHttps:self.config.useHttps frozenDomain:nextHost];
            }
            QNCompleteBlock thirdComplete = ^(QNResponseInfo *info, NSDictionary *resp) {
                if (info.isOK) {
                    self.option.progressHandler(self.key, 1.0);
                }
                self.complete(info, self.key, resp);
            };
            [self.httpManager multipartPost:thirdHost
                               withData:self.data
                             withParams:parameters
                           withFileName:self.fileName
                           withMimeType:self.option.mimeType
                      withCompleteBlock:thirdComplete
                      withProgressBlock:p
                        withCancelBlock:self.option.cancellationSignal
                             withAccess:self.access];
        };
        [self.httpManager multipartPost:nextHost
                           withData:self.data
                         withParams:parameters
                       withFileName:self.fileName
                       withMimeType:self.option.mimeType
                  withCompleteBlock:retriedComplete
                  withProgressBlock:p
                    withCancelBlock:self.option.cancellationSignal
                         withAccess:self.access];
    };
    [self.httpManager multipartPost:upHost
                       withData:self.data
                     withParams:parameters
                   withFileName:self.fileName
                   withMimeType:self.option.mimeType
              withCompleteBlock:complete
              withProgressBlock:p
                withCancelBlock:self.option.cancellationSignal
                     withAccess:self.access];
}
@end
