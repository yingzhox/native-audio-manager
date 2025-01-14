## Install required dependencies

```
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
