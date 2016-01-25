/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTTextField.h"

#import "RCTConvert.h"
#import "RCTEventDispatcher.h"
#import "RCTUtils.h"
#import "NSView+React.h"

@implementation RCTTextField
{
  RCTEventDispatcher *_eventDispatcher;
  NSMutableArray<NSView *> *_reactSubviews;
  BOOL _jsRequestingFirstResponder;
  NSInteger _nativeEventCount;
  NSString * _placeholderString;
  BOOL _submitted;
  NSRange _previousSelectionRange;

}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
  if ((self = [super initWithFrame:CGRectZero])) {
    RCTAssert(eventDispatcher, @"eventDispatcher is a required parameter");
    _eventDispatcher = eventDispatcher;
    self.delegate = self;
    self.drawsBackground = NO;
    self.bordered = NO;

    _previousSelectionRange = self.currentEditor.selectedRange;
//    [self addTarget:self action:@selector(textFieldDidChange) forControlEvents:UIControlEventEditingChanged];
//    [self addTarget:self action:@selector(textFieldBeginEditing) forControlEvents:UIControlEventEditingDidBegin];
//    [self addTarget:self action:@selector(textFieldEndEditing) forControlEvents:UIControlEventEditingDidEnd];
//    [self addTarget:self action:@selector(textFieldSubmitEditing) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self addObserver:self forKeyPath:@"selectedTextRange" options:0 context:nil];
    _reactSubviews = [NSMutableArray new];
  }
  return self;
}

- (void)dealloc
{
  [self removeObserver:self forKeyPath:@"selectedTextRange"];
}

RCT_NOT_IMPLEMENTED(- (instancetype)initWithFrame:(CGRect)frame)
RCT_NOT_IMPLEMENTED(- (instancetype)initWithCoder:(NSCoder *)aDecoder)

- (void)sendKeyValueForString:(NSString *)string
{
  [_eventDispatcher sendTextEventWithType:RCTTextEventTypeKeyPress
                                 reactTag:self.reactTag
                                     text:nil
                                      key:string
                               eventCount:_nativeEventCount];
}

// This method is overridden for `onKeyPress`. The manager
// will not send a keyPress for text that was pasted.
- (void)paste:(id)sender
{
  _textWasPasted = YES;
  NSLog(@"paste is not implemented");
  //[super paste:sender];
}

- (void)setText:(NSString *)text
{
  NSInteger eventLag = _nativeEventCount - _mostRecentEventCount;
  if (eventLag == 0 && ![text isEqualToString:[self stringValue]]) {
    [self setStringValue:text];
    // TODO: maintain cursor position
  } else if (eventLag > RCTTextUpdateLagWarningThreshold) {
    RCTLogWarn(@"Native TextInput(%@) is %zd events ahead of JS - try to make your JS faster.", [self stringValue], eventLag);
  }
}


- (void)setPlaceholderTextColor:(NSColor *)placeholderTextColor
{
  if (placeholderTextColor != nil && ![_placeholderTextColor isEqual:placeholderTextColor]) {
    _placeholderTextColor = placeholderTextColor;
    [self setNeedsDisplay:YES];
  }
}

- (void)setPlaceholder:(NSString *)placeholder
{
  if (placeholder != nil && ![_placeholderString isEqual:placeholder]) {
    _placeholderString = placeholder;
    [self setPlaceholderString:placeholder];
    [self setNeedsDisplay:YES];
  }
}

- (NSArray<NSView *> *)reactSubviews
{
  // TODO: do we support subviews of textfield in React?
  // In any case, we should have a better approach than manually
  // maintaining array in each view subclass like this
  return _reactSubviews;
}

- (void)removeReactSubview:(NSView *)subview
{
  // TODO: this is a bit broken - if the TextField inserts any of
  // its own views below or between React's, the indices won't match
  [_reactSubviews removeObject:subview];
  [subview removeFromSuperview];
}

- (void)insertReactSubview:(NSView *)view atIndex:(NSInteger)atIndex
{
  // TODO: this is a bit broken - if the TextField inserts any of
  // its own views below or between React's, the indices won't match
  [_reactSubviews insertObject:view atIndex:atIndex];
  [super addSubview:view];
}


- (void)textDidChange:(NSNotification *)aNotification
{
  _nativeEventCount++;
  [_eventDispatcher sendTextEventWithType:RCTTextEventTypeChange
                                 reactTag:self.reactTag
                                     text:[self stringValue]
                                      key:nil
                               eventCount:_nativeEventCount];

  // selectedTextRange observer isn't triggered when you type even though the
  // cursor position moves, so we send event again here.
  [self sendSelectionEvent];
}

- (void)textDidEndEditing:(NSNotification *)aNotification
{
  _nativeEventCount++;
  [_eventDispatcher sendTextEventWithType:RCTTextEventTypeEnd
                                 reactTag:self.reactTag
                                     text:[self stringValue]
                                      key:nil
                               eventCount:_nativeEventCount];
}
- (void)textFieldSubmitEditing
{
  _submitted = YES;
  [_eventDispatcher sendTextEventWithType:RCTTextEventTypeSubmit
                                 reactTag:self.reactTag
                                     text:[self stringValue]
                                      key:nil
                               eventCount:_nativeEventCount];
}

- (void)textDidBeginEditing:(NSNotification *)aNotification
{
  if (_selectTextOnFocus) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self selectAll:nil];
    });
  }
  [_eventDispatcher sendTextEventWithType:RCTTextEventTypeFocus
                                 reactTag:self.reactTag
                                     text:[self stringValue]
                                      key:nil
                               eventCount:_nativeEventCount];
}

- (BOOL)textFieldShouldEndEditing:(RCTTextField *)textField
{
//  if (_submitted) {
//    _submitted = NO;
//    return _blurOnSubmit;
//  }
  return YES;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(RCTTextField *)textField
                        change:(NSDictionary *)change
                       context:(void *)context
{
  if ([keyPath isEqualToString:@"selectedTextRange"]) {
    [self sendSelectionEvent];
  }
}

- (void)sendSelectionEvent
{
  if (_onSelectionChange &&
      (self.currentEditor.selectedRange.location != _previousSelectionRange.location ||
      self.currentEditor.selectedRange.length != _previousSelectionRange.length)) {

    _previousSelectionRange = self.currentEditor.selectedRange;

    NSRange selection = self.currentEditor.selectedRange;
    NSInteger start = selection.location;
    NSInteger end = selection.location + selection.length;
    _onSelectionChange(@{
      @"selection": @{
        @"start": @(start),
        @"end": @(end),
      },
    });
  }
}

- (BOOL)canBecomeFirstResponder
{
  return _jsRequestingFirstResponder;
}

- (void)reactWillMakeFirstResponder
{
  _jsRequestingFirstResponder = YES;
}

- (void)reactDidMakeFirstResponder
{
  _jsRequestingFirstResponder = NO;
}

- (BOOL)resignFirstResponder
{
  BOOL result = [super resignFirstResponder];
  if (result)
  {
    [_eventDispatcher sendTextEventWithType:RCTTextEventTypeBlur
                                   reactTag:self.reactTag
                                       text:[self stringValue]
                                        key:nil
                                 eventCount:_nativeEventCount];
  }
  return result;
}

@end
