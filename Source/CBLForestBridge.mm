//
//  CBLForestBridge.mm
//  CouchbaseLite
//
//  Created by Jens Alfke on 5/1/14.
//  Copyright (c) 2014-2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBLForestBridge.h"
extern "C" {
#import "ExceptionUtils.h"
#import "CBLSymmetricKey.h"
}


NSString* C4SliceToString(C4Slice s) {
    if (!s.buf)
        return nil;
    return [[NSString alloc] initWithBytes: s.buf length: s.size encoding:NSUTF8StringEncoding];
}


@implementation CBLForestBridge


+ (void) setEncryptionKey: (C4EncryptionKey*)fdbKey fromSymmetricKey: (CBLSymmetricKey*)key {
    if (key) {
        fdbKey->algorithm = kC4EncryptionAES256;
        Assert(key.keyData.length == sizeof(fdbKey->bytes));
        memcpy(fdbKey->bytes, key.keyData.bytes, sizeof(fdbKey->bytes));
    } else {
        fdbKey->algorithm = kC4EncryptionNone;
    }
}


+ (C4Database*) openDatabaseAtPath: (NSString*)path
                         withFlags: (C4DatabaseFlags)flags
                     encryptionKey: (CBLSymmetricKey*)key
                             error: (NSError**)outError
{
    C4EncryptionKey encKey;
    [self setEncryptionKey: &encKey fromSymmetricKey: key];
    C4Error c4err;
    auto db = c4db_open(stringToSlice(path), flags, &encKey, &c4err);
    if (!db)
        ErrorFromC4Error(c4err, outError);
    return db;
}


+ (CBL_MutableRevision*) revisionObjectFromForestDoc: (C4Document*)doc
                                               docID: (UU NSString*)docID
                                               revID: (UU NSString*)revID
                                            withBody: (BOOL)withBody
                                              status: (CBLStatus*)outStatus
{
    BOOL deleted = (doc->selectedRev.flags & kRevDeleted) != 0;
    if (revID == nil)
        revID = C4SliceToString(doc->selectedRev.revID);
    CBL_MutableRevision* result = [[CBL_MutableRevision alloc] initWithDocID: docID
                                                                       revID: revID
                                                                     deleted: deleted];
    result.sequence = doc->selectedRev.sequence;
    if (withBody) {
        *outStatus = [self loadBodyOfRevisionObject: result fromSelectedRevision: doc];
        if (CBLStatusIsError(*outStatus))
            result = nil;
    }
    return result;
}


+ (CBLStatus) loadBodyOfRevisionObject: (CBL_MutableRevision*)rev
                  fromSelectedRevision: (C4Document*)doc
{
    C4Error c4err;
    if (!c4doc_loadRevisionBody(doc, &c4err))
        return CBLStatusFromC4Error(c4err);
    rev.asJSON = C4SliceToData(doc->selectedRev.body);
    rev.sequence = doc->selectedRev.sequence;
    return kCBLStatusOK;
}


+ (NSMutableDictionary*) bodyOfNode: (const Revision*)rev {
    NSData* json = dataOfNode(rev);
    if (!json)
        return nil;
    NSMutableDictionary* properties = [CBLJSON JSONObjectWithData: json
                                                          options: NSJSONReadingMutableContainers
                                                            error: NULL];
    Assert(properties, @"Unable to parse doc from db: %@", json.my_UTF8ToString);
    NSString* revID = (NSString*)rev->revID;
    Assert(revID);

    const VersionedDocument* doc = (const VersionedDocument*)rev->owner;
    properties[@"_id"] = (NSString*)doc->docID();
    properties[@"_rev"] = revID;
    if (rev->isDeleted())
        properties[@"_deleted"] = $true;
    return properties;
}


+ (NSArray*) getCurrentRevisionIDs: (C4Document*)doc includeDeleted: (BOOL)includeDeleted {
    NSMutableArray* currentRevIDs = $marray();
    auto revs = doc.currentRevisions();
    for (auto rev = revs.begin(); rev != revs.end(); ++rev)
        if (includeDeleted || !(*rev)->isDeleted())
            [currentRevIDs addObject: (NSString*)(*rev)->revID];
    return currentRevIDs;
}


+ (NSArray*) mapHistoryOfNode: (const Revision*)rev
                      through: (id(^)(const Revision*, BOOL *stop))block
{
    NSMutableArray* history = $marray();
    BOOL stop = NO;
    for (; rev && !stop; rev = rev->parent())
        [history addObject: block(rev, &stop)];
    return history;
}


+ (NSArray*) getRevisionHistoryOfNode: (const cbforest::Revision*)revNode
                         backToRevIDs: (NSSet*)ancestorRevIDs
{
    const VersionedDocument* doc = (const VersionedDocument*)revNode->owner;
    NSString* docID = (NSString*)doc->docID();
    return [self mapHistoryOfNode: revNode
                          through: ^id(const Revision *ancestor, BOOL *stop)
    {
        CBL_MutableRevision* rev = [[CBL_MutableRevision alloc] initWithDocID: docID
                                                                revID: (NSString*)ancestor->revID
                                                              deleted: ancestor->isDeleted()];
        rev.missing = !ancestor->isBodyAvailable();
        if ([ancestorRevIDs containsObject: rev.revID])
            *stop = YES;
        return rev;
    }];
}


@end


namespace couchbase_lite {

    CBLStatus tryStatus(CBLStatus(^block)()) {
        try {
            return block();
        } catch (cbforest::error err) {
            return CBLStatusFromForestDBStatus(err.status);
        } catch (NSException* x) {
            MYReportException(x, @"CBL_ForestDBStorage");
            return kCBLStatusException;
        } catch (...) {
            Warn(@"Unknown C++ exception caught in CBL_ForestDBStorage");
            return kCBLStatusException;
        }
    }


    bool tryError(NSError** outError, void(^block)()) {
        CBLStatus status = tryStatus(^{
            block();
            return kCBLStatusOK;
        });
        return CBLStatusToOutNSError(status, outError);
    }


    CBLStatus CBLStatusFromForestDBStatus(int fdbStatus) {
        switch (fdbStatus) {
            case FDB_RESULT_SUCCESS:
                return kCBLStatusOK;
            case FDB_RESULT_KEY_NOT_FOUND:
            case FDB_RESULT_NO_SUCH_FILE:
                return kCBLStatusNotFound;
            case FDB_RESULT_RONLY_VIOLATION:
                return kCBLStatusForbidden;
            case FDB_RESULT_NO_DB_HEADERS:
            case FDB_RESULT_CRYPTO_ERROR:
                return kCBLStatusUnauthorized;     // assuming db is encrypted
            case FDB_RESULT_CHECKSUM_ERROR:
            case FDB_RESULT_FILE_CORRUPTION:
            case error::CorruptRevisionData:
                return kCBLStatusCorruptError;
            case error::BadRevisionID:
                return kCBLStatusBadID;
            default:
                return kCBLStatusDBError;
        }
    }

}
