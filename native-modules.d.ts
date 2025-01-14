/**
 * @file native-modules.d.ts
 * @description TypeScript definitions for the native audio manager module.
 */

declare module "native-modules" {
  /**
   * Represents the possible states of device permission.
   */
  export type PermissionStatus =
    | "not_determined" // Permission hasn't been requested yet
    | "denied" // User explicitly denied permission
    | "authorized" // Permission granted
    | "restricted"; // Permission restricted by system policy

  /**
   * Types of audio devices that can be accessed.
   */
  export type DeviceType = "microphone" | "audio";

  /**
   * Structure containing permission status for both microphone and audio capture.
   */
  export interface PermissionResult {
    microphone: PermissionStatus;
    audio: PermissionStatus;
  }

  /**
   * Interface for the native audio manager instance.
   */
  export interface AudioWrapperInstance {
    /**
     * Start capturing audio from the system.
     * @param callback Function that receives captured audio data
     * @throws If permissions not granted or setup fails
     */
    startCapture(callback: (data: ArrayBuffer) => void): void;

    /**
     * Stop the current audio capture session.
     * @throws If stopping capture fails
     */
    stopCapture(): void;

    /**
     * Get current permission status for audio devices.
     * @returns Object containing permission status for each device type
     */
    getPermissions: () => PermissionResult;

    /**
     * Request permission to access an audio device.
     * @param deviceType The type of device to request permission for
     * @returns Promise that resolves with updated permission status
     */
    requestPermissions: (deviceType: DeviceType) => Promise<PermissionResult>;
  }

  /**
   * Interface for the native addon module.
   */
  export interface NativeAddon {
    AudioWrapper: {
      new (): AudioWrapperInstance;
    };
  }

  /**
   * The native addon instance.
   * Use this to create new AudioWrapper instances.
   */
  const addon: NativeAddon;
  export default addon;
}
