#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Stringprep (RFC 3454) для XMPP: профили Nodeprep, Nameprep, Resourceprep (RFC 3920) и SASLprep (RFC 4013).
/// Возвращает nil, если строка запрещена профилем или длиннее 1023 байт UTF-8.
@interface NSString (IDN)

+ (nullable NSString *)idn_prepNode:(NSString *)node;
+ (nullable NSString *)idn_prepDomain:(NSString *)domain;
+ (nullable NSString *)idn_prepResource:(NSString *)resource;
+ (nullable NSString *)idn_prepPassword:(NSString *)password;

@end

NS_ASSUME_NONNULL_END
