/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "SNTMessageWindowController.h"

@import SecurityInterface.SFCertificatePanel;

#import "MOLCertificate.h"
#import "SNTBlockMessage.h"
#import "SNTConfigurator.h"
#import "SNTFileInfo.h"
#import "SNTMessageWindow.h"
#import "SNTStoredEvent.h"

@interface SNTMessageWindowController ()
///  The custom message to display for this event
@property(copy) NSString *customMessage;

///  A 'friendly' string representing the certificate information
@property(readonly, nonatomic) NSString *publisherInfo;

///  An optional message to display with this block.
@property(readonly, nonatomic) NSAttributedString *attributedCustomMessage;

///  Reference to the "Application Name" label in the XIB. Used to remove if application
///  doesn't have a CFBundleName.
@property(weak) IBOutlet NSTextField *applicationNameLabel;

///  Linked to checkbox in UI to prevent future notifications for this binary.
@property BOOL silenceFutureNotifications;
@end

@implementation SNTMessageWindowController

- (instancetype)initWithEvent:(SNTStoredEvent *)event andMessage:(NSString *)message {
  self = [super initWithWindowNibName:@"MessageWindow"];
  if (self) {
    _event = event;
    _customMessage = message;
    _progress = [NSProgress discreteProgressWithTotalUnitCount:1];
    [_progress addObserver:self
                forKeyPath:@"fractionCompleted"
                   options:NSKeyValueObservingOptionNew
                   context:NULL];
  }
  return self;
}

- (void)windowDidLoad {
  [self.window setFrame:NSMakeRect(self.window.frame.origin.x, self.window.frame.origin.y, 0, 0)
                display:NO];
  self.webView.frame = NSMakeRect(0, 0, 0, 0);
  self.webView.drawsBackground = NO;
  self.window.movableByWindowBackground = YES;
  self.webView.shouldCloseWithWindow = YES;
  
  // Turn off scrollbars in the frame
  [[[self.webView mainFrame] frameView] setAllowsScrolling:NO];
  
  // Load the page
  [self.webView.windowScriptObject setValue:self forKey:@"AppDelegate"];
  [self.mainWindow.contentView addSubview:_webView];
  [self.webView.mainFrame loadRequest:[self localHTMLForSanta]];
  self.webView.policyDelegate = self;
  self.webView.frameLoadDelegate = self;
  [NSApp activateIgnoringOtherApps:YES];
}

// Handles WebView and Message Resizing based on the HTML page
- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)webFrame {
  NSRect contentRect = [[[webFrame frameView] documentView] frame];
  NSRect windowFrame = NSMakeRect(self.window.frame.origin.x, self.window.frame.origin.y,
                                  contentRect.size.width, contentRect.size.height);
  
  [self.window setFrame:windowFrame display:YES];
  [self.window center];
  
  sender.frame = NSMakeRect(0, 0, contentRect.size.width, contentRect.size.height);
}

- (void)dealloc {
  [_progress removeObserver:self forKeyPath:@"fractionCompleted"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if ([keyPath isEqualToString:@"fractionCompleted"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSProgress *progress = object;
      if (progress.fractionCompleted != 0.0) {
        self.hashingIndicator.indeterminate = NO;
        self.foundFileCountLabel = nil;
      }
      self.hashingIndicator.doubleValue = progress.fractionCompleted;
    });
  } else if ([keyPath isEqualToString:@"self.event.fileBundleHash"]) {
    NSString *js = [NSString stringWithFormat:@"bundleHashChanged('%@');", self.event.fileBundleHash];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.webView.windowScriptObject evaluateWebScript:js];
    });
  }
}

- (NSString *)foundFileCountLabel {
  return nil;
}

// Handles string update when Bundle Hash is in progress
- (void)setFoundFileCountLabel:(NSString *)foundFileCountLabel {
  NSString *js = [NSString stringWithFormat:@"fileCountUpdateString('%@');", foundFileCountLabel];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.webView.windowScriptObject evaluateWebScript:js];
  });
}

- (void)loadWindow {
  [super loadWindow];
  [self.window setLevel:NSPopUpMenuWindowLevel];
  [self.window setMovableByWindowBackground:YES];

  if (![[SNTConfigurator configurator] eventDetailURL]) {
    [self.openEventButton removeFromSuperview];
  } else {
    NSString *eventDetailText = [[SNTConfigurator configurator] eventDetailText];
    if (eventDetailText) {
      [self.openEventButton setTitle:eventDetailText];
    }
  }

  if (!self.event.needsBundleHash) {
    [self.bundleHashLabel removeFromSuperview];
    [self.hashingIndicator removeFromSuperview];
    self.foundFileCountLabel = nil;
  } else {
    self.openEventButton.enabled = NO;
    self.hashingIndicator.indeterminate = YES;
    [self.hashingIndicator startAnimation:self];
    self.bundleHashLabel.hidden = YES;
    self.foundFileCountLabel = @"";
  }

  if (!self.event.fileBundleName) {
    [self.applicationNameLabel removeFromSuperview];
  }
}

- (void)closeWindow:(id)sender {
  [self.progress cancel];
  [(SNTMessageWindow *)self.window fadeOut:sender];
}

- (void)windowWillClose:(NSNotification *)notification {
  if (!self.delegate) return;
  if (self.silenceFutureNotifications) {
    [self.delegate windowDidCloseSilenceHash:self.event.fileSHA256];
  } else {
    [self.delegate windowDidCloseSilenceHash:nil];
  }
}

- (void)showCertInfo {
  // SFCertificatePanel expects an NSArray of SecCertificateRef's
  NSMutableArray *certArray = [NSMutableArray arrayWithCapacity:[self.event.signingChain count]];
  for (MOLCertificate *cert in self.event.signingChain) {
    [certArray addObject:(id)cert.certRef];
  }

  [[[SFCertificatePanel alloc] init] beginSheetForWindow:self.window
                                           modalDelegate:nil
                                          didEndSelector:nil
                                             contextInfo:nil
                                            certificates:certArray
                                               showGroup:YES];
}

- (void)openEventDetails:(id)sender {
  NSURL *url = [SNTBlockMessage eventDetailURLForEvent:self.event];
  [self closeWindow:sender];
  [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark Generated properties

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
  if (![key isEqualToString:@"event"]) {
    return [NSSet setWithObject:@"event"];
  } else {
    return [NSSet set];
  }
}

- (NSString *)publisherInfo {
  MOLCertificate *leafCert = [self.event.signingChain firstObject];

  if (leafCert.commonName && leafCert.orgName) {
    return [NSString stringWithFormat:@"%@ - %@", leafCert.orgName, leafCert.commonName];
  } else if (leafCert.commonName) {
    return leafCert.commonName;
  } else if (leafCert.orgName) {
    return leafCert.orgName;
  } else {
    return nil;
  }
}

- (NSString *)attributedCustomMessage {
  return [SNTBlockMessage blockMessageForGUI:self.event customMessage:self.customMessage];
}

// Loads local html file to be the WebView in the MessageWindow
- (NSURLRequest *)localHTMLForSanta {
  NSString *resources = [[NSBundle mainBundle] resourcePath];
  NSString *htmlPath = [resources stringByAppendingPathComponent:@"santa.html"];
  NSURLRequest *URL = [NSURLRequest requestWithURL:[NSURL fileURLWithPath:htmlPath]];
  return URL;
}

// Allows Javascript to only call the methods below
+ (BOOL)isSelectorExcludedFromWebScript:(SEL)selector {
  if (selector == @selector(santaData) ||
      selector == @selector(showCertInfo) ||
      selector == @selector(acceptFunction) ||
      selector == @selector(ignoreFunction:)) {
    return NO;
  }
  return YES;
}

// Data that is passed from Objective-C code to Javascript for parsing
- (NSString *)santaData {
  NSMutableDictionary *dataSet = [[NSMutableDictionary alloc] init];
  if (self.attributedCustomMessage) dataSet[@"message"] = self.attributedCustomMessage;
  if (self.event.fileBundleName) dataSet[@"application"] = self.event.fileBundleName;
  if (self.event.filePath) dataSet[@"path"] = self.event.filePath;
  if (self.event.filePath.lastPathComponent) {
    dataSet[@"filename"] = self.event.filePath.lastPathComponent;
  }
  if (self.publisherInfo) dataSet[@"publisher"] = self.publisherInfo;
  if (self.event.fileSHA256) dataSet[@"identifier"] = self.event.fileSHA256;
  if (self.event.needsBundleHash) dataSet[@"bundle identifier"] = @"";
  if (self.event.parentName) dataSet[@"parent"] = self.event.parentName;
  if (self.event.ppid) dataSet[@"ppid"] = self.event.ppid;
  if (self.event.executingUser) dataSet[@"user"] = self.event.executingUser;
  
  NSData *dataTransform = [NSJSONSerialization dataWithJSONObject:dataSet options:0 error:NULL];
  NSString *json = [[NSString alloc] initWithData:dataTransform encoding:NSUTF8StringEncoding];
  return json;
}

// Allows links in WebView to open in default Web browser instead of within the WebView
- (void)webView:(WebView *)webView
    decidePolicyForNavigationAction:(NSDictionary *)actionInformation
                            request:(NSURLRequest *)request
                              frame:(WebFrame *)frame
                   decisionListener:(id<WebPolicyDecisionListener>)listener {
  if ([request.URL.path isEqualToString:[[[self localHTMLForSanta] URL] absoluteString]]) {
    [listener use];
  } else {
    [listener ignore];
    [[NSWorkspace sharedWorkspace] openURL:request.URL];
  }
}

// Handles detection of notification silencing from the WebView to Santa
- (void)ignoreFunction:(BOOL)ignoreChecked {
  _silenceFutureNotifications = ignoreChecked;
  [self closeWindow:self];
}

- (void)acceptFunction{
  [self openEventDetails:self];
}

@end
