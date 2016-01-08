//
//  CBL_ForestDBStorage.mm
//  CouchbaseLite
//
//  Created by Jens Alfke on 1/13/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

extern "C" {
#import "CBL_ForestDBStorage.h"
#import "CBL_ForestDBViewStorage.h"
#import "CBLForestBridge.h"
#import "CouchbaseLitePrivate.h"
#import "CBLInternal.h"
#import "CBL_BlobStore.h"
#import "CBL_Attachment.h"
#import "CBLBase64.h"
#import "CBLMisc.h"
#import "CBLSymmetricKey.h"
#import "ExceptionUtils.h"
#import "MYAction.h"
#import "MYBackgroundMonitor.h"

#import "c4DocEnumerator.h"
}


#define kDBFilename @"db.forest"

// Size of ForestDB buffer cache allocated for a database
#define kDBBufferCacheSize (8*1024*1024)

// ForestDB Write-Ahead Log size (# of records)
#define kDBWALThreshold 1024

// How often ForestDB should check whether databases need auto-compaction
#define kAutoCompactInterval (15.0)

// Percentage of wasted space in db file that triggers auto-compaction
#define kCompactionThreshold 70

#define kDefaultMaxRevTreeDepth 20


@implementation CBL_ForestDBStorage
{
    @private
    NSString* _directory;
    BOOL _readOnly;
    C4Database* _forest;
    NSMapTable* _views;
}

@synthesize delegate=_delegate, directory=_directory, autoCompact=_autoCompact;
@synthesize maxRevTreeDepth=_maxRevTreeDepth, encryptionKey=_encryptionKey;


static void FDBLogCallback(C4LogLevel level, C4Slice message) {
    switch (level) {
        case kC4LogDebug:
            LogTo(CBLDatabaseVerbose, @"ForestDB: %.*s", (int)message.size, message.buf);
            break;
        case kC4LogInfo:
            LogTo(CBLDatabase, @"ForestDB: %.*s", (int)message.size, message.buf);
            break;
        case kC4LogWarning:
            Warn(@"%.*s", (int)message.size, message.buf);
            break;
        case kC4LogError:
            Warn(@"ForestDB error: %.*s", (int)message.size, message.buf);
            break;
        default:
            break;
    }
}


#ifdef TARGET_OS_IPHONE
static MYBackgroundMonitor *bgMonitor;
#endif


static void onCompactCallback(C4Database *db, bool compacting) {
    const char *what = (compacting ?"starting" :"finished");
    NSString* path = [[NSString alloc] initWithCString: db->filename().c_str()
                                              encoding: NSUTF8StringEncoding];
    NSString* viewName = path.lastPathComponent;
    path = path.stringByDeletingLastPathComponent;
    NSString* dbName = path.lastPathComponent.stringByDeletingPathExtension;
    if ([viewName isEqualToString: kDBFilename]) {
        Log(@"Database '%@' %s compaction", dbName, what);
    } else {
        dbName = [dbName stringByAppendingPathComponent: viewName];
        Log(@"View index '%@/%@' %s compaction",
            dbName, viewName.stringByDeletingPathExtension, what);
    }
}


+ (void) initialize {
    if (self == [CBL_ForestDBStorage class]) {
        Log(@"Initializing ForestDB");
        C4LogLevel logLevel = kC4LogWarning;
        if (WillLogTo(CBLDatabaseVerbose))
            logLevel = kC4LogDebug;
        else if (WillLogTo(CBLDatabase))
            logLevel = kC4LogInfo;
        c4log_register(logLevel, FDBLogCallback);

//TODO        Database::onCompactCallback = onCompactCallback;

#if TARGET_OS_IPHONE
        bgMonitor = [[MYBackgroundMonitor alloc] init];
        bgMonitor.onAppBackgrounding = ^{
            if ([self checkStillCompacting])
                [bgMonitor beginBackgroundTaskNamed: @"Database compaction"];
        };
        bgMonitor.onAppForegrounding = ^{
            [self cancelPreviousPerformRequestsWithTarget: self
                                                 selector: @selector(checkStillCompacting)
                                                   object: nil];
        };
#endif
    }
}


#if TARGET_OS_IPHONE
+ (BOOL) checkStillCompacting {
    if (Database::isAnyCompacting()) {
        Log(@"Database still compacting; delaying app suspend...");
        [self performSelector: @selector(checkStillCompacting) withObject: nil afterDelay: 0.5];
        return YES;
    } else {
        if (bgMonitor.hasBackgroundTask) {
            Log(@"Database finished compacting; allowing app to suspend.");
            [bgMonitor endBackgroundTask];
        }
        return NO;
    }
}
#endif


- (instancetype) init {
    self = [super init];
    if (self) {
        _autoCompact = YES;
        _maxRevTreeDepth = kDefaultMaxRevTreeDepth;
    }
    return self;
}


- (NSString*) description {
    return [NSString stringWithFormat: @"%@[%@]", self.class, _directory];
}


- (BOOL) databaseExistsIn: (NSString*)directory {
    NSString* dbPath = [directory stringByAppendingPathComponent: kDBFilename];
    if ([[NSFileManager defaultManager] fileExistsAtPath: dbPath isDirectory: NULL])
        return YES;
    // If "db.forest" doesn't exist (auto-compaction will add numeric suffixes), check for meta:
    dbPath = [dbPath stringByAppendingString: @".meta"];
    return [[NSFileManager defaultManager] fileExistsAtPath: dbPath isDirectory: NULL];
}


- (BOOL)openInDirectory: (NSString *)directory
               readOnly: (BOOL)readOnly
                manager: (CBLManager*)manager
                  error: (NSError**)outError
{
    _directory = [directory copy];
    _readOnly = readOnly;
    return [self reopen: outError];
}


- (BOOL) reopen: (NSError**)outError {
    if (_encryptionKey)
        LogTo(CBLDatabase, @"Database is encrypted; setting CBForest encryption key");
    NSString* forestPath = [_directory stringByAppendingPathComponent: kDBFilename];
    C4DatabaseFlags flags = _readOnly ? kC4DB_ReadOnly : kC4DB_Create;
    if (_autoCompact)
        flags |= kC4DB_AutoCompact;

    _forest = [CBLForestBridge openDatabaseAtPath: forestPath withFlags: flags
                                    encryptionKey: _encryptionKey error: outError];
    return (_forest != nil);
}


- (void) close {
    c4db_close(_forest, NULL);
    _forest = NULL;
}


- (MYAction*) actionToChangeEncryptionKey: (CBLSymmetricKey*)newKey {
    MYAction* action = [MYAction new];

    // Re-key the views!
    NSArray* viewNames = self.allViewNames;
    for (NSString* viewName in viewNames) {
        CBL_ForestDBViewStorage* viewStorage = [self viewStorageNamed: viewName create: YES];
        [action addAction: [viewStorage actionToChangeEncryptionKey]];
    }

    // Re-key the database:
    CBLSymmetricKey* oldKey = _encryptionKey;
    [action addPerform: ^BOOL(NSError **outError) {
        C4EncryptionKey enc;
        [CBLForestBridge setEncryptionKey: &enc fromSymmetricKey: newKey];
        C4Error c4Err;
        if (!c4db_rekey(_forest, &enc, &c4Err))
            return ErrorFromC4Error(c4Err, outError);
        self.encryptionKey = newKey;
        return YES;
    } backOut:^BOOL(NSError **outError) {
        C4EncryptionKey enc;
        [CBLForestBridge setEncryptionKey: &enc fromSymmetricKey: newKey];
        //FIX: This can potentially fail. If it did, the database would be lost.
        // It would be safer to save & restore the old db file, the one that got replaced
        // during rekeying, but the ForestDB API doesn't allow preserving it...
        c4db_rekey(_forest, &enc, NULL);
        self.encryptionKey = oldKey;
        return YES;
    } cleanUp: nil];

    return action;
}


- (void*) forestDatabase {
    return _forest;
}


- (NSUInteger) documentCount {
    return c4db_getDocumentCount(_forest);
}


- (SequenceNumber) lastSequence {
    return c4db_getLastSequence(_forest);
}


- (BOOL) compact: (NSError**)outError {
    C4Error c4Err;
    return c4db_compact(_forest, &c4Err) || ErrorFromC4Error(c4Err, outError);
}


- (CBLStatus) inTransaction: (CBLStatus(^)())block {
    if (c4db_isInTransaction(_forest)) {
        return block();
    } else {
        LogTo(CBLDatabase, @"BEGIN transaction...");
        C4Error c4Err;
        if (!c4db_beginTransaction(_forest, &c4Err))
            return CBLStatusFromC4Error(c4Err);
        CBLStatus status = block();
        BOOL commit = !CBLStatusIsError(status);
        LogTo(CBLDatabase, @"END transaction...");
        if (!c4db_endTransaction(_forest, commit, &c4Err) && commit) {
            status = CBLStatusFromC4Error(c4Err);
            commit = NO;
        }
        [_delegate storageExitedTransaction: commit];
        return status;
    }
}

- (BOOL) inTransaction {
    return _forest && c4db_isInTransaction(_forest);
}


#pragma mark - DOCUMENTS:


- (CBLStatus) _withVersionedDoc: (UU NSString*)docID
                      mustExist: (BOOL)mustExist
                             do: (CBLStatus(^)(C4Document*))block
{
    __block C4Document* doc = NULL;
    __block C4Error c4err;
    CBLWithStringBytes(docID, ^(const char *docIDBuf, size_t docIDSize) {
        doc = c4doc_get(_forest, {docIDBuf, docIDSize}, mustExist, &c4err);
    });
    if (!doc)
        return CBLStatusFromC4Error(c4err);
    CBLStatus status = block(doc);
    c4doc_free(doc);
    return status;
}


static CBLStatus selectRev(C4Document* doc, NSString* revID, BOOL withBody) {
    __block CBLStatus status = kCBLStatusOK;
    if (revID) {
        CBLWithStringBytes(revID, ^(const char *buf, size_t size) {
            C4Error c4err;
            if (!c4doc_selectRevision(doc, {buf, size}, withBody, &c4err))
                status = CBLStatusFromC4Error(c4Err);
        });
    } else {
        if (!c4doc_selectCurrentRevision(doc))
            status = kCBLStatusDeleted;
    }
    return status;
}


- (CBL_MutableRevision*) getDocumentWithID: (NSString*)docID
                                revisionID: (NSString*)inRevID
                                  withBody: (BOOL)withBody
                                    status: (CBLStatus*)outStatus
{
    __block CBL_MutableRevision* result = nil;
    *outStatus = [self _withVersionedDoc: docID mustExist: YES do: ^(C4Document* doc) {
#if DEBUG
        LogTo(CBLDatabase, @"Read %@ rev %@", docID, inRevID);
#endif
        CBLStatus status = selectRev(doc, inRevID, withBody);
        if (!CBLStatusIsError(status)) {
            if (!inRevID && (doc->selectedRev.flags & kRevDeleted))
                status = kCBLStatusDeleted;
            else
                result = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                                docID: docID revID: inRevID
                                                             withBody: withBody status: &status];
        }
        return status;
    }];
    return result;
}


- (NSDictionary*) getBodyWithID: (NSString*)docID
                       sequence: (SequenceNumber)sequence
                         status: (CBLStatus*)outStatus
{
    __block NSDictionary* result = nil;
    *outStatus = [self _withVersionedDoc: docID mustExist: YES do: ^(C4Document* doc) {
#if DEBUG
        LogTo(CBLDatabase, @"Read %@ seq %lld", docID, sequence);
#endif
        do {
            if (doc->selectedRev.sequence == (C4SequenceNumber)sequence) {
                NSMutableDictionary* result = [CBLForestBridge bodyOfSelectedRevision: doc];
                return result ? kCBLStatusOK : kCBLStatusNotFound;
            }
        } while (c4doc_selectNextRevision(doc));
        return kCBLStatusNotFound;
    }];
    return result;
}


- (CBLStatus) loadRevisionBody: (CBL_MutableRevision*)rev {
    return [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        CBLStatus status = selectRev(doc, rev.revID, YES);
        if (CBLStatusIsError(status))
            return status;
        return [CBLForestBridge loadBodyOfRevisionObject: rev fromSelectedRevision: doc];
    }];
}


- (SequenceNumber) getRevisionSequence: (CBL_Revision*)rev {
    __block SequenceNumber sequence = 0;
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        CBLStatus status = selectRev(doc, rev.revID, YES);
        if (!CBLStatusIsError(status))
            sequence = doc->selectedRev.sequence;
        return kCBLStatusOK;
    }];
    return sequence;
}


#pragma mark - HISTORY:


- (CBL_Revision*) getParentRevision: (CBL_Revision*)rev {
    if (!rev.docID || !rev.revID)
        return nil;
    __block CBL_Revision* parent = nil;
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        CBLStatus status = selectRev(doc, rev.revID, YES);
        if (CBLStatusIsError(status))
            return status;
        if (!c4doc_selectParentRevision(doc))
            return kCBLStatusNotFound;
        parent = [CBLForestBridge revisionObjectFromForestDoc: doc docID: rev.docID revID: nil
                                                     withBody: YES status: &status];
        return status;
    }];
    return parent;
}


- (CBL_RevisionList*) getAllRevisionsOfDocumentID: (NSString*)docID
                                      onlyCurrent: (BOOL)onlyCurrent
{
    __block CBL_RevisionList* revs = nil;
    [self _withVersionedDoc: docID mustExist: YES do: ^(C4Document* doc) {
        revs = [[CBL_RevisionList alloc] init];
        do {
            if (onlyCurrent && !(doc->selectedRev.flags & kRevLeaf))
                continue;
            CBLStatus status;
            CBL_Revision *rev = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                                       docID: docID
                                                                       revID: nil
                                                                    withBody: NO
                                                                      status: &status];
            if (rev)
                [revs addRev: rev];
        } while (c4doc_selectNextRevision(doc));
        return kCBLStatusOK;
    }];
    return revs;
}


- (NSArray*) getPossibleAncestorRevisionIDs: (CBL_Revision*)rev
                                      limit: (unsigned)limit
                            onlyAttachments: (BOOL)onlyAttachments
{
    unsigned generation = [CBL_Revision generationFromRevID: rev.revID];
    if (generation <= 1)
        return nil;
    __block NSMutableArray* revIDs = nil;
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        revIDs = $marray();
        do {
            C4DocumentFlags flags = doc->selectedRev.flags;
            if (!(flags & kRevDeleted) && (!onlyAttachments || (flags & kRevHasAttachments))
                            && c4_getRevisionGeneration(doc->selectedRev.revID) < generation
                            && c4doc_hasRevisionBody(doc)) {
                [revIDs addObject: C4SliceToString(doc->selectedRev.revID)];
                if (limit && revIDs.count >= limit)
                    break;
            }
        } while (c4doc_selectNextRevision(doc));
        return kCBLStatusOK;
    }];
    return revIDs;
}


- (NSString*) findCommonAncestorOf: (CBL_Revision*)rev withRevIDs: (NSArray*)revIDs {
    unsigned generation = [CBL_Revision generationFromRevID: rev.revID];
    if (generation <= 1 || revIDs.count == 0)
        return nil;
    revIDs = [revIDs sortedArrayUsingComparator: ^NSComparisonResult(NSString* id1, NSString* id2) {
        return CBLCompareRevIDs(id2, id1); // descending order of generation
    }];
    __block NSString* commonAncestor = nil;
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        for (NSString* possibleRevID in revIDs) {
            if ([CBL_Revision generationFromRevID: possibleRevID] <= generation) {
                CBLWithStringBytes(possibleRevID, ^(const char *buf, size_t size) {
                    if (c4doc_selectRevision(doc, {buf, size}, false, NULL))
                        commonAncestor = possibleRevID;
                });
                if (commonAncestor)
                    break;
            }
        }
        return kCBLStatusOK;
    }];
    return commonAncestor;
}
    

- (NSArray*) getRevisionHistory: (CBL_Revision*)rev
                   backToRevIDs: (NSSet*)ancestorRevIDs
{
    NSMutableArray* history = [NSMutableArray array];
    [self _withVersionedDoc: rev.docID mustExist: YES do: ^(C4Document* doc) {
        do {
            CBLStatus status;
            CBL_MutableRevision* rev = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                                              docID: rev.docID
                                                                              revID: nil
                                                                           withBody: NO
                                                                             status: &status];
            if (!rev)
                break;
            rev.missing = !c4doc_hasRevisionBody(doc);
            [history addObject: rev];
            if ([ancestorRevIDs containsObject: rev.revID])
                break;
        } while (c4doc_selectParentRevision(doc));
        return kCBLStatusOK;
    }];
    return history;
}


- (CBL_RevisionList*) changesSinceSequence: (SequenceNumber)lastSequence
                                   options: (const CBLChangesOptions*)options
                                    filter: (CBL_RevisionFilter)filter
                                    status: (CBLStatus*)outStatus
{
    // http://wiki.apache.org/couchdb/HTTP_database_API#Changes
    if (!options) options = &kDefaultCBLChangesOptions;
    
    if (options->descending) {
        // https://github.com/couchbase/couchbase-lite-ios/issues/641
        *outStatus = kCBLStatusNotImplemented;
        return nil;
    }

    BOOL withBody = (options->includeDocs || filter != nil);
    unsigned limit = options->limit;

    C4Error c4err;
    CLEANUP(C4DocEnumerator)* e = c4db_enumerateChanges(_forest, lastSequence, NULL, &c4err);
    if (!e) {
        *outStatus = CBLStatusFromC4Error(c4err);
        return nil;
    }
    CBL_RevisionList* changes = [[CBL_RevisionList alloc] init];
    while (limit-- > 0 && c4enum_next(e, &c4err)) {
        @autoreleasepool {
            CLEANUP(C4Document) *doc = c4enum_getDocument(e, &c4err);
            if (!doc)
                break;
            NSString* docID = C4SliceToString(doc->docID);
            do {
                CBL_MutableRevision* rev;
                rev = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                             docID: docID
                                                             revID: nil
                                                          withBody: withBody
                                                            status: outStatus];
                if (!rev)
                    return nil;
                if (!filter || filter(rev)) {
                    if (!options->includeDocs)
                        rev.body = nil;
                    [changes addRev: rev];
                }
            } while (options->includeConflicts && c4doc_selectNextLeafRevision(doc, true, withBody,
                                                                               &c4err));
            if (c4err.code)
                break;
        }
    }
    if (c4err.code) {
        *outStatus = CBLStatusFromC4Error(c4err);
        return nil;
    }
    return changes;
}


- (CBLQueryIteratorBlock) getAllDocs: (CBLQueryOptions*)options
                              status: (CBLStatus*)outStatus
{
    if (!options)
        options = [CBLQueryOptions new];
    auto forestOpts = DocEnumerator::Options::kDefault;
    BOOL includeDocs = (options->includeDocs || options.filter);
    forestOpts.descending = options->descending;
    forestOpts.inclusiveEnd = options->inclusiveEnd;
    if (!includeDocs && !(options->allDocsMode >= kCBLShowConflicts))
        forestOpts.contentOptions = Database::kMetaOnly;
    __block unsigned limit = options->limit;
    __block unsigned skip = options->skip;
    CBLQueryRowFilter filter = options.filter;

    __block DocEnumerator e;
    if (options.keys) {
        std::vector<std::string> docIDs;
        for (NSString* docID in options.keys)
            docIDs.push_back(docID.UTF8String);
        e = DocEnumerator(*_forest, docIDs, forestOpts);
    } else {
        id startKey, endKey;
        if (options->descending) {
            startKey = CBLKeyForPrefixMatch(options.startKey, options->prefixMatchLevel);
            endKey = options.endKey;
        } else {
            startKey = options.startKey;
            endKey = CBLKeyForPrefixMatch(options.endKey, options->prefixMatchLevel);
        }
        e = DocEnumerator(*_forest,
                          nsstring_slice(startKey),
                          nsstring_slice(endKey),
                          forestOpts);
    }

    return ^CBLQueryRow*() {
        while (e.next()) {
            NSString* docID = (NSString*)e.doc().key();
            if (!e.doc().exists()) {
                LogTo(QueryVerbose, @"AllDocs: No such row with key=\"%@\"",
                      docID);
                return [[CBLQueryRow alloc] initWithDocID: nil
                                                 sequence: 0
                                                      key: docID
                                                    value: nil
                                              docRevision: nil
                                                  storage: nil];
            }

            bool deleted;
            {
                VersionedDocument::Flags flags;
                revid revID;
                slice docType;
                if (!VersionedDocument::readMeta(e.doc(), flags, revID, docType))
                    if (!options.keys)  // key might be a nonexistent doc
                        continue;
                deleted = (flags & VersionedDocument::kDeleted) != 0;
                if (deleted && options->allDocsMode != kCBLIncludeDeleted && !options.keys)
                    continue; // skip deleted doc
                if (!(flags & VersionedDocument::kConflicted)
                        && options->allDocsMode == kCBLOnlyConflicts)
                    continue; // skip non-conflicted doc
                if (skip > 0) {
                    --skip;
                    continue;
                }
            }

            VersionedDocument doc(*_forest, *e);
            NSString* revID = (NSString*)doc.revID();
            SequenceNumber sequence = doc.sequence();

            CBL_Revision* docRevision = nil;
            if (includeDocs) {
                // Fill in the document contents:
                docRevision = [CBLForestBridge revisionObjectFromForestDoc: doc
                                                                     revID: nil
                                                                  withBody: YES];
                if (!docRevision)
                    Warn(@"AllDocs: Unable to read body of doc %@", docID);
            }

            NSArray* conflicts = nil;
            if (options->allDocsMode >= kCBLShowConflicts && doc.isConflicted()) {
                conflicts = [CBLForestBridge getCurrentRevisionIDs: doc includeDeleted: NO];
                if (conflicts.count == 1)
                    conflicts = nil;
            }

            NSDictionary* value = $dict({@"rev", revID},
                                        {@"deleted", (deleted ?$true : nil)},
                                        {@"_conflicts", conflicts});  // (not found in CouchDB)
            LogTo(QueryVerbose, @"AllDocs: Found row with key=\"%@\", value=%@",
                  docID, value);
            auto row = [[CBLQueryRow alloc] initWithDocID: docID
                                                 sequence: sequence
                                                      key: docID
                                                    value: value
                                              docRevision: docRevision
                                                  storage: nil];
            if (filter && !filter(row)) {
                LogTo(QueryVerbose, @"   ... on 2nd thought, filter predicate skipped that row");
                continue;
            }

            if (limit > 0 && --limit == 0)
                e.close();
            return row;
        }
        return nil;
    };
}


- (BOOL) findMissingRevisions: (CBL_RevisionList*)revs
                       status: (CBLStatus*)outStatus
{
    CBL_RevisionList* sortedRevs = [revs mutableCopy];
    [sortedRevs sortByDocID];
    __block VersionedDocument* doc = NULL;
    *outStatus = tryStatus(^CBLStatus {
        NSString* lastDocID = nil;
        for (CBL_Revision* rev in sortedRevs) {
            if (!$equal(rev.docID, lastDocID)) {
                lastDocID = rev.docID;
                delete doc;
                doc = new VersionedDocument(*_forest, lastDocID);
            }
            if (doc && doc->get(rev.revID) != NULL)
                [revs removeRevIdenticalTo: rev];
        }
        return kCBLStatusOK;
    });
    delete doc;
    return !CBLStatusIsError(*outStatus);
}


#pragma mark - PURGING / COMPACTING:


- (NSSet*) findAllAttachmentKeys: (NSError**)outError {
    NSMutableSet* keys = [NSMutableSet setWithCapacity: 1000];
    CBLStatus status = tryStatus(^CBLStatus{
        DocEnumerator::Options options = DocEnumerator::Options::kDefault;
        options.contentOptions = Database::kMetaOnly;
        for (DocEnumerator e(*_forest, slice::null, slice::null, options); e.next(); ) {
            VersionedDocument doc(*_forest, *e);
            if (!doc.hasAttachments() || (doc.isDeleted() && !doc.isConflicted()))
                continue;
            doc.read();
            // Since db is assumed to have just been compacted, we know that non-current revisions
            // won't have any bodies. So only scan the current revs.
            auto revNodes = doc.currentRevisions();
            for (auto revNode = revNodes.begin(); revNode != revNodes.end(); ++revNode) {
                if ((*revNode)->isActive() && (*revNode)->hasAttachments()) {
                    alloc_slice body = (*revNode)->readBody();
                    if (body.size > 0) {
                        NSDictionary* rev = [CBLJSON JSONObjectWithData: body.uncopiedNSData()
                                                                options: 0 error: NULL];
                        [rev.cbl_attachments enumerateKeysAndObjectsUsingBlock:^(id key, NSDictionary* att, BOOL *stop) {
                            CBLBlobKey blobKey;
                            if ([CBL_Attachment digest: att[@"digest"] toBlobKey: &blobKey]) {
                                NSData* keyData = [[NSData alloc] initWithBytes: &blobKey length: sizeof(blobKey)];
                                [keys addObject: keyData];
                            }
                        }];
                    }
                }
            }
        }
        return kCBLStatusOK;
    });
    if (CBLStatusIsError(status)) {
        CBLStatusToOutNSError(status, outError);
        keys = nil;
    }
    return keys;
}


- (CBLStatus) purgeRevisions: (NSDictionary*)docsToRevs
                      result: (NSDictionary**)outResult
{
    // <http://wiki.apache.org/couchdb/Purge_Documents>
    NSMutableDictionary* result = $mdict();
    if (outResult)
        *outResult = result;
    if (docsToRevs.count == 0)
        return kCBLStatusOK;
    LogTo(CBLDatabase, @"Purging %lu docs...", (unsigned long)docsToRevs.count);
    return [self inTransaction: ^CBLStatus {
        for (NSString* docID in docsToRevs) {
            VersionedDocument doc(*_forest, docID);
            if (!doc.exists())
                return kCBLStatusNotFound;

            NSArray* revsPurged;
            NSArray* revIDs = $castIf(NSArray, docsToRevs[docID]);
            if (!revIDs) {
                return kCBLStatusBadParam;
            } else if (revIDs.count == 0) {
                revsPurged = @[];
            } else if ([revIDs containsObject: @"*"]) {
                // Delete all revisions if magic "*" revision ID is given:
                _forestTransaction->del(doc.docID());
                revsPurged = @[@"*"];
                LogTo(CBLDatabase, @"Purged doc '%@'", docID);
            } else {
                NSMutableArray* purged = $marray();
                for (NSString* revID in revIDs) {
                    if (doc.purge(revidBuffer(revID)) > 0)
                        [purged addObject: revID];
                }
                if (purged.count > 0) {
                    if (doc.allRevisions().size() > 0) {
                        doc.save(*_forestTransaction);
                        LogTo(CBLDatabase, @"Purged doc '%@' revs %@", docID, revIDs);
                    } else {
                        _forestTransaction->del(doc.docID());
                        LogTo(CBLDatabase, @"Purged doc '%@'", docID);
                    }
                }
                revsPurged = purged;
            }
            result[docID] = revsPurged;
        }
        return kCBLStatusOK;
    }];
}


#pragma mark - LOCAL DOCS:


static NSDictionary* getDocProperties(const Document& doc) {
    NSData* bodyData = doc.body().uncopiedNSData();
    if (!bodyData)
        return nil;
    return [CBLJSON JSONObjectWithData: bodyData options: 0 error: NULL];
}


- (CBL_MutableRevision*) getLocalDocumentWithID: (NSString*)docID
                                     revisionID: (NSString*)revID
{
    if (![docID hasPrefix: @"_local/"])
        return nil;
    KeyStore localDocs(_forest, "_local");
    Document doc = localDocs.get((cbforest::slice)docID.UTF8String);
    if (!doc.exists())
        return nil;
    NSString* gotRevID = (NSString*)doc.meta();
    if (revID && !$equal(revID, gotRevID))
        return nil;
    NSMutableDictionary* properties = [getDocProperties(doc) mutableCopy];
    if (!properties)
        return nil;
    properties[@"_id"] = docID;
    properties[@"_rev"] = gotRevID;
    CBL_MutableRevision* result = [[CBL_MutableRevision alloc] initWithDocID: docID revID: gotRevID
                                                                     deleted: NO];
    result.properties = properties;
    return result;
}


- (CBL_Revision*) putLocalRevision: (CBL_Revision*)revision
                    prevRevisionID: (NSString*)prevRevID
                          obeyMVCC: (BOOL)obeyMVCC
                            status: (CBLStatus*)outStatus
{
    NSString* docID = revision.docID;
    if (![docID hasPrefix: @"_local/"]) {
        *outStatus = kCBLStatusBadID;
        return nil;
    }
    if (revision.deleted) {
        // DELETE:
        *outStatus = [self deleteLocalDocumentWithID: docID
                                          revisionID: prevRevID
                                            obeyMVCC: obeyMVCC];
        return *outStatus < 300 ? revision : nil;
    } else {
        // PUT:
        __block CBL_Revision* result = nil;
        *outStatus = [self inTransaction: ^CBLStatus {
            KeyStore localDocs(_forest, "_local");
            KeyStoreWriter localWriter = (*_forestTransaction)(localDocs);
            NSData* json = revision.asCanonicalJSON;
            if (!json)
                return kCBLStatusBadJSON;
            cbforest::slice key(docID.UTF8String);
            Document doc = localWriter.get(key);
            NSString* actualPrevRevID = doc.exists() ? (NSString*)doc.meta() : nil;
            if (obeyMVCC && !$equal(prevRevID, actualPrevRevID))
                return kCBLStatusConflict;
            unsigned generation = [CBL_Revision generationFromRevID: actualPrevRevID];
            NSString* newRevID = $sprintf(@"%d-local", generation + 1);
            localWriter.set(key, nsstring_slice(newRevID), cbforest::slice(json));
            result = [revision mutableCopyWithDocID: docID revID: newRevID];
            return kCBLStatusCreated;
        }];
        return result;
    }
}


- (CBLStatus) deleteLocalDocumentWithID: (NSString*)docID
                             revisionID: (NSString*)revID
                               obeyMVCC: (BOOL)obeyMVCC
{
    if (![docID hasPrefix: @"_local/"])
        return kCBLStatusBadID;
    if (obeyMVCC && !revID) {
        // Didn't specify a revision to delete: kCBLStatusNotFound or a kCBLStatusConflict, depending
        return [self getLocalDocumentWithID: docID revisionID: nil] ? kCBLStatusConflict : kCBLStatusNotFound;
    }

    KeyStore localDocs(_forest, "_local");
    return [self inTransaction: ^CBLStatus {
        KeyStoreWriter localWriter = (*_forestTransaction)(localDocs);
        Document doc = localWriter.get(cbforest::slice(docID.UTF8String));
        if (!doc.exists())
            return kCBLStatusNotFound;
        else if (obeyMVCC && !$equal(revID, (NSString*)doc.meta()))
            return kCBLStatusConflict;
        else {
            localWriter.del(doc);
            return kCBLStatusOK;
        }
    }];
}


#pragma mark - INFO FOR KEY:


- (NSString*) infoForKey: (NSString*)key {
    KeyStore infoStore(_forest, "info");
    __block NSString* value = nil;
    tryStatus(^CBLStatus {
        Document doc = infoStore.get((cbforest::slice)key.UTF8String);
        value = (NSString*)doc.body();
        return kCBLStatusOK;
    });
    return value;
}


- (CBLStatus) setInfo: (NSString*)info forKey: (NSString*)key {
    KeyStore infoStore(_forest, "info");
    return [self inTransaction: ^CBLStatus {
        KeyStoreWriter infoWriter = (*_forestTransaction)(infoStore);
        infoWriter.set((cbforest::slice)key.UTF8String, (cbforest::slice)info.UTF8String);
        return kCBLStatusOK;
    }];
}


#pragma mark - INSERTION:


- (CBLDatabaseChange*) changeWithNewRevision: (CBL_Revision*)inRev
                                isWinningRev: (BOOL)isWinningRev
                                         doc: (C4Document*)doc
                                      source: (NSURL*)source
{
    NSString* winningRevID;
    if (isWinningRev) {
        winningRevID = inRev.revID;
    } else {
        const Revision* winningRevision = doc.currentRevision();
        winningRevID = (NSString*)winningRevision->revID;
    }
    return [[CBLDatabaseChange alloc] initWithAddedRevision: inRev
                                          winningRevisionID: winningRevID
                                                 inConflict: doc.hasConflict()
                                                     source: source];
}


- (CBL_Revision*) addDocID: (NSString*)inDocID
                 prevRevID: (NSString*)inPrevRevID
                properties: (NSMutableDictionary*)properties
                  deleting: (BOOL)deleting
             allowConflict: (BOOL)allowConflict
           validationBlock: (CBL_StorageValidationBlock)validationBlock
                    status: (CBLStatus*)outStatus
                     error: (NSError **)outError
{
    if (outError)
        *outError = nil;

    if (_forest->isReadOnly()) {
        *outStatus = kCBLStatusForbidden;
        CBLStatusToOutNSError(*outStatus, outError);
        return nil;
    }

    __block NSData* json = nil;
    if (properties) {
        json = [CBL_Revision asCanonicalJSON: properties error: NULL];
        if (!json) {
            *outStatus = kCBLStatusBadJSON;
            CBLStatusToOutNSError(*outStatus, outError);
            return nil;
        }
    } else {
        json = [NSData dataWithBytes: "{}" length: 2];
    }

    __block CBL_Revision* putRev = nil;
    __block CBLDatabaseChange* change = nil;

    *outStatus = [self inTransaction: ^CBLStatus {
        NSString* docID = inDocID;
        NSString* prevRevID = inPrevRevID;

        Document rawDoc;
        if (docID) {
            // Read the doc from the database:
            rawDoc.setKey(nsstring_slice(docID));
            _forest->read(rawDoc);
        } else {
            // Create new doc ID, and don't bother to read it since it's a new doc:
            docID = CBLCreateUUID();
            rawDoc.setKey(nsstring_slice(docID));
        }

        // Parse the document revision tree:
        VersionedDocument doc(*_forest, rawDoc);
        const Revision* revNode;

        if (prevRevID) {
            // Updating an existing revision; make sure it exists and is a leaf:
            revNode = doc.get(prevRevID);
            if (!revNode)
                return kCBLStatusNotFound;
            else if (!allowConflict && !revNode->isLeaf())
                return kCBLStatusConflict;
        } else {
            // No parent revision given:
            if (deleting) {
                // Didn't specify a revision to delete: NotFound or a Conflict, depending
                return doc.exists() ? kCBLStatusConflict : kCBLStatusNotFound;
            }
            // If doc exists, current rev must be in a deleted state or there will be a conflict:
            revNode = doc.currentRevision();
            if (revNode) {
                if (revNode->isDeleted()) {
                    // New rev will be child of the tombstone:
                    // (T0D0: Write a horror novel called "Child Of The Tombstone"!)
                    prevRevID = (NSString*)revNode->revID;
                } else {
                    return kCBLStatusConflict;
                }
            }
        }

        // Compute the new revID. (Can't be done earlier because prevRevID may have changed.)
        NSString* newRevID = [_delegate generateRevIDForJSON: json
                                                     deleted: deleting
                                                   prevRevID: prevRevID];
        if (!newRevID)
            return kCBLStatusBadID;  // invalid previous revID (no numeric prefix)

        // Create the new CBL_Revision:
        CBL_Body *body = nil;
        if (properties) {
            properties[@"_id"] = docID;
            properties[@"_rev"] = newRevID;
            body = [[CBL_Body alloc] initWithProperties: properties];
        }
        putRev = [[CBL_Revision alloc] initWithDocID: docID
                                               revID: newRevID
                                             deleted: deleting
                                                body: body];

        // Run any validation blocks:
        if (validationBlock) {
            CBL_Revision* prevRev = nil;
            if (prevRevID) {
                prevRev = [[CBL_Revision alloc] initWithDocID: docID
                                                        revID: prevRevID
                                                      deleted: revNode->isDeleted()];
            }

            CBLStatus status = validationBlock(putRev, prevRev, prevRevID, outError);
            if (CBLStatusIsError(status))
                return status;
        }

        // Add the revision to the database:
        int status;
        revidBuffer newrevid(newRevID);
        {
            const Revision* fdbRev = doc.insert(newrevid, json,
                                                deleting,
                                                (putRev.attachments != nil),
                                                revNode, allowConflict, status);
            if (!fdbRev && CBLStatusIsError((CBLStatus)status))
                return (CBLStatus)status;
        } // fdbRev ptr will be invalidated soon, so let it go out of scope
        BOOL isWinner = [self saveForestDoc: doc revID: newrevid properties: properties];
        putRev.sequence = doc.sequence();
#if DEBUG
        LogTo(CBLDatabase, @"Saved %s", doc.dump().c_str());
#endif

        change = [self changeWithNewRevision: putRev
                                isWinningRev: isWinner
                                         doc: doc
                                      source: nil];
        return (CBLStatus)status;
    }];

    if (CBLStatusIsError(*outStatus)) {
        // Check if the outError has a value to not override the validation error:
        if (outError && !*outError)
            CBLStatusToOutNSError(*outStatus, outError);
        return nil;
    }
    [_delegate databaseStorageChanged: change];
    return putRev;
}


/** Add an existing revision of a document (probably being pulled) plus its ancestors. */
- (CBLStatus) forceInsert: (CBL_Revision*)inRev
          revisionHistory: (NSArray*)history
          validationBlock: (CBL_StorageValidationBlock)validationBlock
                   source: (NSURL*)source
                    error: (NSError **)outError
{
    if (outError)
        *outError = nil;

    if (_forest->isReadOnly()) {
        CBLStatusToOutNSError(kCBLStatusForbidden, outError);
        return kCBLStatusForbidden;
    }

    NSData* json = inRev.asCanonicalJSON;
    if (!json) {
        CBLStatusToOutNSError(kCBLStatusBadJSON, outError);
        return kCBLStatusBadJSON;
    }

    __block CBLDatabaseChange* change = nil;

    CBLStatus status = [self inTransaction: ^CBLStatus {
        // First get the CBForest doc:
        VersionedDocument doc(*_forest, inRev.docID);

        // Add the revision & ancestry to the doc:
        std::vector<revidBuffer> historyVector;
        historyVector.reserve(history.count);
        for (NSString* revID in history)
            historyVector.push_back(revidBuffer(revID));
        int common = doc.insertHistory(historyVector,
                                       cbforest::slice(json),
                                       inRev.deleted,
                                       (inRev.attachments != nil));
        if (common < 0)
            return kCBLStatusBadRequest; // generation numbers not in descending order
        else if (common == 0)
            return kCBLStatusOK;      // No-op: No new revisions were inserted.

        // Validate against the common ancestor:
        if (validationBlock) {
            CBL_Revision* prev;
            if ((NSUInteger)common < history.count) {
                BOOL deleted = doc[historyVector[common]]->isDeleted();
                prev = [[CBL_Revision alloc] initWithDocID: inRev.docID
                                                     revID: history[common]
                                                   deleted: deleted];
            }
            NSString* parentRevID = (history.count > 1) ? history[1] : nil;
            CBLStatus status = validationBlock(inRev, prev, parentRevID, outError);
            if (CBLStatusIsError(status))
                return status;
        }

        // Save updated doc back to the database:
        BOOL isWinner = [self saveForestDoc: doc
                                      revID: historyVector[0]
                                 properties: inRev.properties];
        inRev.sequence = doc.sequence();
#if DEBUG
        LogTo(CBLDatabase, @"Saved %s", doc.dump().c_str());
#endif
        change = [self changeWithNewRevision: inRev
                                isWinningRev: isWinner
                                         doc: doc
                                      source: source];
        return kCBLStatusCreated;
    }];

    if (change)
        [_delegate databaseStorageChanged: change];

    if (CBLStatusIsError(status)) {
        // Check if the outError has a value to not override the validation error:
        if (outError && !*outError)
            CBLStatusToOutNSError(status, outError);
    }
    return status;
}


- (BOOL) saveForestDoc: (C4Document*)doc
                 revID: (revid)revID
            properties: (NSDictionary*)properties
{
    // Is the new revision the winner?
    BOOL isWinner = (doc.currentRevision()->revID == revID);
    // Update the documentType:
    if (!isWinner)
        properties = [CBLForestBridge bodyOfNode: doc[0]];
    nsstring_slice type(properties[@"type"]);
    doc.setDocType(type);
    // Save:
    doc.prune((unsigned)_maxRevTreeDepth);
    doc.save(*_forestTransaction);
    return isWinner;
}


#pragma mark - VIEWS:


- (id<CBL_ViewStorage>) viewStorageNamed: (NSString*)name create:(BOOL)create {
    id<CBL_ViewStorage> view = [_views objectForKey: name];
    if (!view) {
        view = [[CBL_ForestDBViewStorage alloc] initWithDBStorage: self name: name create: create];
        if (view) {
            if (!_views)
                _views = [NSMapTable strongToWeakObjectsMapTable];
            [_views setObject: view forKey: name];
        }
    }
    return view;
}


- (void) forgetViewStorageNamed: (NSString*)viewName {
    [_views removeObjectForKey: viewName];
}


- (NSArray*) allViewNames {
    NSArray* filenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: _directory
                                                                             error: NULL];
    // Mapping files->views may produce duplicates because there can be multiple files for the
    // same view, if compression is in progress. So use a set to coalesce them.
    NSMutableSet *viewNames = [NSMutableSet set];
    for (NSString* filename in filenames) {
        NSString* viewName = [CBL_ForestDBViewStorage fileNameToViewName: filename];
        if (viewName)
            [viewNames addObject: viewName];
    }
    return viewNames.allObjects;
}


@end
