See this [article](https://dev.to/yingzhong_xu_20d6f4c5d4ce/from-core-audio-to-llms-native-macos-audio-capture-for-ai-powered-tools-dkg) for more details.

# Native Audio Manager for macOS

A native Node.js module that provides system-level audio device management and capture capabilities for macOS applications. This module is particularly useful for Electron applications that need to interact with system audio devices and capture audio streams.

## Features

- System audio device management and monitoring
- Audio stream capture from system devices
- Permission handling for microphone and audio capture
- Automatic audio device change detection
- Support for aggregate audio devices
- TypeScript type definitions included

## Installation

First, install the required global dependencies:

```bash
npm i -g node-gyp electron-rebuild node-addon-api
```

## Development Setup (VSCode)

This command configures the project for building with node-gyp.

```
npm run configure
```

This command creates a `.clangd` file in the project root, to make code-intellisense work in vscode.

```
./setup-clangd.sh
```

## Use it in Electron

Native nodejs addon has to be built with electron-rebuild. If you are using electron-react-boilerplate, simply put this project under the `release/app` folder. Add it as dependency in `package.json`.

```
  "dependencies": {
    "native-audio-manager": "file:native-audio-manager"
  }
```

Then run this command inside the `release/app` folder.

```
npm install
```

## Core Functions

### Audio Device Management

#### `getPermissions()`

Returns the current permission status for microphone and audio capture access. The status can be:

- `notDetermined`: Permission hasn't been requested yet
- `authorized`: Permission granted
- `denied`: Permission explicitly denied
- `restricted`: Permission restricted by system policy

#### `requestPermissions(deviceType, callback)`

Request system permissions for audio access.

- `deviceType`: Either 'microphone' or 'audio'
- `callback`: Function called with permission result

### Audio Capture

#### `setAudioCallback(callback)`

Sets up a callback function to receive captured audio data.

- `callback`: Function that receives audio data as Buffer

#### `startCapture()`

Starts capturing system audio. Returns a Promise that resolves when capture begins.

- Throws error if permissions not granted or setup fails

#### `stopCapture()`

Stops the current audio capture session. Returns a Promise that resolves when stopped.

## Technical Details

- Uses macOS Core Audio and AVFoundation frameworks
- Implements TCC (Transparency, Consent, and Control) permission handling
- Supports automatic audio device change detection
- Creates and manages aggregate audio devices when needed
- Handles audio format conversion and buffering

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
