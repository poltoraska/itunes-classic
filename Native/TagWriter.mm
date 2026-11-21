#import <Foundation/Foundation.h>
#include "fileref.h"
#include "tpropertymap.h"
#include "tvariant.h"
@interface ITTagWriter : NSObject
+ (BOOL)writeURL:(NSURL *)url values:(NSDictionary<NSString *,NSString *> *)values artwork:(NSData *)artwork error:(NSError **)error;
@end
@implementation ITTagWriter
+ (BOOL)writeURL:(NSURL *)url values:(NSDictionary<NSString *,NSString *> *)values artwork:(NSData *)artwork error:(NSError **)error {
  @try { try {
    TagLib::FileRef file(url.fileSystemRepresentation,false);
    if(file.isNull()) throw std::runtime_error("Формат не поддерживает запись тегов TagLib.");
    auto props=file.properties();
    for(NSString *key in values) { TagLib::String k(key.UTF8String,TagLib::String::UTF8); NSString *value=values[key]; if(value.length) props[k]=TagLib::StringList(TagLib::String(value.UTF8String,TagLib::String::UTF8)); else props.erase(k); }
    if(!file.setProperties(props).isEmpty()) throw std::runtime_error("Часть тегов не поддерживается этим форматом.");
    if(artwork) {
      TagLib::List<TagLib::VariantMap> pictures;
      if(artwork.length) { TagLib::VariantMap picture; picture["data"]=TagLib::ByteVector((const char *)artwork.bytes,(unsigned int)artwork.length); picture["pictureType"]=TagLib::String("Front Cover"); const unsigned char *b=(const unsigned char *)artwork.bytes; picture["mimeType"]=TagLib::String(artwork.length>3 && b[0]==0x89 ? "image/png" : "image/jpeg"); pictures.append(picture); }
      if(!file.setComplexProperties("PICTURE",pictures)) throw std::runtime_error("Запись обложки в этот формат не поддерживается.");
    }
    if(!file.save()) throw std::runtime_error("Не удалось сохранить теги в копию файла.");
    return YES;
  } catch(const std::exception &e) { if(error) *error=[NSError errorWithDomain:@"iTunes.Tags" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:e.what()]}]; return NO; } }
  @catch(NSException *e) { if(error) *error=[NSError errorWithDomain:@"iTunes.Tags" code:2 userInfo:@{NSLocalizedDescriptionKey:e.reason ?: @"Ошибка записи тегов"}]; return NO; }
}
@end
