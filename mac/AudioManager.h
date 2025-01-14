#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

typedef NS_ENUM(NSInteger, PermissionStatus) {
    PermissionStatusNotDetermined,
    PermissionStatusDenied,
    PermissionStatusAuthorized,
    PermissionStatusRestricted
};

typedef NS_ENUM(NSInteger, DeviceType) {
    DeviceTypeMicrophone,
    DeviceTypeAudio
};

// TCC function types
typedef int (*TCCPreflightFuncType)(CFStringRef service, CFDictionaryRef options);
typedef void (*TCCRequestFuncType)(CFStringRef service, CFDictionaryRef options, void (^completionHandler)(BOOL granted));

@interface AudioManager : NSObject {
    void *_tccHandle;
    TCCPreflightFuncType _preflightFunc;
    TCCRequestFuncType _requestFunc;
    
    // Audio properties
    AudioDeviceID _aggregateDeviceID;
    AudioDeviceIOProcID _deviceProcID;
    AudioStreamBasicDescription _targetFormat;
    AudioStreamBasicDescription _sourceFormat;
    AudioObjectPropertyListenerBlock _deviceChangeListener;
    
    // State
    BOOL _isCapturing;
    BOOL _isSetup;
    
    // Queue for audio operations
    dispatch_queue_t _audioQueue;
    
    // Callback for audio data
    void (^_audioDataCallback)(NSData *audioData);
    
    // Tap properties
    NSUUID* _tapUID;
    AudioObjectID _tapObjectID;
}

// Singleton accessor
+ (instancetype)sharedInstance;

// Audio control methods
- (BOOL)startCapture:(NSError **)error;
- (BOOL)stopCapture:(NSError **)error;
- (void)setAudioDataCallback:(void (^)(NSData *audioData))callback;

// Permission methods
- (NSDictionary *)getPermissions;
- (void)requestPermissionsForDevice:(DeviceType)deviceType completion:(void (^)(NSDictionary *))completion;

// Private methods
- (void)initializeTCCFramework;
- (int)checkTCCPermission:(NSString *)service;
- (void)requestTCCPermission:(NSString *)service completion:(void (^)(BOOL granted))completion;

// Audio setup methods
- (BOOL)setupAudioTapIfNeeded:(NSError **)error;
- (BOOL)setupAggregateDeviceIfNeeded:(NSError **)error;
- (void)destroyAudioResources;
- (void)startDeviceMonitoring;
- (void)stopDeviceMonitoring;
- (void)handleDeviceChange;

@end