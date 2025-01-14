#import "AudioManager.h"
#import "LogUtil.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CATapDescription.h>
#include <CoreAudio/AudioHardwareTapping.h>

// Constants for audio format
static const Float64 kTargetSampleRate = 22050.0;
static const UInt32 kTargetChannelCount = 1;
static const UInt32 kBitsPerChannel = 32;
static const UInt32 kPreferredBufferSize = 4096;  // Added preferred buffer size (samples)

// Constants for device monitoring
static const UInt32 kDeviceChangeScope = kAudioObjectPropertyScopeGlobal;
static const UInt32 kDeviceChangeElement = kAudioObjectPropertyElementMain;


@interface AudioManager () {
}
@end

@implementation AudioManager

#pragma mark - Singleton

static AudioManager *sharedInstance = nil;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Log("Creating singleton instance");
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    Log("Initializing");
    self = [super init];
    if (self) {
        Log("Initializing TCC framework");
        [self initializeTCCFramework];
        
        // Initialize audio properties
        _isCapturing = NO;
        _isSetup = NO;
        _audioQueue = dispatch_queue_create("audio-manager-queue", DISPATCH_QUEUE_SERIAL);
        _aggregateDeviceID = kAudioDeviceUnknown;
        _deviceProcID = NULL;
        
        // Set up target format
        _targetFormat.mSampleRate = kTargetSampleRate;
        _targetFormat.mFormatID = kAudioFormatLinearPCM;
        _targetFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        _targetFormat.mFramesPerPacket = 1;
        _targetFormat.mChannelsPerFrame = kTargetChannelCount;
        _targetFormat.mBitsPerChannel = kBitsPerChannel;
        _targetFormat.mBytesPerPacket = (_targetFormat.mBitsPerChannel / 8) * _targetFormat.mChannelsPerFrame;
        _targetFormat.mBytesPerFrame = _targetFormat.mBytesPerPacket;
        
        // Try to set up audio resources if we have permission
        if ([self checkTCCPermission:@"kTCCServiceAudioCapture"] == 0) {
            NSError *error = nil;
            if (![self setupAudioTapIfNeeded:&error]) {
                Log(std::string("Failed to setup audio tap: ") + std::string([error.localizedDescription UTF8String]), "error");
            }
            if (![self setupAggregateDeviceIfNeeded:&error]) {
                Log(std::string("Failed to setup aggregate device: ") + std::string([error.localizedDescription UTF8String]), "error");
            }
            [self startDeviceMonitoring];
        }
    }
    return self;
}

- (void)dealloc {
    _audioDataCallback = nil;
    
    Log("Deallocating");
    [self stopDeviceMonitoring];
    [self destroyAudioResources];
    if (_tccHandle) {
        Log("Closing TCC framework handle");
        dlclose(_tccHandle);
    }
}

#pragma mark - Audio Setup Methods

- (BOOL)setupAudioTapIfNeeded:(NSError **)error {
    if (_tapUID != NULL) {
        return YES;
    }
    
    Log("Setting up audio tap");
    

    CATapDescription *desc = [[CATapDescription alloc]
                               initMonoGlobalTapButExcludeProcesses:@[]];
    // Create a unique tap UID
    _tapUID = [NSUUID UUID];

    desc.name = [NSString stringWithFormat: @"audiorec-tap-%@", _tapUID];
    desc.UUID = _tapUID;
    desc.privateTap = true;
    desc.muteBehavior = CATapUnmuted;
    desc.exclusive = false;
    desc.mixdown = true;

    _tapObjectID = kAudioObjectUnknown;
    OSStatus ret = AudioHardwareCreateProcessTap(desc, &_tapObjectID);
    
    if (ret != kAudioHardwareNoError) {
        if (error) {
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:ret
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to create audio tap"}];
        }
        return NO;
    }
    
    Log("Audio tap setup successfully");
    return YES;
}

- (BOOL)startCapture:(NSError **)error {
    if (_isCapturing) {
        return YES;
    }
    
    Log("Starting audio capture");
    
    NSDictionary *permissions = [self getPermissions];
    NSString *audioStatus = permissions[@"audio"];
    if (![audioStatus isEqualToString:@"authorized"]) {
        return NO;
    }

    // check mic permission
    NSString *micStatus = permissions[@"microphone"];
    if (![micStatus isEqualToString:@"authorized"]) {
        return NO;
    }

    // Set up audio tap and aggregate device if needed
    if (![self setupAudioTapIfNeeded:error]) {
        return NO;
    }
    
    if (![self setupAggregateDeviceIfNeeded:error]) {
        return NO;
    }
    
    // Log device IDs for debugging
    Log("Using aggregate device ID: " + std::to_string(_aggregateDeviceID));
    Log("Tap object ID: " + std::to_string(_tapObjectID));
    
    // Set up IO proc for the aggregate device instead of tap
    OSStatus status = AudioDeviceCreateIOProcID(_aggregateDeviceID,
                                             HandleAudioDeviceIOProc,
                                             (__bridge void *)self,
                                             &_deviceProcID);
    
    if (status != noErr) {
        if (error) {
            NSString *errorDescription = [NSString stringWithFormat:@"Failed to create IO proc for aggregate device. Status code: %d. This typically means there was an issue setting up the audio processing callback for the device.", (int)status];
            
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:status
                                   userInfo:@{
                                       NSLocalizedDescriptionKey: errorDescription,
                                       @"OSStatus": @(status),
                                       @"ErrorLocation": @"AudioDeviceCreateIOProcID"
                                   }];
        }
        return NO;
    }
    
    // Start the IO proc on the aggregate device
    status = AudioDeviceStart(_aggregateDeviceID, _deviceProcID);
    if (status != noErr) {
        AudioDeviceDestroyIOProcID(_aggregateDeviceID, _deviceProcID);
        _deviceProcID = NULL;
        if (error) {
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to start audio capture"}];
        }
        return NO;
    }
    
    _isCapturing = YES;
    Log("Audio capture started successfully");
    return YES;
}

- (BOOL)stopCapture:(NSError **)error {
    if (!_isCapturing) {
        return YES;
    }
    
    Log("Stopping audio capture");
    
    // Stop and destroy the IO proc on the aggregate device
    if (_deviceProcID != NULL) {
        OSStatus status = AudioDeviceStop(_aggregateDeviceID, _deviceProcID);
        if (status != noErr) {
            if (error) {
                *error = [NSError errorWithDomain:@"audio-manager"
                                           code:status
                                       userInfo:@{NSLocalizedDescriptionKey: @"Failed to stop audio capture"}];
            }
            return NO;
        }
        
        status = AudioDeviceDestroyIOProcID(_aggregateDeviceID, _deviceProcID);
        if (status != noErr) {
            if (error) {
                *error = [NSError errorWithDomain:@"audio-manager"
                                           code:status
                                       userInfo:@{NSLocalizedDescriptionKey: @"Failed to destroy IO proc"}];
            }
            return NO;
        }
        
        _deviceProcID = NULL;
    }
    
    _isCapturing = NO;
    Log("Audio capture stopped successfully");
    return YES;
}

static OSStatus HandleAudioDeviceIOProc(AudioDeviceID inDevice,
                                      const AudioTimeStamp* inNow,
                                      const AudioBufferList* inInputData,
                                      const AudioTimeStamp* inInputTime,
                                      AudioBufferList* outOutputData,
                                      const AudioTimeStamp* inOutputTime,
                                      void* inClientData) {
    AudioManager *audioManager = (__bridge AudioManager *)inClientData;
    [audioManager handleAudioInput:inInputData];
    return noErr;
}

- (Float32 *)convertToMono:(const AudioBufferList *)bufferList numFrames:(UInt32)numFrames {
    if (!bufferList || bufferList->mNumberBuffers == 0) {
        Log("Invalid buffer list received", "error");
        return NULL;
    }
    
    const AudioBuffer *buffer = &bufferList->mBuffers[0];
    if (!buffer->mData || buffer->mDataByteSize == 0) {
        Log("Invalid buffer data received", "error");
        return NULL;
    }
    
    Float32 *samples = (Float32 *)buffer->mData;
    
    // Determine channel count and format based on source format
    BOOL isInterleaved = !(_sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    UInt32 numChannels = _sourceFormat.mChannelsPerFrame;
    if (numChannels == 0) {
        numChannels = bufferList->mNumberBuffers;
    }
    
    // Allocate mono buffer
    Float32 *monoBuffer = (Float32 *)calloc(numFrames, sizeof(Float32));
    if (!monoBuffer) {
        Log("Failed to allocate memory for mono buffer", "error");
        return NULL;
    }
    
    // Merge channels to mono based on format
    if (isInterleaved) {
        // Handle interleaved format (all channels in one buffer)
        for (UInt32 frame = 0; frame < numFrames; frame++) {
            float sum = 0.0f;
            for (UInt32 channel = 0; channel < numChannels; channel++) {
                sum += samples[frame * numChannels + channel];
            }
            monoBuffer[frame] = sum / numChannels;
        }
    } else {
        // Handle non-interleaved format (separate buffers for each channel)
        for (UInt32 frame = 0; frame < numFrames; frame++) {
            float sum = 0.0f;
            for (UInt32 channel = 0; channel < numChannels; channel++) {
                const AudioBuffer *channelBuffer = &bufferList->mBuffers[channel];
                Float32 *channelData = (Float32 *)channelBuffer->mData;
                sum += channelData[frame];
            }
            monoBuffer[frame] = sum / numChannels;
        }
    }
    
    return monoBuffer;
}

- (Float32 *)resampleBuffer:(Float32 *)inputBuffer inputFrames:(UInt32)inputFrames outputFrames:(UInt32 *)outputFrames {
    Float64 sourceRate = _sourceFormat.mSampleRate;
    Float64 ratio = sourceRate / kTargetSampleRate;
    UInt32 newFrameLength = (UInt32)(inputFrames / ratio);
    
    if (newFrameLength == 0) {
        Log("Invalid resampled frame length", "error");
        return NULL;
    }
    
    // Allocate buffer for resampled data
    Float32 *resampledBuffer = (Float32 *)calloc(newFrameLength, sizeof(Float32));
    if (!resampledBuffer) {
        Log("Failed to allocate memory for resampled buffer", "error");
        return NULL;
    }
    
    // Perform sinc resampling
    const UInt32 windowSize = 16;
    const UInt32 halfWindow = windowSize / 2;
    const float M_2PI = 2.0f * M_PI;
    
    for (UInt32 newIndex = 0; newIndex < newFrameLength; newIndex++) {
        float position = newIndex * ratio;
        int32_t centerIndex = (int32_t)floorf(position);
        float fracOffset = position - centerIndex;
        float sum = 0.0f;
        float weightSum = 0.0f;
        
        for (int32_t i = -(int32_t)halfWindow; i <= (int32_t)halfWindow; i++) {
            int32_t sampleIndex = centerIndex + i;
            
            if (sampleIndex < 0 || (UInt32)sampleIndex >= inputFrames) {
                continue;
            }
            
            float x = fracOffset - i;
            // Use normalized sinc function
            float sincValue = (x == 0.0f) ? 1.0f : sinf(M_PI * x) / (M_PI * x);
            // Blackman window for better frequency response
            float windowValue = 0.42f - 0.5f * cosf(M_PI * (i + halfWindow) / halfWindow) 
                            + 0.08f * cosf(M_2PI * (i + halfWindow) / halfWindow);
            float weight = sincValue * windowValue;
            
            sum += inputBuffer[sampleIndex] * weight;
            weightSum += weight;
        }
        
        // Normalize by total weight
        resampledBuffer[newIndex] = weightSum > 0.0f ? sum / weightSum : 0.0f;
    }
    
    *outputFrames = newFrameLength;
    return resampledBuffer;
}

- (void)handleAudioInput:(const AudioBufferList *)bufferList {
    if (!_isCapturing || !_audioDataCallback) {
        return;
    }
    
    @autoreleasepool {
        // Validate input data
        if (!bufferList || bufferList->mNumberBuffers == 0) {
            Log("Invalid buffer list received", "error");
            return;
        }
        
        const AudioBuffer *buffer = &bufferList->mBuffers[0];
        UInt32 numFrames = buffer->mDataByteSize / sizeof(Float32);
        
        // Determine channel count based on source format
        BOOL isInterleaved = !(_sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
        UInt32 numChannels = _sourceFormat.mChannelsPerFrame;
        if (numChannels == 0) {
            numChannels = bufferList->mNumberBuffers;
        }
        
        // For interleaved data, adjust numFrames
        if (isInterleaved) {
            numFrames = numFrames / numChannels;
        }
        
        // Validate frame count
        if (numFrames == 0) {
            Log("Invalid frame count", "error");
            return;
        }
        
        @try {
            // Convert to mono
            Float32 *monoBuffer = [self convertToMono:bufferList numFrames:numFrames];
            if (!monoBuffer) {
                return;
            }
            
            // Resample
            UInt32 resampledFrameLength = 0;
            Float32 *resampledBuffer = [self resampleBuffer:monoBuffer inputFrames:numFrames outputFrames:&resampledFrameLength];
            free(monoBuffer);
            
            if (!resampledBuffer) {
                return;
            }
            
            // Create NSData safely
            NSData *audioData = [[NSData alloc] initWithBytes:resampledBuffer 
                                                     length:resampledFrameLength * sizeof(Float32)];
            free(resampledBuffer);
            
            // Send to callback on main thread
            if (audioData) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self->_audioDataCallback) {
                        self->_audioDataCallback(audioData);
                    }
                });
            }
        } @catch (NSException *exception) {
            Log(std::string("Exception in handleAudioInput: ") + 
                     std::string([exception.description UTF8String]), "error");
        }
    }
}

#pragma mark - Aggregate Device Setup

- (BOOL)setupAggregateDeviceIfNeeded:(NSError **)error {
    if (_aggregateDeviceID != kAudioDeviceUnknown) {
        return YES;
    }
    
    Log("Setting up aggregate device");
    
    // Get default input and output devices
    AudioDeviceID inputDeviceID, outputDeviceID;
    UInt32 propertySize = sizeof(AudioDeviceID);
    AudioObjectPropertyAddress propertyAddress = {
        .mSelector = kAudioHardwarePropertyDefaultInputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    // Get default input device
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                               &propertyAddress,
                                               0,
                                               NULL,
                                               &propertySize,
                                               &inputDeviceID);
    
    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to get default input device"}];
        }
        return NO;
    }

    Log("Got input device ID: " + std::to_string(inputDeviceID));
    
    // Get default output device
    propertyAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                      &propertyAddress,
                                      0,
                                      NULL,
                                      &propertySize,
                                      &outputDeviceID);
    
    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to get default output device"}];
        }
        return NO;
    }

    Log("Got output device ID: " + std::to_string(outputDeviceID));
    
    // Get device UIDs
    CFStringRef inputUID, outputUID;
    AudioObjectPropertyAddress uidPropertyAddress = {
        .mSelector = kAudioDevicePropertyDeviceUID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    UInt32 dataSize = sizeof(CFStringRef);
    
    status = AudioObjectGetPropertyData(inputDeviceID,
                                      &uidPropertyAddress,
                                      0,
                                      NULL,
                                      &dataSize,
                                      &inputUID);
    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to get input device UID"}];
        }
        return NO;
    }

    Log("Got input device UID: " + std::string([(__bridge NSString *)inputUID UTF8String]));
    
    status = AudioObjectGetPropertyData(outputDeviceID,
                                      &uidPropertyAddress,
                                      0,
                                      NULL,
                                      &dataSize,
                                      &outputUID);
    if (status != noErr) {
        CFRelease(inputUID);
        if (error) {
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to get output device UID"}];
        }
        return NO;
    }

    Log("Got output device UID: " + std::string([(__bridge NSString *)outputUID UTF8String]));
    
    // Get sample rates for both devices
    Float64 inputSampleRate, outputSampleRate;
    AudioObjectPropertyAddress sampleRateAddress = {
        .mSelector = kAudioDevicePropertyNominalSampleRate,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    dataSize = sizeof(Float64);
    
    status = AudioObjectGetPropertyData(inputDeviceID,
                                      &sampleRateAddress,
                                      0,
                                      NULL,
                                      &dataSize,
                                      &inputSampleRate);
    if (status != noErr) {
        CFRelease(inputUID);
        CFRelease(outputUID);
        if (error) {
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to get input device sample rate"}];
        }
        return NO;
    }

    Log("Input device sample rate: " + std::to_string(inputSampleRate));
    
    status = AudioObjectGetPropertyData(outputDeviceID,
                                      &sampleRateAddress,
                                      0,
                                      NULL,
                                      &dataSize,
                                      &outputSampleRate);
    if (status != noErr) {
        CFRelease(inputUID);
        CFRelease(outputUID);
        if (error) {
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to get output device sample rate"}];
        }
        return NO;
    }

    Log("Output device sample rate: " + std::to_string(outputSampleRate));
    
    // Choose master device based on lower sample rate
    NSString *masterDeviceUID = inputSampleRate <= outputSampleRate ? (__bridge NSString *)inputUID : (__bridge NSString *)outputUID;
    Log("Selected master device UID: " + std::string([masterDeviceUID UTF8String]) + 
              " (based on sample rate comparison: " + std::to_string(inputSampleRate) + " <= " + std::to_string(outputSampleRate) + ")");
    
    NSUUID* aggregateUID = [NSUUID UUID];
    Log("Created aggregate device UUID: " + std::string([[aggregateUID UUIDString] UTF8String]));

    NSDictionary* description = @{
        @(kAudioAggregateDeviceUIDKey): [aggregateUID UUIDString],
        @(kAudioAggregateDeviceIsPrivateKey): @(1),
        @(kAudioAggregateDeviceIsStackedKey): @(0),
        @(kAudioAggregateDeviceMasterSubDeviceKey): masterDeviceUID,
        @(kAudioAggregateDeviceSubDeviceListKey): @[
            @{
                @(kAudioSubDeviceUIDKey): (__bridge NSString *)inputUID,
                @(kAudioSubDeviceDriftCompensationKey): @(0),
                @(kAudioSubDeviceDriftCompensationQualityKey): @(kAudioSubDeviceDriftCompensationMaxQuality),
            },
            @{
                @(kAudioSubDeviceUIDKey): (__bridge NSString *)outputUID,
                @(kAudioSubDeviceDriftCompensationKey): @(1),
                @(kAudioSubDeviceDriftCompensationQualityKey): @(kAudioSubDeviceDriftCompensationMaxQuality),
            },
        ],
        @(kAudioAggregateDeviceTapListKey): @[
            @{
                @(kAudioSubTapDriftCompensationKey): @(1),
                @(kAudioSubTapUIDKey): [_tapUID UUIDString],
            },
        ],
    };

    // Create the aggregate device
    AudioDeviceID aggregateDeviceID;
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description, &aggregateDeviceID);
    
    CFRelease(inputUID);
    CFRelease(outputUID);
    
    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:@"audio-manager"
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to create aggregate device"}];
        }
        return NO;
    }

   // Configure buffer size for aggregate device
    AudioObjectPropertyAddress bufferSizeAddress = {
        .mSelector = kAudioDevicePropertyBufferFrameSize,
        .mScope = kAudioDevicePropertyScopeInput,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    UInt32 bufferSize = kPreferredBufferSize;
    status = AudioObjectSetPropertyData(aggregateDeviceID,
                                      &bufferSizeAddress,
                                      0,
                                      NULL,
                                      sizeof(UInt32),
                                      &bufferSize);
    
    if (status == noErr) {
        Log("Set aggregate device buffer size to: " + std::to_string(bufferSize));
    } else {
        Log("Failed to set aggregate device buffer size, continuing with default", "warning");
    }

    // Get and log aggregate device info
    Float64 aggregateSampleRate;
    status = AudioObjectGetPropertyData(aggregateDeviceID,
                                      &sampleRateAddress,
                                      0,
                                      NULL,
                                      &dataSize,
                                      &aggregateSampleRate);
    
    if (status == noErr) {
        Log("Created aggregate device with ID: " + std::to_string(aggregateDeviceID) + 
                 ", sample rate: " + std::to_string(aggregateSampleRate));
        
        // Get format description
        AudioStreamBasicDescription format;
        UInt32 formatSize = sizeof(AudioStreamBasicDescription);
        AudioObjectPropertyAddress formatAddress = {
            .mSelector = kAudioDevicePropertyStreamFormat,
            .mScope = kAudioDevicePropertyScopeInput,
            .mElement = kAudioObjectPropertyElementMain
        };
        
        status = AudioObjectGetPropertyData(aggregateDeviceID,
                                          &formatAddress,
                                          0,
                                          NULL,
                                          &formatSize,
                                          &format);
        
        if (status == noErr) {
            Log("Aggregate device format details:");
            Log("- Sample rate: " + std::to_string(format.mSampleRate));
            Log("- Format ID: " + std::to_string(format.mFormatID));
            Log("- Format flags: " + std::to_string(format.mFormatFlags));
            Log("- Bytes per packet: " + std::to_string(format.mBytesPerPacket));
            Log("- Frames per packet: " + std::to_string(format.mFramesPerPacket));
            Log("- Bytes per frame: " + std::to_string(format.mBytesPerFrame));
            Log("- Channels per frame: " + std::to_string(format.mChannelsPerFrame));
            Log("- Bits per channel: " + std::to_string(format.mBitsPerChannel));
            bool isInterleaved = !(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
            Log("- Is interleaved: " + std::string(isInterleaved ? "yes" : "no"));
        }
        _sourceFormat = format;
    }
    
    _aggregateDeviceID = aggregateDeviceID;
    Log("Aggregate device setup successfully");
    return YES;
}

#pragma mark - Device Monitoring

- (void)startDeviceMonitoring {
    Log("Starting device monitoring");
    
    // Set up device change listener for both input and output devices
    AudioObjectPropertyAddress propertyAddress = {
        .mSelector = kAudioHardwarePropertyDefaultInputDevice,
        .mScope = kDeviceChangeScope,
        .mElement = kDeviceChangeElement
    };
    
    // Create block for device changes
    AudioManager* blockSelf = self;
    _deviceChangeListener = ^(UInt32 inNumberAddresses,
                            const AudioObjectPropertyAddress* inAddresses) {
        [blockSelf handleDeviceChange];
    };
    
    // Add listener for input device changes
    OSStatus status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
                                                        &propertyAddress,
                                                        self->_audioQueue,
                                                        self->_deviceChangeListener);
    
    if (status != noErr) {
        Log("Failed to add input device change listener", "error");
        return;
    }
    
    // Add listener for output device changes
    propertyAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
                                               &propertyAddress,
                                               self->_audioQueue,
                                               self->_deviceChangeListener);
    
    if (status != noErr) {
        Log("Failed to add output device change listener", "error");
        return;
    }
    
    Log("Device monitoring started successfully");
}

- (void)handleDeviceChange {
    Log("Handling device change");
    
    // If we're currently capturing, we need to recreate the audio setup
    BOOL wasCapturing = _isCapturing;
    if (wasCapturing) {
        NSError *error = nil;
        [self stopCapture:&error];
        if (error) {
            Log(std::string("Failed to stop capture after device change: ") + 
                     std::string([error.localizedDescription UTF8String]), "error");
            return;
        }
    }
    
    // Destroy and recreate audio resources
    [self destroyAudioResources];
    
    NSError *error = nil;
    if (![self setupAudioTapIfNeeded:&error]) {
        Log(std::string("Failed to setup audio tap after device change: ") + 
                 std::string([error.localizedDescription UTF8String]), "error");
        return;
    }
    
    if (![self setupAggregateDeviceIfNeeded:&error]) {
        Log(std::string("Failed to setup aggregate device after device change: ") + 
                 std::string([error.localizedDescription UTF8String]), "error");
        return;
    }
    
    // If we were capturing before, restart capture
    if (wasCapturing) {
        NSError *error = nil;
        [self startCapture:&error];
        if (error) {
            Log(std::string("Failed to start capture after device change: ") + 
                     std::string([error.localizedDescription UTF8String]), "error");
            return;
        }
    }
    
    Log("Device change handled successfully");
}

- (void)stopDeviceMonitoring {
    Log("Stopping device monitoring");
    
    if (_deviceChangeListener) {
        // Remove input device listener
        AudioObjectPropertyAddress propertyAddress = {
            .mSelector = kAudioHardwarePropertyDefaultInputDevice,
            .mScope = kDeviceChangeScope,
            .mElement = kDeviceChangeElement
        };
        
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                             &propertyAddress,
                                             _audioQueue,
                                             _deviceChangeListener);
        
        // Remove output device listener
        propertyAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                             &propertyAddress,
                                             _audioQueue,
                                             _deviceChangeListener);
        
        _deviceChangeListener = nil;
    }
    
    Log("Device monitoring stopped");
}

- (void)destroyAudioResources {
    Log("Destroying audio resources");
    
    if (_deviceProcID && _aggregateDeviceID != kAudioDeviceUnknown) {
        AudioDeviceDestroyIOProcID(_aggregateDeviceID, _deviceProcID);
        _deviceProcID = NULL;
    }
    
    if (_tapObjectID != 0) {
        AudioHardwareDestroyProcessTap(_tapObjectID);
        _tapObjectID = 0;
    }
    
    if (_tapUID) {
        _tapUID = NULL;
    }
    
    if (_aggregateDeviceID != kAudioDeviceUnknown) {
        AudioHardwareDestroyAggregateDevice(_aggregateDeviceID);
        _aggregateDeviceID = kAudioDeviceUnknown;
    }
    
    Log("Audio resources destroyed");
}

#pragma mark - Audio Data Callback

- (void)setAudioDataCallback:(void (^)(NSData *audioData))callback {
    _audioDataCallback = [callback copy];
}

#pragma mark - TCC Framework Methods

- (void)initializeTCCFramework {
  Log("Initializing TCC framework");
  
  // Load TCC framework
  NSString *tccPath = @"/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC";
  _tccHandle = dlopen([tccPath UTF8String], RTLD_NOW);
  if (!_tccHandle) {
    Log(std::string("Failed to load TCC framework: ") + std::string(dlerror()), "error");
    return;
  }
  Log("Successfully loaded TCC framework");

  // Get function pointers
  _preflightFunc = (TCCPreflightFuncType)dlsym(_tccHandle, "TCCAccessPreflight");
  _requestFunc = (TCCRequestFuncType)dlsym(_tccHandle, "TCCAccessRequest");

  if (!_preflightFunc || !_requestFunc) {
    Log(std::string("Failed to get TCC function pointers: ") + std::string(dlerror()), "error");
    dlclose(_tccHandle);
    _tccHandle = NULL;
    return;
  }
  Log("Successfully initialized TCC functions");
}

- (int)checkTCCPermission:(NSString *)service {
  Log("Checking TCC permission for service: " + std::string([service UTF8String]));
  
  if (!_preflightFunc) {
    Log("TCC preflight function not available", "error");
    return 2; // Not determined
  }
  
  int result = _preflightFunc((__bridge CFStringRef)service, NULL);
  NSString *status;
  switch (result) {
    case 0:
      status = @"authorized";
      break;
    case 1:
      status = @"denied";
      break;
    case 2:
      status = @"not_determined";
      break;
    default:
      status = @"unknown";
      break;
  }
  Log("TCC permission result for " + std::string([service UTF8String]) + ": " + 
            std::string([status UTF8String]) + " (" + std::to_string(result) + ")");
  return result;
}

- (void)requestTCCPermission:(NSString *)service completion:(void (^)(BOOL granted))completion {
  Log("Requesting TCC permission for service: " + std::string([service UTF8String]));
  
  if (!_requestFunc) {
    Log("TCC request function not available", "error");
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(NO);
    });
    return;
  }
  
  _requestFunc((__bridge CFStringRef)service, NULL, ^(BOOL granted) {
    dispatch_async(dispatch_get_main_queue(), ^{
      Log("TCC permission request for " + std::string([service UTF8String]) + 
                " completed with result: " + (granted ? "granted" : "denied"));
      completion(granted);
    });
  });
}

#pragma mark - Permission Methods

- (NSDictionary *)getPermissions {
  Log("Getting all permissions");
  
  // Check microphone permission
  AVAuthorizationStatus micStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
  NSString *micPermissionStatus;
  
  switch (micStatus) {
  case AVAuthorizationStatusAuthorized:
    micPermissionStatus = @"authorized";
    break;
  case AVAuthorizationStatusDenied:
    micPermissionStatus = @"denied";
    break;
  case AVAuthorizationStatusRestricted:
    micPermissionStatus = @"restricted";
    break;
  case AVAuthorizationStatusNotDetermined:
    micPermissionStatus = @"not_determined";
    break;
  }
  Log("Microphone permission status: " + std::string([micPermissionStatus UTF8String]));
  
  // Check audio recording permission using TCC
  int audioResult = [self checkTCCPermission:@"kTCCServiceAudioCapture"];
  NSString *audioPermissionStatus;
  
  switch (audioResult) {
  case 0:
    audioPermissionStatus = @"authorized";
    break;
  case 1:
    audioPermissionStatus = @"denied";
    break;
  case 2:
    audioPermissionStatus = @"not_determined";
    break;
  default:
    audioPermissionStatus = @"not_determined";
    break;
  }
  Log("System audio permission status: " + std::string([audioPermissionStatus UTF8String]));
  
  return @{
    @"microphone": micPermissionStatus,
    @"audio": audioPermissionStatus
  };
}

- (void)requestPermissionsForDevice:(DeviceType)deviceType completion:(void (^)(NSDictionary *))completion {
  NSString *deviceTypeStr = deviceType == DeviceTypeMicrophone ? @"microphone" : @"audio";
  Log("Requesting permission for device type: " + std::string([deviceTypeStr UTF8String]));
  
  if (deviceType == DeviceTypeMicrophone) {
    Log("Requesting microphone permission via AVCaptureDevice");
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                           completionHandler:^(BOOL granted) {
                             dispatch_async(dispatch_get_main_queue(), ^{
                               NSString *status = granted ? @"authorized" : @"denied";
                               Log("Microphone permission request completed with status: " + 
                                       std::string([status UTF8String]));
                               NSDictionary *result = @{
                                 @"microphone": status,
                               };
                               completion(result);
                             });
                           }];
  } else if (deviceType == DeviceTypeAudio) {
    Log("Requesting system audio permission via TCC");
    [self requestTCCPermission:@"kTCCServiceAudioCapture" completion:^(BOOL granted) {
      dispatch_async(dispatch_get_main_queue(), ^{
        NSString *status = granted ? @"authorized" : @"denied";
        Log("System audio permission request completed with status: " + 
                 std::string([status UTF8String]));
        NSDictionary *result = @{
          @"audio": status
        };
        completion(result);
      });
    }];
  }
}

@end