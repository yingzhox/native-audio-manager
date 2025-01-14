{
  "targets": [
    {
      "target_name": "nativeAudioManager",
      "cflags!": [
        "-fno-exceptions"
      ],
      "cflags_cc!": [
        "-fno-exceptions"
      ],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include\")"
      ],
      "defines": [
        "NAPI_DISABLE_CPP_EXCEPTIONS"
      ],
      "conditions": [
        [
          "OS==\"mac\"",
          {
            "sources": [
              "<!@(node -p \"require('fs').readdirSync('./mac').map(f=>'mac/'+f).join(' ')\")"
            ],
            "libraries": [
              "-framework Cocoa"
            ],
            "xcode_settings": {
              "MACOSX_DEPLOYMENT_TARGET": "15.0",
              "CLANG_CXX_LIBRARY": "libc++",
              "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
              "GCC_ENABLE_CPP_RTTI": "YES",
              "CLANG_ENABLE_OBJC_ARC": "YES",
              "OTHER_CFLAGS": [
                "-std=c++17",
                "-fexceptions",
                "-x",
                "objective-c++"
              ],
              "OTHER_CPLUSPLUSFLAGS": [
                "-std=c++17",
                "-fexceptions",
                "-x",
                "objective-c++"
              ]
            },
            "link_settings": {
              "libraries": [
                "$(SDKROOT)/System/Library/Frameworks/Foundation.framework",
                "$(SDKROOT)/System/Library/Frameworks/AVFoundation.framework",
                "$(SDKROOT)/System/Library/Frameworks/CoreAudio.framework",
                "$(SDKROOT)/System/Library/Frameworks/AudioToolbox.framework"
              ]
            }
          }
        ]
      ]
    }
  ]
}
