declare module 'native-modules' {
  export type PermissionStatus =
    | 'not_determined'
    | 'denied'
    | 'authorized'
    | 'restricted';

  export type DeviceType = 'microphone' | 'audio';

  export interface PermissionResult {
    microphone: PermissionStatus;
    audio: PermissionStatus;
  }

  export interface AudioWrapperInstance {
    startCapture(callback: (data: ArrayBuffer) => void): void;
    stopCapture(): void;
    getPermissions: () => PermissionResult;
    requestPermissions: (deviceType: DeviceType) => Promise<PermissionResult>;
  }

  export interface NativeAddon {
    AudioWrapper: {
      new (): AudioWrapperInstance;
    };
  }

  const addon: NativeAddon;
  export default addon;
}
