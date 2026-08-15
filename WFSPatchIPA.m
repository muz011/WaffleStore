#import "WFSPatchIPA.h"
#import <zlib.h>

typedef struct
{
	uint32_t crc;
	uint32_t compSize;
	uint32_t uncompSize;
	uint16_t method;
	uint16_t flags;
	uint16_t nameLen;
	uint16_t extraLen;
	uint16_t commentLen;
	uint32_t localOffset;
	uint16_t versionMadeBy;
	uint16_t versionNeeded;
	uint16_t modTime;
	uint16_t modDate;
	char* name;
	char* extra;
	char* comment;
} wfsZipEntry;

static uint16_t wfsLE16(const uint8_t* p)
{
	return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t wfsLE32(const uint8_t* p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void wfsPutLE16(uint8_t* p, uint16_t v)
{
	p[0] = v & 0xFF;
	p[1] = (v >> 8) & 0xFF;
}

static void wfsPutLE32(uint8_t* p, uint32_t v)
{
	p[0] = v & 0xFF;
	p[1] = (v >> 8) & 0xFF;
	p[2] = (v >> 16) & 0xFF;
	p[3] = (v >> 24) & 0xFF;
}

static BOOL wfsZipParse(const char* path, wfsZipEntry** outEntries, size_t* outCount, uint32_t* outCdOffset, uint32_t* outCdSize)
{
	FILE* f = fopen(path, "rb");
	if (!f)
	{
		return NO;
	}
	fseek(f, 0, SEEK_END);
	long fileSize = ftell(f);
	long scanLen = fileSize < 65557 ? fileSize : 65557;
	uint8_t* tail = malloc((size_t)scanLen);
	fseek(f, fileSize - scanLen, SEEK_SET);
	if (fread(tail, 1, (size_t)scanLen, f) != (size_t)scanLen)
	{
		free(tail);
		fclose(f);
		return NO;
	}
	long eocdPos = -1;
	for (long i = scanLen - 22; i >= 0; i--)
	{
		if (tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06)
		{
			eocdPos = i;
			break;
		}
	}
	if (eocdPos < 0)
	{
		free(tail);
		fclose(f);
		return NO;
	}
	const uint8_t* eocd = tail + eocdPos;
	uint32_t cdOffset = wfsLE32(eocd + 16);
	uint32_t cdSize = wfsLE32(eocd + 12);
	uint16_t totalEntries = wfsLE16(eocd + 10);
	free(tail);
	if (cdSize == 0 || totalEntries == 0)
	{
		fclose(f);
		return NO;
	}
	uint8_t* cd = malloc(cdSize);
	fseek(f, cdOffset, SEEK_SET);
	if (fread(cd, 1, cdSize, f) != cdSize)
	{
		free(cd);
		fclose(f);
		return NO;
	}
	fclose(f);
	wfsZipEntry* entries = calloc(totalEntries, sizeof(wfsZipEntry));
	size_t count = 0;
	size_t pos = 0;
	while (pos + 46 <= cdSize && count < totalEntries)
	{
		const uint8_t* p = cd + pos;
		if (wfsLE32(p) != 0x02014b50)
		{
			break;
		}
		wfsZipEntry* e = &entries[count];
		e->versionMadeBy = wfsLE16(p + 4);
		e->versionNeeded = wfsLE16(p + 6);
		e->flags = wfsLE16(p + 8);
		e->method = wfsLE16(p + 10);
		e->modTime = wfsLE16(p + 12);
		e->modDate = wfsLE16(p + 14);
		e->crc = wfsLE32(p + 16);
		e->compSize = wfsLE32(p + 20);
		e->uncompSize = wfsLE32(p + 24);
		e->nameLen = wfsLE16(p + 28);
		e->extraLen = wfsLE16(p + 30);
		e->commentLen = wfsLE16(p + 32);
		e->localOffset = wfsLE32(p + 42);
		uint32_t totalLen = 46 + e->nameLen + e->extraLen + e->commentLen;
		if (pos + totalLen > cdSize)
		{
			break;
		}
		e->name = malloc(e->nameLen + 1);
		memcpy(e->name, p + 46, e->nameLen);
		e->name[e->nameLen] = 0;
		if (e->extraLen)
		{
			e->extra = malloc(e->extraLen);
			memcpy(e->extra, p + 46 + e->nameLen, e->extraLen);
		}
		if (e->commentLen)
		{
			e->comment = malloc(e->commentLen);
			memcpy(e->comment, p + 46 + e->nameLen + e->extraLen, e->commentLen);
		}
		pos += totalLen;
		count++;
	}
	free(cd);
	*outEntries = entries;
	*outCount = count;
	*outCdOffset = cdOffset;
	*outCdSize = cdSize;
	return YES;
}

static void wfsZipEntriesFree(wfsZipEntry* entries, size_t count)
{
	if (!entries)
	{
		return;
	}
	for (size_t i = 0; i < count; i++)
	{
		free(entries[i].name);
		free(entries[i].extra);
		free(entries[i].comment);
	}
	free(entries);
}

static NSData* wfsEntryData(const char* path, const wfsZipEntry* e)
{
	if (!e)
	{
		return nil;
	}
	FILE* f = fopen(path, "rb");
	if (!f)
	{
		return nil;
	}
	fseek(f, e->localOffset, SEEK_SET);
	uint8_t lh[30];
	if (fread(lh, 1, 30, f) != 30)
	{
		fclose(f);
		return nil;
	}
	uint16_t nameLen = wfsLE16(lh + 26);
	uint16_t extraLen = wfsLE16(lh + 28);
	fseek(f, e->localOffset + 30 + nameLen + extraLen, SEEK_SET);
	uint8_t* comp = malloc(e->compSize ? e->compSize : 1);
	if (e->compSize && fread(comp, 1, e->compSize, f) != e->compSize)
	{
		free(comp);
		fclose(f);
		return nil;
	}
	fclose(f);
	NSData* result = nil;
	if (e->method == 0)
	{
		result = [NSData dataWithBytes:comp length:e->compSize];
	}
	else if (e->method == 8)
	{
		z_stream strm = {0};
		if (inflateInit2(&strm, -MAX_WBITS) != Z_OK)
		{
			free(comp);
			return nil;
		}
		NSMutableData* out = [NSMutableData dataWithLength:e->uncompSize];
		strm.next_in = comp;
		strm.avail_in = (uInt)e->compSize;
		strm.next_out = out.mutableBytes;
		strm.avail_out = (uInt)e->uncompSize;
		int rc = inflate(&strm, Z_FINISH);
		inflateEnd(&strm);
		if (rc == Z_STREAM_END || rc == Z_OK)
		{
			result = out;
		}
	}
	free(comp);
	return result;
}

static NSData* wfsSinfDataFromEntry(id sinfEntry)
{
	if ([sinfEntry isKindOfClass:[NSDictionary class]])
	{
		id data = ((NSDictionary*)sinfEntry)[@"sinf"];
		return [data isKindOfClass:[NSData class]] ? data : nil;
	}
	if ([sinfEntry isKindOfClass:[NSData class]])
	{
		return sinfEntry;
	}
	return nil;
}

BOOL WFSPatchIPAWithSinfData(NSString* ipaPath, NSDictionary* metadata, NSArray* sinfs, NSString* appleId, NSError** error)
{
	const char* path = ipaPath.fileSystemRepresentation;
	wfsZipEntry* entries = NULL;
	size_t count = 0;
	uint32_t cdOffset = 0;
	uint32_t cdSize = 0;
	if (!wfsZipParse(path, &entries, &count, &cdOffset, &cdSize))
	{
		if (error)
		{
			*error = [NSError errorWithDomain:@"WFSPatchIPAErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The downloaded file is not a valid zip archive."}];
		}
		return NO;
	}

	const wfsZipEntry* manifestEntry = NULL;
	const wfsZipEntry* infoEntry = NULL;
	NSString* bundleAppDir = nil;
	for (size_t i = 0; i < count; i++)
	{
		NSString* name = [NSString stringWithUTF8String:entries[i].name];
		if (!name.length)
		{
			continue;
		}
		if (!manifestEntry && [name hasSuffix:@".app/SC_Info/Manifest.plist"])
		{
			manifestEntry = &entries[i];
			bundleAppDir = [name stringByReplacingOccurrencesOfString:@"/SC_Info/Manifest.plist" withString:@""];
		}
		if (!infoEntry && [name hasSuffix:@".app/Info.plist"])
		{
			infoEntry = &entries[i];
		}
	}

	NSMutableArray* newEntries = [NSMutableArray array];

	if ([metadata isKindOfClass:[NSDictionary class]])
	{
		NSMutableDictionary* meta = [metadata mutableCopy];
		if (appleId.length)
		{
			meta[@"apple-id"] = appleId;
			meta[@"userName"] = appleId;
		}
		NSData* plistData = [NSPropertyListSerialization dataWithPropertyList:meta format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
		if (plistData.length)
		{
			[newEntries addObject:@{@"name": @"iTunesMetadata.plist", @"data": plistData}];
		}
	}

	NSArray* sinfPaths = nil;
	if (manifestEntry)
	{
		NSData* manifestData = wfsEntryData(path, manifestEntry);
		id manifestObj = [NSPropertyListSerialization propertyListWithData:manifestData options:0 format:NULL error:nil];
		if ([manifestObj isKindOfClass:[NSDictionary class]])
		{
			id rawPaths = ((NSDictionary*)manifestObj)[@"SinfPaths"];
			if ([rawPaths isKindOfClass:[NSArray class]])
			{
				sinfPaths = rawPaths;
			}
		}
	}

	NSArray* validSinfs = [sinfs isKindOfClass:[NSArray class]] ? sinfs : nil;
	if (sinfPaths.count && validSinfs.count && bundleAppDir.length)
	{
		NSUInteger pairs = MIN(sinfPaths.count, validSinfs.count);
		for (NSUInteger i = 0; i < pairs; i++)
		{
			NSString* sinfPath = sinfPaths[i];
			if (![sinfPath isKindOfClass:[NSString class]] || !sinfPath.length)
			{
				continue;
			}
			NSData* sinfData = wfsSinfDataFromEntry(validSinfs[i]);
			if (!sinfData.length)
			{
				continue;
			}
			NSString* entryName = [NSString stringWithFormat:@"%@/%@", bundleAppDir, sinfPath];
			[newEntries addObject:@{@"name": entryName, @"data": sinfData}];
		}
	}
	else if (validSinfs.count && bundleAppDir.length)
	{
		NSString* executable = nil;
		if (infoEntry)
		{
			NSData* infoData = wfsEntryData(path, infoEntry);
			id infoObj = [NSPropertyListSerialization propertyListWithData:infoData options:0 format:NULL error:nil];
			if ([infoObj isKindOfClass:[NSDictionary class]])
			{
				id rawExe = ((NSDictionary*)infoObj)[@"CFBundleExecutable"];
				if ([rawExe isKindOfClass:[NSString class]])
				{
					executable = rawExe;
				}
			}
		}
		if (!executable.length)
		{
			executable = [bundleAppDir stringByDeletingPathExtension].lastPathComponent;
		}
		if (executable.length)
		{
			NSData* sinfData = wfsSinfDataFromEntry(validSinfs[0]);
			if (sinfData.length)
			{
				NSString* entryName = [NSString stringWithFormat:@"%@/SC_Info/%@.sinf", bundleAppDir, executable];
				[newEntries addObject:@{@"name": entryName, @"data": sinfData}];
			}
		}
	}

	if (!newEntries.count)
	{
		wfsZipEntriesFree(entries, count);
		if (error)
		{
			*error = [NSError errorWithDomain:@"WFSPatchIPAErrorDomain" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No SINF data or metadata available to patch the archive."}];
		}
		return NO;
	}

	for (NSDictionary* newEntry in newEntries)
	{
		NSString* newName = newEntry[@"name"];
		for (size_t i = 0; i < count; i++)
		{
			NSString* existingName = [NSString stringWithUTF8String:entries[i].name];
			if ([existingName isEqualToString:newName])
			{
				wfsZipEntriesFree(entries, count);
				if (error)
				{
					*error = [NSError errorWithDomain:@"WFSPatchIPAErrorDomain" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Entry %@ already exists in the archive.", newName]}];
				}
				return NO;
			}
		}
	}

	NSString* tmpPath = [ipaPath stringByAppendingString:@".wfs.tmp"];
	FILE* src = fopen(path, "rb");
	FILE* dst = fopen(tmpPath.fileSystemRepresentation, "wb");
	if (!src || !dst)
	{
		if (src) fclose(src);
		if (dst) fclose(dst);
		[[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
		wfsZipEntriesFree(entries, count);
		if (error)
		{
			*error = [NSError errorWithDomain:@"WFSPatchIPAErrorDomain" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Could not create the patched archive."}];
		}
		return NO;
	}

	uint8_t buf[65536];
	long remaining = (long)cdOffset;
	while (remaining > 0)
	{
		size_t n = (size_t)MIN(remaining, (long)sizeof(buf));
		size_t read = fread(buf, 1, n, src);
		if (read == 0)
		{
			break;
		}
		fwrite(buf, 1, read, dst);
		remaining -= (long)read;
	}
	fclose(src);

	uint32_t* newOffsets = calloc(newEntries.count, sizeof(uint32_t));
	for (NSUInteger i = 0; i < newEntries.count; i++)
	{
		NSDictionary* newEntry = newEntries[i];
		NSString* newName = newEntry[@"name"];
		NSData* newData = newEntry[@"data"];
		const uint8_t* nameBytes = (const uint8_t*)newName.UTF8String;
		uint16_t nameLen = (uint16_t)MIN(newName.length, 65535);
		uint32_t crc = crc32(0L, Z_NULL, 0);
		crc = crc32(crc, newData.bytes, (uInt)newData.length);
		newOffsets[i] = (uint32_t)ftell(dst);
		uint8_t lh[30];
		wfsPutLE32(lh, 0x04034b50);
		wfsPutLE16(lh + 4, 20);
		wfsPutLE16(lh + 6, 0);
		wfsPutLE16(lh + 8, 0);
		wfsPutLE16(lh + 10, 0x0021);
		wfsPutLE16(lh + 12, 0x5821);
		wfsPutLE32(lh + 14, crc);
		wfsPutLE32(lh + 18, (uint32_t)newData.length);
		wfsPutLE32(lh + 22, (uint32_t)newData.length);
		wfsPutLE16(lh + 26, nameLen);
		wfsPutLE16(lh + 28, 0);
		fwrite(lh, 1, 30, dst);
		fwrite(nameBytes, 1, nameLen, dst);
		fwrite(newData.bytes, 1, newData.length, dst);
	}

	uint32_t newCdOffset = (uint32_t)ftell(dst);

	for (size_t i = 0; i < count; i++)
	{
		const wfsZipEntry* e = &entries[i];
		uint8_t ce[46];
		wfsPutLE32(ce, 0x02014b50);
		wfsPutLE16(ce + 4, e->versionMadeBy);
		wfsPutLE16(ce + 6, e->versionNeeded);
		wfsPutLE16(ce + 8, e->flags);
		wfsPutLE16(ce + 10, e->method);
		wfsPutLE16(ce + 12, e->modTime);
		wfsPutLE16(ce + 14, e->modDate);
		wfsPutLE32(ce + 16, e->crc);
		wfsPutLE32(ce + 20, e->compSize);
		wfsPutLE32(ce + 24, e->uncompSize);
		wfsPutLE16(ce + 28, e->nameLen);
		wfsPutLE16(ce + 30, e->extraLen);
		wfsPutLE16(ce + 32, e->commentLen);
		wfsPutLE16(ce + 34, 0);
		wfsPutLE16(ce + 36, 0);
		wfsPutLE32(ce + 38, 0);
		wfsPutLE32(ce + 42, e->localOffset);
		fwrite(ce, 1, 46, dst);
		fwrite(e->name, 1, e->nameLen, dst);
		if (e->extraLen)
		{
			fwrite(e->extra, 1, e->extraLen, dst);
		}
		if (e->commentLen)
		{
			fwrite(e->comment, 1, e->commentLen, dst);
		}
	}

	for (NSUInteger i = 0; i < newEntries.count; i++)
	{
		NSDictionary* newEntry = newEntries[i];
		NSString* newName = newEntry[@"name"];
		NSData* newData = newEntry[@"data"];
		const uint8_t* nameBytes = (const uint8_t*)newName.UTF8String;
		uint16_t nameLen = (uint16_t)MIN(newName.length, 65535);
		uint32_t crc = crc32(0L, Z_NULL, 0);
		crc = crc32(crc, newData.bytes, (uInt)newData.length);
		uint8_t ce[46];
		wfsPutLE32(ce, 0x02014b50);
		wfsPutLE16(ce + 4, 20);
		wfsPutLE16(ce + 6, 20);
		wfsPutLE16(ce + 8, 0);
		wfsPutLE16(ce + 10, 0);
		wfsPutLE16(ce + 12, 0x0021);
		wfsPutLE16(ce + 14, 0x5821);
		wfsPutLE32(ce + 16, crc);
		wfsPutLE32(ce + 20, (uint32_t)newData.length);
		wfsPutLE32(ce + 24, (uint32_t)newData.length);
		wfsPutLE16(ce + 28, nameLen);
		wfsPutLE16(ce + 30, 0);
		wfsPutLE16(ce + 32, 0);
		wfsPutLE16(ce + 34, 0);
		wfsPutLE16(ce + 36, 0);
		wfsPutLE32(ce + 38, 0);
		wfsPutLE32(ce + 42, newOffsets[i]);
		fwrite(ce, 1, 46, dst);
		fwrite(nameBytes, 1, nameLen, dst);
	}
	free(newOffsets);

	uint32_t newCdSize = (uint32_t)(ftell(dst) - newCdOffset);
	uint16_t totalEntries = (uint16_t)(count + newEntries.count);
	uint8_t eocd[22];
	wfsPutLE32(eocd, 0x06054b50);
	wfsPutLE16(eocd + 4, 0);
	wfsPutLE16(eocd + 6, 0);
	wfsPutLE16(eocd + 8, totalEntries);
	wfsPutLE16(eocd + 10, totalEntries);
	wfsPutLE32(eocd + 12, newCdSize);
	wfsPutLE32(eocd + 16, newCdOffset);
	wfsPutLE16(eocd + 20, 0);
	fwrite(eocd, 1, 22, dst);
	fclose(dst);

	wfsZipEntriesFree(entries, count);

	NSFileManager* fm = [NSFileManager defaultManager];
	NSError* moveError = nil;
	[fm removeItemAtPath:ipaPath error:nil];
	if (![fm moveItemAtPath:tmpPath toPath:ipaPath error:&moveError])
	{
		[fm removeItemAtPath:tmpPath error:nil];
		if (error)
		{
			*error = moveError ?: [NSError errorWithDomain:@"WFSPatchIPAErrorDomain" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Failed to replace the downloaded archive."}];
		}
		return NO;
	}
	return YES;
}