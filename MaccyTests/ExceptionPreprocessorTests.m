#import <XCTest/XCTest.h>
#import "../Maccy/ExceptionPreprocessor.h"

static id ReplaceException(id object) {
  return [(NSException *)object userInfo][@"replacement"] ?: object;
}

@interface ExceptionPreprocessorTests : XCTestCase
@end

@implementation ExceptionPreprocessorTests

- (void)testAbsentPreprocessorPreservesOriginalException {
  NSException *original = [NSException exceptionWithName:@"Original" reason:nil userInfo:nil];
  XCTAssertTrue(ForwardExceptionToPreprocessor(original, NULL) == original);
}

- (void)testPriorPreprocessorCanReplaceException {
  NSException *replacement = [NSException exceptionWithName:@"Replacement" reason:nil userInfo:nil];
  NSException *original = [NSException exceptionWithName:@"Original" reason:nil
    userInfo:@{@"replacement": replacement}];
  XCTAssertTrue(ForwardExceptionToPreprocessor(original, ReplaceException) == replacement);
}

@end
