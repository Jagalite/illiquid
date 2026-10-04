// Finder's icvp background field uses a legacy Alias record, not a URL bookmark.
#include <CoreServices/CoreServices.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[2], "--resolve") == 0) {
        FILE *input = fopen(argv[1], "rb");
        if (!input) return 1;
        fseek(input, 0, SEEK_END);
        long length = ftell(input);
        rewind(input);
        CFMutableDataRef data = CFDataCreateMutable(NULL, length);
        CFDataSetLength(data, length);
        size_t read = fread(CFDataGetMutableBytePtr(data), 1, length, input);
        fclose(input);
        if (read != (size_t)length) { CFRelease(data); return 1; }
        Boolean stale = false;
        CFErrorRef error = NULL;
        CFURLRef url = CFURLCreateByResolvingBookmarkData(NULL, data,
            kCFURLBookmarkResolutionWithoutUIMask | kCFURLBookmarkResolutionWithoutMountingMask,
            NULL, NULL, &stale, &error);
        CFRelease(data);
        if (!url) { if (error) CFRelease(error); return 1; }
        UInt8 path[PATH_MAX];
        Boolean success = CFURLGetFileSystemRepresentation(url, true, path, sizeof(path));
        CFRelease(url);
        if (success) puts((const char *)path);
        return success ? 0 : 1;
    }
    if (argc == 3 && strcmp(argv[2], "--bookmark") == 0) {
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL,
            (const UInt8 *)argv[1], strlen(argv[1]), false);
        CFErrorRef error = NULL;
        CFDataRef data = CFURLCreateBookmarkData(NULL, url,
            kCFURLBookmarkCreationMinimalBookmarkMask, NULL, NULL, &error);
        CFRelease(url);
        if (!data) { if (error) CFRelease(error); return 1; }
        CFIndex length = CFDataGetLength(data);
        size_t written = fwrite(CFDataGetBytePtr(data), 1, (size_t)length, stdout);
        CFRelease(data);
        return written == (size_t)length ? 0 : 1;
    }
    if (argc != 2) return 2;
    FSRef file;
    OSStatus status = FSPathMakeRef((const UInt8 *)argv[1], &file, NULL);
    if (status != noErr) return 1;
    AliasHandle alias = NULL;
    status = FSNewAlias(NULL, &file, &alias);
    if (status != noErr) return 1;
    Size length = GetHandleSize((Handle)alias);
    size_t written = fwrite(*alias, 1, (size_t)length, stdout);
    DisposeHandle((Handle)alias);
    return written == (size_t)length ? 0 : 1;
}
