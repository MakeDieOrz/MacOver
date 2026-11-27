//
//  PlayedAppleDBConstants.swift
//  PlayTools
//
//  Created by TheMoonThatRises on 9/12/24.
//

import Security

struct PlayedAppleDBConstants {
    // https://developer.apple.com/documentation/security/keychain_services/keychain_items/item_class_keys_and_values
    // Synchronizable does not matter.
    nonisolated(unsafe) static let primaries = [
        kSecClassGenericPassword: [
            kSecAttrAccessGroup,
            kSecAttrAccount,
            kSecAttrService
            // kSecAttrSynchronizable
        ],
        kSecClassInternetPassword: [
            kSecAttrAccessGroup,
            kSecAttrAccount,
            kSecAttrAuthenticationType,
            kSecAttrPath,
            kSecAttrPort,
            kSecAttrProtocol,
            kSecAttrSecurityDomain,
            kSecAttrServer
            // kSecAttrSynchronizable
        ],
        kSecClassCertificate: [
            kSecAttrAccessGroup,
            kSecAttrCertificateType,
            kSecAttrIssuer,
            kSecAttrSerialNumber
            // kSecAttrSynchronizable
        ],
        kSecClassKey: [
            kSecAttrAccessGroup,
            kSecAttrApplicationLabel,
            kSecAttrApplicationTag,
            kSecAttrEffectiveKeySize,
            kSecAttrKeyClass,
            kSecAttrKeySizeInBits,
            kSecAttrKeyType
            // kSecAttrSynchronizable
        ],
        kSecClassIdentity: [
            kSecAttrAccessGroup,
            kSecAttrCertificateType,
            kSecAttrIssuer,
            kSecAttrSerialNumber
            // kSecAttrSynchronizable
        ]
    ]
    nonisolated(unsafe) static let attributes = [
        kSecClassGenericPassword: [
            kSecAttrAccessControl,
            kSecAttrAccessible,
            kSecAttrCreationDate,
            kSecAttrModificationDate,
            kSecAttrDescription,
            kSecAttrComment,
            kSecAttrCreator,
            kSecAttrType,
            kSecAttrLabel,
            kSecAttrIsInvisible,
            kSecAttrIsNegative,
            kSecAttrGeneric,
            kSecAttrSynchronizable
        ],
        kSecClassInternetPassword: [
            kSecAttrAccessControl,
            kSecAttrAccessible,
            kSecAttrCreationDate,
            kSecAttrModificationDate,
            kSecAttrDescription,
            kSecAttrComment,
            kSecAttrCreator,
            kSecAttrType,
            kSecAttrLabel,
            kSecAttrIsInvisible,
            kSecAttrIsNegative,
            kSecAttrGeneric,
            kSecAttrSynchronizable
        ],
        kSecClassCertificate: [
            kSecAttrAccessControl,
            kSecAttrAccessible,
            kSecAttrCreationDate,
            kSecAttrModificationDate,
            kSecAttrCertificateEncoding,
            kSecAttrLabel,
            kSecAttrSubject,
            kSecAttrSubjectKeyID,
            kSecAttrPublicKeyHash,
            kSecAttrSynchronizable
        ],
        kSecClassKey: [
            kSecAttrAccessControl,
            kSecAttrAccessible,
            kSecAttrCreationDate,
            kSecAttrModificationDate,
            kSecAttrDescription,
            kSecAttrComment,
            kSecAttrLabel,
            kSecAttrIsPermanent,
            kSecAttrCanEncrypt,
            kSecAttrCanDecrypt,
            kSecAttrCanDerive,
            kSecAttrCanSign,
            kSecAttrCanVerify,
            kSecAttrCanWrap,
            kSecAttrCanUnwrap,
            kSecAttrSynchronizable
        ],
        kSecClassIdentity: [
            kSecAttrAccessControl,
            kSecAttrAccessible,
            kSecAttrCreationDate,
            kSecAttrModificationDate,
            kSecAttrDescription,
            kSecAttrComment,
            kSecAttrCertificateEncoding,
            kSecAttrLabel,
            kSecAttrSubject,
            kSecAttrSubjectKeyID,
            kSecAttrPublicKeyHash,
            kSecAttrApplicationLabel,
            kSecAttrApplicationTag,
            kSecAttrKeyType,
            kSecAttrKeyClass,
            kSecAttrKeySizeInBits,
            kSecAttrEffectiveKeySize,
            kSecAttrIsPermanent,
            kSecAttrCanEncrypt,
            kSecAttrCanDecrypt,
            kSecAttrCanDerive,
            kSecAttrCanSign,
            kSecAttrCanVerify,
            kSecAttrCanWrap,
            kSecAttrCanUnwrap,
            kSecAttrSynchronizable
        ]
    ]
    nonisolated(unsafe) static let values = [
        kSecValueData,
        kSecValueRef,
        kSecValuePersistentRef
    ]
}
