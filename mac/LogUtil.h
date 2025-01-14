/**
 * @file LogUtil.h
 * @brief Logging utility for the native audio manager module.
 *
 * Provides a simple logging interface that can be used throughout the native
 * module to log messages with different severity levels. This utility helps
 * with debugging and monitoring the module's behavior.
 */

#import <Foundation/Foundation.h>
#import <napi.h>
#import <string>

/**
 * @brief Log a message with a specified severity level.
 *
 * This function provides a consistent way to log messages across the native
 * module. It can be used for debugging, error reporting, and general status
 * updates.
 *
 * @param message The message to log
 * @param level The severity level of the message (default: "info")
 *             Supported levels: "info", "warn", "error", "debug"
 *
 * Example usage:
 * @code
 *   Log("Starting audio capture", "info");
 *   Log("Failed to initialize device", "error");
 * @endcode
 */
void Log(const std::string &message, const std::string &level = "info");
