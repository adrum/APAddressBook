//
//  APAddressBook.m
//  APAddressBook
//
//  Created by Alexey Belkevich on 1/10/14.
//  Copyright (c) 2014 alterplay. All rights reserved.
//

#import <AddressBook/AddressBook.h>
#import "APAddressBook.h"
#import "APContact.h"

void APAddressBookExternalChangeCallback(ABAddressBookRef addressBookRef, CFDictionaryRef info,
                                         void *context);

@interface APAddressBook ()
@property (atomic, readonly) ABAddressBookRef addressBook;
@property (nonatomic, copy) void (^changeCallback)();
@end

@implementation APAddressBook

#pragma mark - life cycle

- (id)init
{
    self = [super init];
    if (self)
    {
        self.fieldsMask = APContactFieldDefault;
        CFErrorRef *error = NULL;
        _addressBook = ABAddressBookCreateWithOptions(NULL, error);
        if (error)
        {
            NSString *errorReason = (__bridge_transfer NSString *)CFErrorCopyFailureReason(*error);
            NSLog(@"APAddressBook initialization error:\n%@", errorReason);
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    [self stopObserveChanges];
    if (_addressBook)
    {
        CFRelease(_addressBook);
    }
}

#pragma mark - public

+ (APAddressBookAccess)access
{
    ABAuthorizationStatus status = ABAddressBookGetAuthorizationStatus();
    switch (status)
    {
        case kABAuthorizationStatusDenied:
        case kABAuthorizationStatusRestricted:
            return APAddressBookAccessDenied;

        case kABAuthorizationStatusAuthorized:
            return APAddressBookAccessGranted;

        default:
            return APAddressBookAccessUnknown;
    }
}

+ (void)requestAccess:(void (^)(BOOL granted, NSError * error))completionBlock {
    [self requestAccessOnQueue:dispatch_get_main_queue() completion:completionBlock];
}

+ (void)requestAccessOnQueue:(dispatch_queue_t)queue
                  completion:(void (^)(BOOL granted, NSError * error))completionBlock
{
    CFErrorRef *initializationError = NULL;
    ABAddressBookRef addressBook = ABAddressBookCreateWithOptions(NULL, initializationError);
    if (initializationError)
    {

        completionBlock ? completionBlock(NO, (__bridge NSError *)(*initializationError)) : nil;
    }
    else
    {
        ABAddressBookRequestAccessWithCompletion(addressBook, ^(bool granted, CFErrorRef error)
        {
            dispatch_async(queue, ^
            {
                completionBlock ? completionBlock(granted, (__bridge NSError *)error) : nil;
            });
        });
    }

}

+ (NSString *)getContactsVcard:(NSArray *)contacts withImage:(BOOL)copyImage
{
    if (contacts.count == 0) {
        return @"";
    }
    
    for (NSUInteger i = 0; i < contacts.count; i++){
        if (![contacts[i] isKindOfClass:[APContact class]]) {
            [NSException raise:@"Invalid type of object" format:@"input array object is not of 'APContact' type"];
        }
    }
    
    NSMutableArray *naitiveContacts = [[NSMutableArray alloc]init];
    for (APContact *contact in contacts){
        [naitiveContacts addObject:contact.originalABRecord];
    }
    
    CFDataRef vcards = (CFDataRef)ABPersonCreateVCardRepresentationWithPeople((__bridge CFArrayRef)(naitiveContacts));
    NSString *vcardString = [[NSString alloc] initWithData:(__bridge NSData *)vcards encoding:NSUTF8StringEncoding];
    
    if (copyImage) {
        return vcardString;
    }
    
    return [self removeImageFromVcardString:vcardString];
}

+(NSArray *)createContactsFromVcard:(NSString *)vCard fieldMask:(APContactField)fieldMask withImage:(BOOL)copyImage saveContacts:(BOOL)save {
    
    if (!copyImage) {
        vCard = [self removeImageFromVcardString:vCard];
    }
    
    // If you're using ARC, use this line instead:
    CFDataRef vCardData = (__bridge CFDataRef)[vCard dataUsingEncoding:NSUTF8StringEncoding];
    
    CFErrorRef *error = NULL;
    ABAddressBookRef book = ABAddressBookCreateWithOptions(NULL, error);
    ABRecordRef defaultSource = ABAddressBookCopyDefaultSource(book);
    CFArrayRef vCardPeople = ABPersonCreatePeopleInSourceWithVCardRepresentation(defaultSource, vCardData);
    
    NSMutableArray *newContacts = [NSMutableArray array];
    for (CFIndex index = 0; index < CFArrayGetCount(vCardPeople); index++) {
        ABRecordRef person = CFArrayGetValueAtIndex(vCardPeople, index);
        if (save) {
            ABAddressBookAddRecord(book, person, NULL);
        }
        APContact *c = [[APContact alloc] initWithRecordRef:person fieldMask:fieldMask];
        [newContacts addObject:c];
    }
    
    CFRelease(vCardPeople);
    CFRelease(defaultSource);
    ABAddressBookSave(book, NULL);
    CFRelease(book);
    
    return newContacts;
}

+ (NSString *)removeImageFromVcardString:(NSString*)vcard
{
    NSScanner *scanner = [NSScanner scannerWithString:vcard];
    NSString *text = nil;
    
    NSString *photo = @"PHOTO";
    NSString *endVcard = @"END:VCARD";
    NSString *socialProfile = @"X-SOCIALPROFILE";
    
    if ([vcard rangeOfString:@"X-SOCIALPROFILE"].location == NSNotFound) {
        while ([scanner isAtEnd] == NO) {
            [scanner scanUpToString:photo intoString:NULL] ;
            [scanner scanUpToString:endVcard intoString:&text] ;
            vcard = [vcard stringByReplacingOccurrencesOfString:
                          [NSString stringWithFormat:@"%@", text] withString:@""];
        }
    }else{
        while ([scanner isAtEnd] == NO) {
            [scanner scanUpToString:photo intoString:NULL] ;
            [scanner scanUpToString:socialProfile intoString:&text] ;
            [scanner scanUpToString:endVcard intoString:NULL];
            vcard = [vcard stringByReplacingOccurrencesOfString:
                          [NSString stringWithFormat:@"%@", text] withString:@""];
        }
    }
    
    return vcard;
}

- (void)loadContacts:(void (^)(NSArray *contacts, NSError *error))completionBlock
{
    [self loadContactsOnQueue:dispatch_get_main_queue() completion:completionBlock];
}

- (void)loadContactsOnQueue:(dispatch_queue_t)queue
                 completion:(void (^)(NSArray *contacts, NSError *error))completionBlock
{
    APContactField fieldMask = self.fieldsMask;
    NSArray *descriptors = self.sortDescriptors;
    APContactFilterBlock filterBlock = self.filterBlock;

    ABAddressBookRequestAccessWithCompletion(self.addressBook, ^(bool granted, CFErrorRef errorRef)
    {
        NSArray *array = nil;
        NSError *error = nil;
        if (granted)
        {
            __block CFArrayRef peopleArrayRef;
            peopleArrayRef = ABAddressBookCopyArrayOfAllPeople(self.addressBook);
            NSUInteger contactCount = (NSUInteger)CFArrayGetCount(peopleArrayRef);
            NSMutableArray *contacts = [[NSMutableArray alloc] init];
            for (NSUInteger i = 0; i < contactCount; i++)
            {
                ABRecordRef recordRef = CFArrayGetValueAtIndex(peopleArrayRef, i);
                APContact *contact = [[APContact alloc] initWithRecordRef:recordRef
                                                                fieldMask:fieldMask];
                if (!filterBlock || filterBlock(contact))
                {
                    [contacts addObject:contact];
                }
            }
            [contacts sortUsingDescriptors:descriptors];
            array = contacts.copy;
            CFRelease(peopleArrayRef);
        }
        error = errorRef ? (__bridge NSError *)errorRef : nil;
        dispatch_async(queue, ^
        {
            completionBlock ? completionBlock(array, error) : nil;
        });
    });
}

- (void)startObserveChangesWithCallback:(void (^)())callback
{
    if (callback)
    {
        if (!self.changeCallback)
        {
            ABAddressBookRegisterExternalChangeCallback(self.addressBook,
                                                        APAddressBookExternalChangeCallback,
                                                        (__bridge void *)(self));
        }
        self.changeCallback = callback;
    }
}

- (void)stopObserveChanges
{
    if (self.changeCallback)
    {
        self.changeCallback = nil;
        ABAddressBookUnregisterExternalChangeCallback(self.addressBook,
                                                      APAddressBookExternalChangeCallback,
                                                      (__bridge void *)(self));
    }
}

- (APContact *)getContactByRecordID:(NSNumber *)recordID
{
    APContact *contact = nil;
    ABRecordRef ref = ABAddressBookGetPersonWithRecordID(self.addressBook, recordID.intValue);
    if (ref != NULL)
    {
        contact = [[APContact alloc] initWithRecordRef:ref fieldMask:self.fieldsMask];
    }
    return contact;
}

#pragma mark - external change callback

void APAddressBookExternalChangeCallback(ABAddressBookRef __unused addressBookRef,
                                         CFDictionaryRef __unused info,
                                         void *context)
{
    ABAddressBookRevert(addressBookRef);
    APAddressBook *addressBook = (__bridge APAddressBook *)(context);
    addressBook.changeCallback ? addressBook.changeCallback() : nil;
}

@end
