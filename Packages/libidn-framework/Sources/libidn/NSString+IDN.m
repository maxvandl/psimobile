#import "NSString+IDN.h"

typedef struct { UTF32Char first, last; } Range;

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

// Таблицы RFC 3454.
static const Range kMappedToNothing[] = { // B.1
    {0x00AD, 0x00AD}, {0x034F, 0x034F}, {0x1806, 0x1806}, {0x180B, 0x180D}, {0x200B, 0x200D},
    {0x2060, 0x2060}, {0xFE00, 0xFE0F}, {0xFEFF, 0xFEFF},
};
static const Range kNonASCIISpace[] = { // C.1.2
    {0x00A0, 0x00A0}, {0x1680, 0x1680}, {0x2000, 0x200B}, {0x202F, 0x202F}, {0x205F, 0x205F}, {0x3000, 0x3000},
};
static const Range kASCIIControl[] = { {0x0000, 0x001F}, {0x007F, 0x007F} }; // C.2.1
static const Range kOtherProhibited[] = { // C.2.2, C.3, C.5–C.9 (C.4 проверяется отдельно)
    {0x0080, 0x009F}, {0x0340, 0x0341}, {0x06DD, 0x06DD}, {0x070F, 0x070F}, {0x180E, 0x180E},
    {0x200C, 0x200F}, {0x2028, 0x202E}, {0x2060, 0x2063}, {0x206A, 0x206F}, {0x2FF0, 0x2FFB},
    {0xD800, 0xF8FF}, {0xFDD0, 0xFDEF}, {0xFEFF, 0xFEFF}, {0xFFF9, 0xFFFD}, {0x1D173, 0x1D17A},
    {0xE0001, 0xE0001}, {0xE0020, 0xE007F}, {0xF0000, 0xFFFFD}, {0x100000, 0x10FFFD},
};
static const Range kNodeProhibited[] = { // C.1.1 и RFC 3920, A.5
    {0x0020, 0x0020}, {0x0022, 0x0022}, {0x0026, 0x0027}, {0x002F, 0x002F}, {0x003A, 0x003A}, {0x003C, 0x003C},
    {0x003E, 0x003E}, {0x0040, 0x0040},
};
static const Range kRandAL[] = { // D.1
    {0x05BE, 0x05BE}, {0x05C0, 0x05C0}, {0x05C3, 0x05C3}, {0x05D0, 0x05EA}, {0x05F0, 0x05F4},
    {0x061B, 0x061B}, {0x061F, 0x061F}, {0x0621, 0x063A}, {0x0640, 0x064A}, {0x066D, 0x066F},
    {0x0671, 0x06D5}, {0x06DD, 0x06DD}, {0x06E5, 0x06E6}, {0x06FA, 0x06FE}, {0x0700, 0x070D},
    {0x0710, 0x0710}, {0x0712, 0x072C}, {0x0780, 0x07A5}, {0x07B1, 0x07B1}, {0x200F, 0x200F},
    {0xFB1D, 0xFB1D}, {0xFB1F, 0xFB28}, {0xFB2A, 0xFB36}, {0xFB38, 0xFB3C}, {0xFB3E, 0xFB3E},
    {0xFB40, 0xFB41}, {0xFB43, 0xFB44}, {0xFB46, 0xFBB1}, {0xFBD3, 0xFD3D}, {0xFD50, 0xFD8F},
    {0xFD92, 0xFDC7}, {0xFDF0, 0xFDFC}, {0xFE70, 0xFE74}, {0xFE76, 0xFEFC},
};

static BOOL inRanges(UTF32Char c, const Range *ranges, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (c >= ranges[i].first && c <= ranges[i].last) return YES;
    }
    return NO;
}

typedef struct {
    BOOL caseFold;         // таблица B.2
    BOOL spaceToASCII;     // SASLprep: C.1.2 -> U+0020
    BOOL prohibitSpace;    // C.1.2
    BOOL prohibitControl;  // C.2.1
    BOOL prohibitNodeChars;
} Profile;

static NSData *codePoints(NSString *s) {
    return [s dataUsingEncoding:NSUTF32LittleEndianStringEncoding allowLossyConversion:NO];
}

static NSString *mapped(NSString *input, Profile p) {
    NSData *data = codePoints(input);
    if (!data) return nil;
    const UTF32Char *in = data.bytes;
    NSUInteger count = data.length / sizeof(UTF32Char);
    NSMutableData *out = [NSMutableData dataWithCapacity:data.length];
    const UTF32Char space = 0x20;
    for (NSUInteger i = 0; i < count; i++) {
        // U+200B есть в обеих таблицах: как и в libidn, для SASLprep это пробел, иначе изменится хеш пароля.
        if (p.spaceToASCII && inRanges(in[i], kNonASCIISpace, COUNT(kNonASCIISpace))) {
            [out appendBytes:&space length:sizeof(space)];
        } else if (!inRanges(in[i], kMappedToNothing, COUNT(kMappedToNothing))) {
            [out appendBytes:&in[i] length:sizeof(UTF32Char)];
        }
    }
    return [[NSString alloc] initWithData:out encoding:NSUTF32LittleEndianStringEncoding];
}

static BOOL isAllowed(NSString *s, Profile p) {
    NSData *data = codePoints(s);
    if (!data) return NO;
    const UTF32Char *cp = data.bytes;
    NSUInteger count = data.length / sizeof(UTF32Char);
    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    NSCharacterSet *marks = [NSCharacterSet nonBaseCharacterSet]; // в letterCharacterSet входят и они
    BOOL hasRandAL = NO, hasL = NO;
    for (NSUInteger i = 0; i < count; i++) {
        UTF32Char c = cp[i];
        if ((c & 0xFFFE) == 0xFFFE) return NO; // C.4: последние две точки каждой плоскости
        if (inRanges(c, kOtherProhibited, COUNT(kOtherProhibited))) return NO;
        if (p.prohibitSpace && inRanges(c, kNonASCIISpace, COUNT(kNonASCIISpace))) return NO;
        if (p.prohibitControl && inRanges(c, kASCIIControl, COUNT(kASCIIControl))) return NO;
        if (p.prohibitNodeChars && inRanges(c, kNodeProhibited, COUNT(kNodeProhibited))) return NO;
        if (inRanges(c, kRandAL, COUNT(kRandAL))) hasRandAL = YES;
        else if ([letters longCharacterIsMember:c] && ![marks longCharacterIsMember:c]) hasL = YES;
    }
    if (hasRandAL) { // RFC 3454, раздел 6
        if (hasL) return NO;
        if (!inRanges(cp[0], kRandAL, COUNT(kRandAL)) || !inRanges(cp[count - 1], kRandAL, COUNT(kRandAL))) return NO;
    }
    return YES;
}

static NSString *prep(NSString *input, Profile p) {
    static const NSUInteger maxBytes = 1023; // RFC 6122: часть JID не длиннее 1023 байт
    if (!input || [input lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > maxBytes) return nil;
    NSString *s = mapped(input, p);
    if (!s) return nil;
    if (p.caseFold) {
        s = [s stringByFoldingWithOptions:NSCaseInsensitiveSearch locale:nil];
        s = [s precomposedStringWithCompatibilityMapping];
        s = [s stringByFoldingWithOptions:NSCaseInsensitiveSearch locale:nil];
    }
    s = [s precomposedStringWithCompatibilityMapping];
    if (!isAllowed(s, p) || [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > maxBytes) return nil;
    return s;
}

@implementation NSString (IDN)

+ (NSString *)idn_prepNode:(NSString *)node {
    return prep(node, (Profile){.caseFold = YES, .prohibitSpace = YES, .prohibitControl = YES, .prohibitNodeChars = YES});
}

+ (NSString *)idn_prepDomain:(NSString *)domain {
    return prep(domain, (Profile){.caseFold = YES, .prohibitSpace = YES});
}

+ (NSString *)idn_prepResource:(NSString *)resource {
    return prep(resource, (Profile){.prohibitSpace = YES, .prohibitControl = YES});
}

+ (NSString *)idn_prepPassword:(NSString *)password {
    return prep(password, (Profile){.spaceToASCII = YES, .prohibitControl = YES});
}

@end
