//
//  EduClassroomManager.m
//  Demo
//
//  Created by SRS on 2020/6/17.
//  Copyright © 2020 agora. All rights reserved.
//

#import "EduClassroomManager.h"
#import "HttpManager.h"
#import "RTCManager.h"
#import "RTMManager.h"
#import "EduStream.h"
#import "EduConstants.h"
#import "EduMessageHandle.h"

#import "EduUser+ConvenientInit.h"
#import "EduClassroom+ConvenientInit.h"

#import "JoinRoomModel.h"
#import "RoomModel.h"
#import "CommonModel.h"

#import "EduLogManager.h"

#import "EduChannelMessageHandle.h"

#import "EduSyncUserModel.h"
#import "EduSyncStreamModel.h"
#import "EduSyncRoomModel.h"

#import "SyncIncreaseModel.h"

#import "AgoraLogManager+Quick.h"
#import "EduKVCClassroomConfig.h"
#import "EduKVCUserConfig.h"

#define NOTICE_KEY_ROOM_DESTORY @"NOTICE_KEY_ROOM_DESTORY"

typedef void (^OnJoinRoomSuccessBlock)(EduUserService *userService);

@interface EduClassroomManager()<RTMChannelDelegate, RTCManagerDelegate>

@property (nonatomic, strong) NSString *appId;
@property (nonatomic, strong) NSString *roomUuid;
@property (nonatomic, strong) NSString *defaultUserName;
@property (nonatomic, strong) NSString *userToken;
@property (nonatomic, strong) NSString *logDirectoryPath;
@property (nonatomic, assign) EduSceneType sceneType;
@property (nonatomic, strong) EduClassroomMediaOptions *mediaOption;

@property (nonatomic, strong) EduUserService *userService;

@property (nonatomic, strong) EduChannelMessageHandle *messageHandle;
@property (nonatomic, strong) SyncRoomSession *syncRoomSession;

@property (nonatomic, copy) EduSuccessBlock joinRTCSuccessBlock;

// state
@property (nonatomic, assign) BOOL increaseSyncing;

@end

@implementation EduClassroomManager
- (instancetype)initWithConfig:(EduKVCClassroomConfig *)config {
    
    if (self = [super init]) {
        self.increaseSyncing = NO;
        
        HttpManagerConfig *httpConfig = [HttpManager getHttpManagerConfig];
        self.appId = httpConfig.appid;
        self.roomUuid = config.roomUuid;
        self.defaultUserName = config.dafaultUserName;
        self.logDirectoryPath = httpConfig.logDirectoryPath;
        self.sceneType = config.sceneType;
        
        self.syncRoomSession = [[SyncRoomSession alloc] initWithUserUuid:httpConfig.userUuid roomClass:EduSyncRoomModel.class useClass:EduSyncUserModel.class streamClass:EduSyncStreamModel.class];
        WEAK(self);
        self.syncRoomSession.fetchMessageList = ^(NSInteger nextId, NSInteger count) {
            [weakself syncIncreaseWithStartIndex:nextId count:count success:nil];
        };
        self.messageHandle = [[EduChannelMessageHandle alloc] initWithSyncSession:self.syncRoomSession];
        self.messageHandle.roomUuid = self.roomUuid;
        
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onReconnecting) name:NOTICE_KEY_START_RECONNECT object:nil];
    }

    return self;
}

- (void)onReconnecting {
    NSInteger nextId = self.syncRoomSession.currentMaxSeq + 1;
    [self syncIncreaseWithStartIndex:nextId count:0 success:^{
        [NSNotificationCenter.defaultCenter postNotificationName:NOTICE_KEY_END_RECONNECT object:nil];
    }];
}

- (void)joinClassroom:(EduClassroomJoinOptions*)options success:(OnJoinRoomSuccessBlock)successBlock failure:(EduFailureBlock _Nullable)failureBlock {
    
    NSString *userName = self.defaultUserName;
    if (options.userName != nil) {
        userName = options.userName;
    }

    NSAssert(NoNullString(userName).length > 0, @"userName must not null");
    
    self.mediaOption = options.mediaOption;

    WEAK(self);
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"userName"] = NoNullString(userName);
    if (options.role == EduRoleTypeTeacher) {
        params[@"role"] = kServiceRoleHost;
        
    } else if(options.role == EduRoleTypeAssistant){
        params[@"role"] = kServiceRoleAudience;
        
    } else if(options.role == EduRoleTypeStudent) {
        if(self.sceneType == EduSceneTypeBig
           || self.sceneType == EduSceneTypeBreakout) {
            params[@"role"] = kServiceRoleAudience;
        } else {
            params[@"role"] = kServiceRoleBroadcaster;
        }
    }
    params[@"streamUuid"] = @(options.mediaOption.primaryStreamId);
    if (options.mediaOption.autoPublish){
        params[@"publishType"] = @(1);
    }

    // entry-》初始化RTM&RTC => sync => auto
    [HttpManager joinRoomWithRoomUuid:self.roomUuid param:params apiVersion:APIVersion1 analysisClass:JoinRoomModel.class success:^(id<BaseModel> objModel) {
        
        JoinRoomInfoModel *model = ((JoinRoomModel*)objModel).data;
        weakself.userToken = model.user.userToken;

        EduUserService *userService;
        SEL action = NSSelectorFromString(@"initWithConfig:");
 
        EduKVCUserConfig *kvcConfig = [EduKVCUserConfig new];
        kvcConfig.roomUuid = weakself.roomUuid;
        kvcConfig.messageHandle = weakself.messageHandle;
        kvcConfig.mediaOption = options.mediaOption;
        kvcConfig.userToken = model.user.userToken;
        
        if (options.role == EduRoleTypeTeacher) {
            userService = [EduTeacherService alloc];
        } else if (options.role == EduRoleTypeStudent) {
            userService = [EduStudentService alloc];
        } else if (options.role == EduRoleTypeAssistant) {
            userService = [EduAssistantService alloc];
        }
        if ([userService respondsToSelector:action]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [userService performSelector:action withObject:kvcConfig];
#pragma clang diagnostic pop
        }

        // local
        id userObj = [model.user yy_modelToJSONObject];
        weakself.syncRoomSession.localUser = [EduSyncUserModel new];
        [weakself.syncRoomSession.localUser yy_modelSetWithJSON:userObj];
        weakself.syncRoomSession.localUser.state = 1;
        [AgoraLogManager logMessageWithDescribe:@"classroom:" message:@{@"roomUuid":NoNullString(weakself.roomUuid), @"localuser":weakself.syncRoomSession.localUser}];
        
        // media
        weakself.userService = userService;
        [weakself initMediaDispatchGroup:model success:^{
            
            [AgoraLogManager logMessageWithDescribe:@"classroom initMedia success:" message:@{@"roomUuid":NoNullString( weakself.roomUuid)}];
            
            [weakself syncTotalSuccess:^{
                
                [AgoraLogManager logMessageWithDescribe:@"classroom initMedia success:" message:@{@"roomUuid":NoNullString(weakself.roomUuid), @"users":weakself.syncRoomSession.users, @"streams":weakself.syncRoomSession.streams}];
                
               // auto
                [weakself setupPublishOptionsSuccess:^{

                    if(successBlock){
                        successBlock(userService);
                    }
                } failure:^(NSError * error) {
                    [weakself releaseResource];
                    NSString *errMsg = error.description;
                    NSError *eduError = LocalError(EduErrorTypeInternalError, errMsg);
                    if(failureBlock != nil) {
                        failureBlock(eduError);
                    }
                }];
            }];
        } failure:^(NSError * error) {
            [weakself releaseResource];
            if(failureBlock){
                failureBlock(error);
            }
        }];
        
    } failure:^(NSError * error, NSInteger statusCode) {
        NSString *errMsg = error.description;
        NSError *eduError = LocalError(EduErrorTypeNetworkError, errMsg);
        if(failureBlock != nil) {
            failureBlock(eduError);
        }
    }];
}

- (void)getLocalUserWithSuccess:(OnGetLocalUserSuccessBlock)successBlock failure:(EduFailureBlock)failureBlock {
        
    if (self.syncRoomSession.localUser != nil) {
        if (successBlock) {
            EduLocalUser *localUser = [self.syncRoomSession.localUser mapEduLocalUser];
            successBlock(localUser);
        }
    } else {
        
        NSString *errMsg = @"not yet in the classroom";
        NSError *error = LocalError(EduErrorTypeInternalError, errMsg);
        [AgoraLogManager logErrMessageWithDescribe:@"classroom getLocalUser error:" message:@{@"roomUuid":NoNullString(self.roomUuid), @"errMsg":errMsg}];
        
        if (failureBlock) {
            if(failureBlock != nil) {
                failureBlock(error);
            }
        }
    }
}

- (void)getClassroomInfoWithSuccess:(OnGetClassroomInfoSuccessBlock)successBlock failure:(EduFailureBlock)failureBlock {
    
    if (self.syncRoomSession.room != nil) {
        if (successBlock) {
            NSInteger count = self.syncRoomSession.users.count;
            EduClassroom *classroom = [self.syncRoomSession.room mapEduClassroom:count];
            successBlock(classroom);
        }
    } else {
        
        NSString *errMsg = @"not yet in the classroom";
        NSError *error = LocalError(EduErrorTypeInternalError, errMsg);
        [AgoraLogManager logErrMessageWithDescribe:@"classroom getClassroomInfo error:" message:@{@"roomUuid":NoNullString(self.roomUuid), @"errMsg":errMsg}];
        
        if (failureBlock) {
            if(failureBlock != nil) {
                failureBlock(error);
            }
        }
    }
}

- (void)getUserCountWithRole:(EduRoleType)role success:(OnGetUserCountSuccessBlock)successBlock failure:(EduFailureBlock _Nullable)failureBlock {
 
    [self.syncRoomSession getUsersInQueue:^(NSArray<EduSyncUserModel *> *users) {
        
        NSInteger count = 0;
        for (EduSyncUserModel *user in users) {
            if([user mapEduUser].role == role) {
                count++;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (successBlock) {
                successBlock(count);
            }
        });
    }];
}

- (void)getUserListWithRole:(EduRoleType)role from:(NSUInteger)fromIndex to:(NSUInteger)endIndex success:(OnGetUserListSuccessBlock)successBlock failure:(EduFailureBlock _Nullable)failureBlock {

    if(fromIndex > endIndex) {
        NSString *errMsg = @"endIndex must big then fromIndex";
        NSError *error = LocalError(EduErrorTypeInvalidRange, errMsg);
        [AgoraLogManager logErrMessageWithDescribe:@"classroom getUserList error:" message:@{@"roomUuid":NoNullString(self.roomUuid), @"errMsg":errMsg}];
        
        if(failureBlock != nil) {
            failureBlock(error);
        }
        return;
    }
    
    
    [self.syncRoomSession getUsersInQueue:^(NSArray<EduSyncUserModel *> *users) {
        
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:users.count];
        for (EduSyncUserModel *user in users) {
            EduUser *userModel = [user mapEduUser];
            if (userModel.role == role) {
                [array addObject:userModel];
            }
        }
        
        if(endIndex > array.count){
            NSString *errMsg = @"endIndex outsize the total number of current users";
            NSError *error = LocalError(EduErrorTypeInvalidRange, errMsg);
            [AgoraLogManager logErrMessageWithDescribe:@"classroom getUserList error:" message:@{@"roomUuid":NoNullString(self.roomUuid), @"role":@(role), @"fromIndex":@(fromIndex), @"toIndex":@(endIndex), @"errMsg":errMsg}];
    
            dispatch_async(dispatch_get_main_queue(), ^{
                if(failureBlock != nil) {
                    failureBlock(error);
                }
            });
            
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if(successBlock) {
                 NSRange range = NSMakeRange(fromIndex, endIndex - fromIndex);
                 successBlock([array subarrayWithRange:range]);
             }
        });
    }];
}

- (void)getFullUserListWithSuccess:(OnGetUserListSuccessBlock)successBlock failure:(EduFailureBlock)failureBlock {
    
    [self.syncRoomSession getUsersInQueue:^(NSArray<EduSyncUserModel *> *users) {
        
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:users.count];
        for (EduSyncUserModel *user in users) {
            EduUser *userModel = [user mapEduUser];
            [array addObject:userModel];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (successBlock) {
                successBlock(array);
            }
        });
    }];
}

- (void)getFullStreamListWithSuccess:(OnGetStreamListSuccessBlock)successBlock failure:(EduFailureBlock)failureBlock {
    
    [self.syncRoomSession getStreamsInQueue:^(NSArray<EduSyncStreamModel *> *streams) {
       
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:streams.count];
        for (EduSyncStreamModel *stream in streams) {
            EduStream *streamModel = [stream mapEduStream];
            [array addObject:streamModel];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (successBlock) {
                successBlock(array);
            }
        });
        
    }];
}

- (void)leaveClassroomWithSuccess:(EduSuccessBlock)successBlock failure:(EduFailureBlock)failureBlock {
    
    [self releaseResource];
    if (successBlock) {
        successBlock();
    }
}

- (void)destory {
    [self releaseResource];
}

#pragma mark Private
- (void)setupPublishOptionsSuccess:(EduSuccessBlock)successBlock failure:(EduFailureBlock)failureBlock {
    
    if (self.mediaOption.autoPublish) {
        EduSyncUserModel *userModel = self.syncRoomSession.localUser;
        EduStreamConfig *config = [[EduStreamConfig alloc] initWithStreamUuid:userModel.streamUuid];

        [self.userService startOrUpdateLocalStream:config success:^(EduStream * _Nonnull stream) {
            if(successBlock) {
                successBlock();
            }
            
        } failure:failureBlock];
    } else if(successBlock) {
        successBlock();
    }
}

#pragma mark Private
- (void)setDelegate:(id<EduClassroomDelegate>)delegate {
    _delegate = delegate;
    self.messageHandle.roomDelegate = delegate;
}

- (void)syncTotalSuccess:(EduSuccessBlock)successBlock {
    
    WEAK(self);
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    [HttpManager syncTotalWithRoomUuid:self.roomUuid userToken:self.userToken param:params apiVersion:APIVersion1 analysisClass:CommonModel.class success:^(id<BaseModel>  _Nonnull objModel) {
        CommonModel *model = objModel;
        [weakself.syncRoomSession syncSnapshot:NoNullDictionary(model.data) complete:^{
            successBlock();
        }];
    } failure:^(NSError * _Nullable error, NSInteger statusCode) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakself syncTotalSuccess:successBlock];
        });
    }];
}

- (void)syncIncreaseWithStartIndex:(NSInteger)nextId count:(NSInteger)count success:(EduSuccessBlock)block {

    if (self.increaseSyncing) {
        return;
    }
    
    self.increaseSyncing = YES;
    
    WEAK(self);
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"nextId"] = @(nextId);
    if(count > 0) {
        params[@"count"] = @(count);
    }
    [HttpManager syncIncreaseWithRoomUuid:self.roomUuid userToken:self.userToken param:params apiVersion:APIVersion1 analysisClass:SyncIncreaseModel.class success:^(id<BaseModel>  _Nonnull objModel) {

        weakself.increaseSyncing = NO;
        if(block){
            block();
        }
        
        SyncIncreaseModel *model = objModel;
        for(id obj in NoNullArray(model.data.list)) {
            [weakself.messageHandle didReceivedChannelMsg:obj];
        }
    } failure:^(NSError * _Nullable error, NSInteger statusCode) {
        [weakself syncTotalSuccess:^{
            weakself.increaseSyncing = NO;
        }];
    }];
}

- (void)releaseResource {
    
    [AgoraLogManager logMessageWithDescribe:@"EduClassroomManager destory:" message:@{@"roomUuid": NoNullString(self.roomUuid)}];
    
    [NSNotificationCenter.defaultCenter postNotificationName:NOTICE_KEY_ROOM_DESTORY object:self.roomUuid];
    
    [self.userService destory];
    self.userService = nil;
    [RTCManager.shareManager destoryWithChannelId:self.roomUuid];
    [RTMManager.shareManager destoryWithChannelId:self.roomUuid];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)dealloc {
    [self releaseResource];
}

- (void)initMediaDispatchGroup:(JoinRoomInfoModel *)model success:(EduSuccessBlock)successBlock failure:(EduFailureBlock)failureBlock {
    
    dispatch_group_t group = dispatch_group_create();
    __block NSError *groupError;

    dispatch_group_enter(group);
    [self initRTCWithModel:model success:^{
        dispatch_group_leave(group);
    } failure:^(NSError * error) {
        groupError = error;
        dispatch_group_leave(group);
    }];

    dispatch_group_enter(group);
    [self initRTMWithModel:model success:^{
        dispatch_group_leave(group);
    } failure:^(NSError * error) {
        groupError = error;
        dispatch_group_leave(group);
    }];

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (groupError) {
            failureBlock(groupError);
        } else {
            successBlock();
        }
    });
}
- (void)initRTCWithModel:(JoinRoomInfoModel *)model success:(EduSuccessBlock)successBlock failure:(EduFailureBlock)failureBlock {
    
    if(successBlock != nil) {
        self.joinRTCSuccessBlock = successBlock;
    }
    
    [RTCManager.shareManager initEngineKitWithAppid:self.appId];
    [RTCManager.shareManager setLogFile:self.logDirectoryPath];
    
    [RTCManager.shareManager setChannelProfile:AgoraChannelProfileLiveBroadcasting];
    [self.userService setVideoConfig:[EduVideoConfig defaultVideoConfig]];
    
    if (self.mediaOption.autoPublish) {
        [RTCManager.shareManager setClientRole:AgoraClientRoleBroadcaster channelId:self.roomUuid];
    }
    
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *app_Version = [infoDictionary objectForKey:@"CFBundleShortVersionString"];
    NSDictionary *infoDic = [NSDictionary dictionary];
    NSInteger tag = HttpManager.getHttpManagerConfig.tag;
    switch (tag) {
        case EduSceneType1V1:
            infoDic = @{@"demo_scenario":@"One to One Classroom", @"demo_ver": app_Version};
            break;
        case EduSceneTypeSmall:
            infoDic = @{@"demo_scenario":@"Small Classroom", @"demo_ver": app_Version};
            break;
        case EduSceneTypeBig:
            infoDic = @{@"demo_scenario":@"Lecture Hall", @"demo_ver": app_Version};
            break;
        case EduSceneTypeBreakout:
            infoDic = @{@"demo_scenario":@"Breakout Classroom", @"demo_ver": app_Version};
            break;
        default:
            break;
    }
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:infoDic options:NSJSONWritingPrettyPrinted error:&error];
    NSString *info = @"";
    if (jsonData) {
        info = [[NSString alloc]initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    
    NSString *rtcToken = model.user.rtcToken;
    NSString *roomUuid = model.room.roomInfo.roomUuid;
    NSInteger uid = model.user.streamUuid.integerValue;
    int errorCode = [RTCManager.shareManager joinChannelByToken:rtcToken channelId:roomUuid info:info uid:uid autoSubscribeAudio:self.mediaOption.autoSubscribe autoSubscribeVideo:self.mediaOption.autoSubscribe];
    if (errorCode != 0) {
        if (failureBlock) {
            NSString *errMsg = [@"join rtc failed:" stringByAppendingString:@(errorCode).stringValue];
            failureBlock(LocalError(EduErrorTypeInternalError, errMsg));
        }
    } else {
        RTCChannelDelegateConfig *config = [RTCChannelDelegateConfig new];
        config.delegate = self;
        [RTCManager.shareManager setChannelDelegateWithConfig:config channelId:roomUuid];
    }
}
- (void)initRTMWithModel:(JoinRoomInfoModel *)model success:(EduSuccessBlock)successBlock failure:(EduFailureBlock)failureBlock {
    
    NSString *roomUuid = model.room.roomInfo.roomUuid;

    WEAK(self);
    [RTMManager.shareManager joinSignalWithChannelName:roomUuid completeSuccessBlock:^{
        RTMChannelDelegateConfig *config = [RTMChannelDelegateConfig new];
        config.channelDelegate = weakself;
        [RTMManager.shareManager setChannelDelegateWithConfig:config channelName:roomUuid];
        successBlock();
    } completeFailBlock:^(NSInteger errorCode) {
        NSString *errMsg = [@"join rtm error:" stringByAppendingString:@(errorCode).stringValue];
        failureBlock(LocalError(EduErrorTypeInternalError, errMsg));
    }];
    [RTMManager.shareManager setLogFile:self.logDirectoryPath];
}

#pragma mark RTMManagerDelegate
- (void)didReceivedSignal:(NSString *)signalText fromChannel: (AgoraRtmChannel *)channel {
    [self.messageHandle didReceivedChannelMsg:signalText];
}

#pragma mark RTCManagerDelegate
- (void)rtcChannelDidJoinChannel:(NSString *)channelId
                         withUid:(NSUInteger)uid {
    
    if([channelId isEqualToString:self.roomUuid]){
        if(self.joinRTCSuccessBlock != nil){
            self.joinRTCSuccessBlock();
        }
    }
    
}
- (void)rtcChannel:(NSString *)channelId networkQuality:(NSUInteger)uid txQuality:(AgoraNetworkQuality)txQuality rxQuality:(AgoraNetworkQuality)rxQuality {
    
    NetworkQuality grade = NetworkQualityUnknown;
     
    AgoraNetworkQuality quality = MAX(txQuality, rxQuality);
    switch (quality) {
        case AgoraNetworkQualityExcellent:
        case AgoraNetworkQualityGood:
            grade = NetworkQualityHigh;
            break;
        case AgoraNetworkQualityPoor:
        case AgoraNetworkQualityBad:
            grade = NetworkQualityMiddle;
            break;
        case AgoraNetworkQualityVBad:
        case AgoraNetworkQualityDown:
            grade = NetworkQualityLow;
            break;
        default:
            break;
    }
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"streamUuid = %@", @(uid).stringValue];
    NSArray<EduSyncStreamModel*> *predicateUsers = [self.syncRoomSession.streams filteredArrayUsingPredicate:predicate];
    if(predicateUsers.count > 0){
        if([self.delegate respondsToSelector:@selector(classroom:networkQualityChanged:user:)]) {
            EduSyncRoomModel *room = self.syncRoomSession.room;
            
            EduBaseUser *opr = [EduBaseUser new];
            id oprObj = [predicateUsers.firstObject.fromUser yy_modelToJSONObject];
            [opr yy_modelSetWithJSON:oprObj];

            [self.delegate classroom:[room mapEduClassroom:self.syncRoomSession.users.count] networkQualityChanged:grade user:opr];
        }
    }
}

@end

