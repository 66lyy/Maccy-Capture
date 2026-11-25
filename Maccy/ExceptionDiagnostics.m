#import "ExceptionDiagnostics.h"
#import "ExceptionPreprocessor.h"
#import <AppKit/AppKit.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

static NSURL *reportDirectory;
static NSString *settingsTitle;
static NSUncaughtExceptionHandler *previousUncaughtHandler;
static objc_exception_preprocessor previousPreprocessor;
static struct sigaction previousAbort;
static pthread_t layoutThread;
static char layoutPath[PATH_MAX];
static char layoutReport[64 * 1024];
static volatile sig_atomic_t layoutReportSize;
static NSUInteger layoutGeneration;
static _Thread_local BOOL recording;

static NSString *YesNo(BOOL value) {
  return value ? @"yes" : @"no";
}

static NSURL *ReportURL(void) {
  NSString *timestamp = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
  NSString *filename = [NSString stringWithFormat:@"exception-%@-%@.txt",
    [timestamp stringByReplacingOccurrencesOfString:@":" withString:@"-"], NSUUID.UUID.UUIDString];
  return [reportDirectory URLByAppendingPathComponent:filename];
}

static BOOL IsLayoutException(NSArray<NSString *> *stack) {
  for (NSString *frame in stack) {
    if ([frame containsString:@"AppKit"] && [frame containsString:@"__NSWindowGetDisplayCycleObserverForLayout"]) {
      return YES;
    }
  }
  return NO;
}

static NSString *SafeTitle(NSString *title) {
  if (title.length == 0 || [title isEqualToString:settingsTitle]) return title;
  return @"[redacted]";
}

NSString *ExceptionDiagnosticText(NSException *exception, NSArray<NSString *> *stack) {
  NSArray<NSWindow *> *windows = NSThread.isMainThread ? NSApp.windows : nil;
  NSString *reason = exception.reason == nil ? @"(none)" : @"[redacted outside window layout]";
  if (IsLayoutException(stack) && exception.reason != nil) {
    reason = exception.reason;
    for (NSWindow *window in windows) {
      NSString *title = window.title;
      if (title.length > 0 && ![title isEqualToString:SafeTitle(title)]) {
        reason = [reason stringByReplacingOccurrencesOfString:title withString:@"[redacted]"];
      }
    }
    NSString *home = NSHomeDirectory();
    if (home.length > 0) reason = [reason stringByReplacingOccurrencesOfString:home withString:@"~"];
  }

  NSBundle *bundle = NSBundle.mainBundle;
  NSMutableString *report = [NSMutableString stringWithFormat:
    @"Timestamp: %@\nApp: %@ (%@)\nmacOS: %@\nException: %@\nReason: %@\nUser info keys:",
    [[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
    [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"(unknown)",
    [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"(unknown)",
    NSProcessInfo.processInfo.operatingSystemVersionString, exception.name, reason];
  for (id key in exception.userInfo) {
    if ([key isKindOfClass:NSString.class]) [report appendFormat:@"\n  %@", key];
  }
  [report appendString:@"\nWindows:\n"];
  if (windows == nil) [report appendString:@"  (unavailable off the main thread)\n"];
  for (NSWindow *window in windows) {
    [report appendFormat:@"  %@ title=%@ frame=%@ visible=%@ key=%@ contentView=%@\n",
      NSStringFromClass(window.class), SafeTitle(window.title).debugDescription, NSStringFromRect(window.frame),
      YesNo(window.isVisible), YesNo(window.isKeyWindow),
      window.contentView ? NSStringFromClass(window.contentView.class) : @"(none)"];
  }
  [report appendString:@"Call stack:\n"];
  for (NSString *frame in stack) [report appendFormat:@"  %@\n", frame];
  return report;
}

static void WriteReport(const char *path, const char *bytes, size_t size) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
  if (fd < 0) return;
  while (size > 0) {
    ssize_t written = write(fd, bytes, size);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) break;
    bytes += written;
    size -= (size_t)written;
  }
  close(fd);
}

static void FatalSignal(int signal) {
  int savedErrno = errno;
  if (pthread_self() == layoutThread) {
    sig_atomic_t size = layoutReportSize;
    layoutReportSize = 0;
    if (size > 0) WriteReport(layoutPath, layoutReport, (size_t)size);
  }
  // Only POSIX calls here. Restore and redeliver so the prior disposition and
  // system crash reporter still see the fatal signal.
  sigaction(signal, &previousAbort, NULL);
  errno = savedErrno;
  raise(signal);
}

static id ObserveThrow(id object) {
  object = ForwardExceptionToPreprocessor(object, previousPreprocessor);
  if (pthread_self() != layoutThread || recording || ![object isKindOfClass:NSException.class]) return object;
  recording = YES;
  @try {
    NSException *exception = object;
    NSArray<NSString *> *stack = exception.callStackSymbols;
    if (IsLayoutException(stack)) {
      // AppKit can crash over a display-cycle exception without calling the
      // uncaught handler. Snapshot while Foundation and AppKit are callable.
      NSData *data = [ExceptionDiagnosticText(exception, stack) dataUsingEncoding:NSUTF8StringEncoding];
      layoutReportSize = 0;
      if (data.length > 0 && data.length <= sizeof(layoutReport) &&
          [ReportURL() getFileSystemRepresentation:layoutPath maxLength:sizeof(layoutPath)]) {
        memcpy(layoutReport, data.bytes, data.length);
        layoutReportSize = (sig_atomic_t)data.length;
        NSUInteger generation = ++layoutGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (generation == layoutGeneration) layoutReportSize = 0;
        });
      }
    }
  } @catch (__unused NSException *diagnosticError) {
  } @finally {
    recording = NO;
  }
  return object;
}

static void ObserveUncaught(NSException *exception) {
  if (!recording) {
    recording = YES;
    @try {
      NSArray<NSString *> *stack = exception.callStackSymbols;
      NSData *data = [ExceptionDiagnosticText(exception, stack) dataUsingEncoding:NSUTF8StringEncoding];
      if (pthread_self() == layoutThread) layoutReportSize = 0;
      char path[PATH_MAX];
      if (data.length > 0 && [ReportURL() getFileSystemRepresentation:path maxLength:sizeof(path)]) {
        WriteReport(path, data.bytes, data.length);
      }
    } @catch (__unused NSException *diagnosticError) {
    } @finally {
      recording = NO;
    }
  }
  if (previousUncaughtHandler) previousUncaughtHandler(exception);
}

void InstallExceptionDiagnostics(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *library = [files URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [library URLByAppendingPathComponent:@"Logs/Maccy Capture" isDirectory:YES];
    if (directory == nil || ![files createDirectoryAtURL:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:NULL]) return;

    NSMutableArray<NSString *> *reports = [NSMutableArray array];
    for (NSString *name in [files contentsOfDirectoryAtPath:directory.path error:NULL]) {
      if ([name hasPrefix:@"exception-"] && [name hasSuffix:@".txt"]) [reports addObject:name];
    }
    [reports sortUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i + 4 < reports.count; i++) {
      [files removeItemAtURL:[directory URLByAppendingPathComponent:reports[i]] error:NULL];
    }

    reportDirectory = directory;
    settingsTitle = [NSBundle.mainBundle localizedStringForKey:@"PreferencesWindowTitle"
                                                        value:@"Settings" table:@"GeneralSettings"];
    layoutThread = pthread_self();
    struct sigaction action = { .sa_handler = FatalSignal };
    sigemptyset(&action.sa_mask);
    sigaction(SIGABRT, &action, &previousAbort);
    previousPreprocessor = objc_setExceptionPreprocessor(ObserveThrow);
    previousUncaughtHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(ObserveUncaught);
  });
}
