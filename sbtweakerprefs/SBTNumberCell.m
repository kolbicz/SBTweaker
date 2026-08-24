#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import "../SBTDefaults.h"

// SBTNumberCell — slider with an editable number field beside it.
// Specifier keys: key, defaults, min, max, default, isInteger (optional bool).
// Values persist straight to the tweak's defaults domain via CFPreferences;
// SpringBoard picks them up at the next respring.

#define kPrefsDomain SBTPreferencesDomain
#define sbc_default_values SBTDefaultValues

static id sbc_read_pref(NSString *key) {
    CFPreferencesAppSynchronize(kPrefsDomain);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kPrefsDomain));
}

static void sbc_write_pref(NSString *key, id value, BOOL sync) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, kPrefsDomain);
    if (sync) {
        CFPreferencesAppSynchronize(kPrefsDomain);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("cz.kolbi.sbtweaker/apply"),
                                             NULL, NULL, YES);
    }
}

@interface SBTNumberCell : PSTableCell <UITextFieldDelegate> {
    UISlider *_slider;
    UITextField *_field;
    NSString *_prefKey;
    double _min, _max;
    BOOL _isInteger;
}
@end

@implementation SBTNumberCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _prefKey = [specifier propertyForKey:@"key"];
        _min = [[specifier propertyForKey:@"min"] doubleValue];
        _max = [[specifier propertyForKey:@"max"] doubleValue];
        _isInteger = [[specifier propertyForKey:@"isInteger"] boolValue];
        NSNumber *defNum = [specifier propertyForKey:@"default"] ?: sbc_default_values()[_prefKey];

        _slider = [[UISlider alloc] init];
        _slider.minimumValue = (float)_min;
        _slider.maximumValue = (float)_max;
        _slider.continuous = YES;
        [_slider addTarget:self action:@selector(sliderChanged)
          forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(sliderFinished)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        _field = [[UITextField alloc] init];
        _field.borderStyle = UITextBorderStyleRoundedRect;
        _field.textAlignment = NSTextAlignmentCenter;
        _field.font = [UIFont systemFontOfSize:14.0];
        // NumberPad/DecimalPad have no minus sign; punctuation keyboard does.
        _field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        _field.delegate = self;

        id current = sbc_read_pref(_prefKey);
        [self setValue:current ? [current doubleValue] : [defNum doubleValue]];

        [self.contentView addSubview:_slider];
        [self.contentView addSubview:_field];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat fieldW = 72.0, pad = 12.0;
    CGFloat fieldX = b.size.width - fieldW - pad;
    _field.frame = CGRectMake(fieldX, (b.size.height - 30.0) / 2.0, fieldW, 30.0);

    CGFloat left = CGRectGetMaxX(self.textLabel.frame) + 8.0;
    CGFloat sliderW = fieldX - pad - left;
    if (sliderW < 40.0) sliderW = 40.0;
    _slider.frame = CGRectMake(left, 0.0, sliderW, b.size.height);
}

- (void)setValue:(double)v {
    if (_isInteger) v = round(v);
    v = MIN(_max, MAX(_min, v));
    _slider.value = (float)v;
    _field.text = _isInteger
        ? [NSString stringWithFormat:@"%d", (int)v]
        : [NSString stringWithFormat:@"%.2f", v];
}

// Re-read the stored value when the cell is (re)configured — keeps reused
// cells in sync after reloadSpecifiers (e.g. Reset to Defaults).
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    id current = sbc_read_pref(_prefKey);
    if (current) [self setValue:[current doubleValue]];
}

- (void)persist:(BOOL)sync {
    double v = (double)_slider.value;
    if (_isInteger) v = round(v);
    sbc_write_pref(_prefKey, _isInteger ? @((int)v) : @(v), sync);
}

- (void)sliderChanged {
    double v = (double)_slider.value;
    if (_isInteger) {
        v = round(v);
        _slider.value = (float)v; // snap
    }
    _field.text = _isInteger
        ? [NSString stringWithFormat:@"%d", (int)v]
        : [NSString stringWithFormat:@"%.2f", v];
    [self persist:NO];
}

- (void)sliderFinished {
    [self persist:YES];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [self setValue:[textField.text doubleValue]];
    [self persist:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
