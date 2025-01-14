#import <Foundation/Foundation.h>
#import <string>
#import <napi.h>

// Helper function to log messages
void Log(const std::string& message, const std::string& level = "info");
