#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void InstallExceptionDiagnostics(void);
NSString *ExceptionDiagnosticText(NSException *exception, NSArray<NSString *> *stack);

NS_ASSUME_NONNULL_END
