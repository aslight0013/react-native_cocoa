/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTTextField.h"

#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTUtils.h>
#import <React/UIView+React.h>

#import "RCTTextSelection.h"

@interface RCTTextField()

- (BOOL)shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string;
- (BOOL)keyboardInputShouldDelete;
- (BOOL)textFieldShouldEndEditing;

@end

@interface RCTTextFieldDelegateProxy: NSObject <UITextFieldDelegate>
@end

@implementation RCTTextFieldDelegateProxy

- (BOOL)textField:(RCTTextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
  return [textField shouldChangeCharactersInRange:range replacementString:string];
}

- (BOOL)keyboardInputShouldDelete:(RCTTextField *)textField
{
  return [textField keyboardInputShouldDelete];
}

- (BOOL)textFieldShouldEndEditing:(RCTTextField *)textField {
  return [textField textFieldShouldEndEditing];
}

@end

@implementation RCTTextField
{
  RCTEventDispatcher *_eventDispatcher;
  NSInteger _nativeEventCount;
  NSString * _placeholderString;
  BOOL _submitted;
  UITextRange *_previousSelectionRange;
  BOOL _textWasPasted;
  NSString *_finalText;
  RCTTextFieldDelegateProxy *_delegateProxy;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
  if ((self = [super initWithFrame:CGRectZero])) {
    RCTAssert(eventDispatcher, @"eventDispatcher is a required parameter");
    self.delegate = self;
    self.drawsBackground = NO;
    self.bordered = NO;
    self.bezeled = YES;

    _eventDispatcher = eventDispatcher;
    [self addTarget:self action:@selector(textFieldDidChange) forControlEvents:UIControlEventEditingChanged];
    [self addTarget:self action:@selector(textFieldBeginEditing) forControlEvents:UIControlEventEditingDidBegin];
    [self addTarget:self action:@selector(textFieldEndEditing) forControlEvents:UIControlEventEditingDidEnd];
    [self addTarget:self action:@selector(textFieldSubmitEditing) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self addObserver:self forKeyPath:@"selectedTextRange" options:0 context:nil];
    _blurOnSubmit = YES;

    // We cannot use `self.delegate = self;` here because `UITextField` implements some of these delegate methods itself,
    // so if we implement this delegate on self, we will override some of its behaviours.
    _delegateProxy = [RCTTextFieldDelegateProxy new];
    self.delegate = _delegateProxy;
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
  [[super currentEditor] paste:sender];
}

- (void)setSelection:(RCTTextSelection *)selection
{
  if (!selection) {
    return;
  }

  UITextRange *currentSelection = self.selectedTextRange;
  UITextPosition *start = [self positionFromPosition:self.beginningOfDocument offset:selection.start];
  UITextPosition *end = [self positionFromPosition:self.beginningOfDocument offset:selection.end];
  UITextRange *selectedTextRange = [self textRangeFromPosition:start toPosition:end];

  NSInteger eventLag = _nativeEventCount - _mostRecentEventCount;
  if (eventLag == 0 && ![currentSelection isEqual:selectedTextRange]) {
    _previousSelectionRange = selectedTextRange;
    self.selectedTextRange = selectedTextRange;
  } else if (eventLag > RCTTextUpdateLagWarningThreshold) {
    RCTLogWarn(@"Native TextInput(%@) is %zd events ahead of JS - try to make your JS faster.", self.text, eventLag);
  }
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
    [self updatePlaceholder];
  }
}

- (void)updatePlaceholder
{
  if (_placeholderTextColor && _placeholderString) {
    NSAttributedString *attrString = [[NSAttributedString alloc]
                                      initWithString:_placeholderString attributes: @{
                                        NSForegroundColorAttributeName: _placeholderTextColor,
                                        NSFontAttributeName: [self font]
                                      }];
    [self setPlaceholderAttributedString:attrString];
  }
}

- (void)setPlaceholder:(NSString *)placeholder
{
  if (placeholder != nil && ![_placeholderString isEqual:placeholder]) {
    _placeholderString = placeholder;
    [self updatePlaceholder];
  }
}

- (void)setBackgroundColor:(NSColor *)backgroundColor
{
  if (backgroundColor) {
    [self setDrawsBackground:YES];
    [self.cell setBackgroundColor:backgroundColor];
  }
}

- (void)textDidChange:(NSNotification *)aNotification
{
  CGRect rect = [super textRectForBounds:bounds];
  return UIEdgeInsetsInsetRect(rect, _contentInset);
}

- (CGRect)editingRectForBounds:(CGRect)bounds
{
  return [self textRectForBounds:bounds];
}

- (void)textFieldDidChange
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
  if (![_finalText isEqualToString:self.text]) {
    _finalText = nil;
    // iOS does't send event `UIControlEventEditingChanged` if the change was happened because of autocorrection
    // which was triggered by loosing focus. We assume that if `text` was changed in the middle of loosing focus process,
    // we did not receive that event. So, we call `textFieldDidChange` manually.
    [self textFieldDidChange];
  }

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
                                      key:key
                               eventCount:_nativeEventCount];
}

- (void)textDidBeginEditing:(NSNotification *)aNotification
{
  [_eventDispatcher sendTextEventWithType:RCTTextEventTypeFocus
                                 reactTag:self.reactTag
                                     text:[self stringValue]
                                      key:nil
                               eventCount:_nativeEventCount];

  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_selectTextOnFocus) {
      [self selectAll:nil];
    }

    [self sendSelectionEvent];
  });
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
