#import <objc/objc-exception.h>

static inline id _Nonnull ForwardExceptionToPreprocessor(id _Nonnull object,
    objc_exception_preprocessor _Nullable preprocessor) {
  return preprocessor ? preprocessor(object) : object;
}
