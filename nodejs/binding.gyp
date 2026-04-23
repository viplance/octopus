{
  "targets": [
    {
      "target_name": "octopussync_mac",
      "sources": [ "src/addon.mm" ],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include\")"
      ],
      "dependencies": [
        "<!(node -p \"require('node-addon-api').gyp\")"
      ],
      "defines": [ "NAPI_DISABLE_CPP_EXCEPTIONS" ],
      "conditions": [
        ["OS=='mac'", {
          "xcode_settings": {
            "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
            "CLANG_CXX_LIBRARY": "libc++",
            "MACOSX_DEPLOYMENT_TARGET": "10.15",
            "OTHER_CFLAGS": [
              "-fobjc-arc"
            ],
            "OTHER_CPLUSPLUSFLAGS": [
              "-std=c++17",
              "-stdlib=libc++",
              "-fobjc-arc"
            ],
            "OTHER_LDFLAGS": [
              "-framework IOKit",
              "-framework CoreFoundation",
              "-framework Foundation",
              "-framework ApplicationServices",
              "-framework CoreGraphics",
              "-framework AppKit"
            ]
          }
        }]
      ]
    }
  ]
}
