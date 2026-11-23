//
//  PlayWeRuinedIt.swift
//  PlayTools
//
//  Created by Venti on 16/01/2023.
//

import Foundation
import Security

// Implementation for PlayKeychain
// World's Most Advanced Keychain Replacement Solution:tm:
// This is a joke, don't take it seriously

public class PlayKeychain: NSObject {
    static let shared = PlayKeychain()
    private static let playChainDB = PlayKeychainDB.shared

    @objc public static func debugLogger(_ logContent: String) {
        if PlaySettings.shared.playChainDebugging {
            NSLog("PC-DEBUG: \(logContent)")
        }
    }

    private static func flag(_ dictionary: NSDictionary, _ key: CFString) -> Bool {
        let value = dictionary[key as String]
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }
    // Emulates SecItemAdd, SecItemUpdate, SecItemDelete and SecItemCopyMatching
    // Store the entire dictionary as a plist
    // SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result)
    @objc static public func add(_ attributes: NSDictionary,
                                 result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        let (status, insertedDict) = playChainDB.insertWithStatus(attributes)
        guard status == errSecSuccess, let keychainDict = insertedDict else {
            debugLogger("Failed to write keychain file (status: \(status))")
            return status
        }
        debugLogger("Wrote keychain item to db")

        let wantsReturn =
            flag(attributes, kSecReturnAttributes) ||
            flag(attributes, kSecReturnData) ||
            flag(attributes, kSecReturnRef) ||
            flag(attributes, kSecReturnPersistentRef)

        guard wantsReturn, let result else {
            return errSecSuccess
        }

        return buildSingleResult(attributes, keychainDict: keychainDict, result: result)
    }

    private static func makeCFError(status: OSStatus) -> Unmanaged<CFError>? {
        guard let err = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, CFIndex(status), nil) else {
            return nil
        }
        return Unmanaged.passRetained(err)
    }

    private static func isSecureEnclavePrivateKeyItem(_ item: NSDictionary) -> Bool {
        guard (item[PlayKeychainDB.internalTokenIDColumn] as? String) == (kSecAttrTokenIDSecureEnclave as String) else {
            return false
        }
        let keyClass = (item[kSecAttrKeyClass] as? String) ?? (item["kcls"] as? String)
        return keyClass != (kSecAttrKeyClassPublic as String)
    }

    private static func makeResultDictionary(
        from item: NSDictionary,
        queryClassType: String,
        wantsAttributes: Bool,
        wantsData: Bool,
        wantsRef: Bool,
        wantsPersistentRef: Bool
    ) -> NSMutableDictionary {
        let dict = wantsAttributes ? NSMutableDictionary(dictionary: item) : NSMutableDictionary()
        dict.removeObject(forKey: PlayKeychainDB.internalPrivateKeyColumn)
        let storedTokenID = item[PlayKeychainDB.internalTokenIDColumn] as? String
        dict.removeObject(forKey: PlayKeychainDB.internalTokenIDColumn)
        if wantsAttributes, let storedTokenID, dict[kSecAttrTokenID as String] == nil {
            dict[kSecAttrTokenID as String] = storedTokenID
        }
        if wantsData, !isSecureEnclavePrivateKeyItem(item), let vData = item[kSecValueData] {
            dict[kSecValueData as String] = vData
        } else {
            dict.removeObject(forKey: kSecValueData)
        }
        if wantsRef, let ref = materializeReference(for: item, queryClassType: queryClassType) {
            dict[kSecValueRef as String] = ref
        } else {
            dict.removeObject(forKey: kSecValueRef)
        }
        if wantsPersistentRef, let pRef = item[kSecValuePersistentRef] {
            dict[kSecValuePersistentRef as String] = pRef
        } else {
            dict.removeObject(forKey: kSecValuePersistentRef)
        }
        return dict
    }

    private static func buildSingleResult(
        _ queryOrAttributes: NSDictionary,
        keychainDict: NSMutableDictionary,
        result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>
    ) -> OSStatus {
        let wantsAttributes = flag(queryOrAttributes, kSecReturnAttributes)
        let wantsData = flag(queryOrAttributes, kSecReturnData)
        let wantsRef = flag(queryOrAttributes, kSecReturnRef)
        let wantsPersistentRef = flag(queryOrAttributes, kSecReturnPersistentRef)

        if !wantsAttributes && !wantsData && !wantsRef && !wantsPersistentRef {
            return errSecSuccess
        }

        let classType = (queryOrAttributes[kSecClass as String] as? String)
            ?? (keychainDict[kSecClass as String] as? String)
            ?? ""

        let returnFlagCount = (wantsAttributes ? 1 : 0) +
            (wantsData ? 1 : 0) +
            (wantsRef ? 1 : 0) +
            (wantsPersistentRef ? 1 : 0)

        if wantsAttributes || returnFlagCount > 1 {
            let dummyDict = makeResultDictionary(
                from: keychainDict,
                queryClassType: classType,
                wantsAttributes: wantsAttributes,
                wantsData: wantsData,
                wantsRef: wantsRef,
                wantsPersistentRef: wantsPersistentRef
            )
            if !wantsAttributes && dummyDict.count == 0 {
                return errSecItemNotFound
            }
            result.pointee = Unmanaged.passRetained(dummyDict)
            return errSecSuccess
        }

        if wantsData {
            guard !isSecureEnclavePrivateKeyItem(keychainDict),
                  let vData = keychainDict[kSecValueData] else {
                return errSecItemNotFound
            }
            result.pointee = Unmanaged.passRetained(vData as CFTypeRef)
            return errSecSuccess
        }

        if wantsRef {
            return copyReference(keychainDict, classType: classType, result: result)
        }

        if wantsPersistentRef {
            guard let pRef = keychainDict[kSecValuePersistentRef] else {
                return errSecItemNotFound
            }
            result.pointee = Unmanaged.passRetained(pRef as CFTypeRef)
            return errSecSuccess
        }

        return errSecItemNotFound
    }

    // SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate)
    @objc static public func update(_ query: NSDictionary, attributesToUpdate: NSDictionary) -> OSStatus {
        let status = playChainDB.updateMatching(query, attributesToUpdate: attributesToUpdate)
        if status == errSecSuccess {
            debugLogger("Updated keychain item in db")
        } else {
            debugLogger("Failed to update keychain item in db (status: \(status))")
        }
        return status
    }

    // SecItemDelete(CFDictionaryRef query)
    @objc static public func delete(_ query: NSDictionary) -> OSStatus {
        let status = playChainDB.deleteMatching(query)
        if status == errSecSuccess {
            debugLogger("Deleted keychain item in db")
        } else {
            debugLogger("Failed to delete keychain item in db (status: \(status))")
        }
        return status
    }

    private static let persistedKeyAttributeKeys: [CFString] = [
        kSecAttrAccessGroup,
        kSecAttrApplicationLabel,
        kSecAttrApplicationTag,
        kSecAttrEffectiveKeySize,
        kSecAttrKeySizeInBits,
        kSecAttrLabel,
        kSecAttrAccessible,
        kSecAttrCanEncrypt,
        kSecAttrCanDecrypt,
        kSecAttrCanDerive,
        kSecAttrCanSign,
        kSecAttrCanVerify,
        kSecAttrCanWrap,
        kSecAttrCanUnwrap
    ]

    private static func copyPersistedKeyAttributes(
        from parameters: NSDictionary,
        subAttrs: [String: Any],
        into dict: inout [String: Any]
    ) {
        for attrKey in persistedKeyAttributeKeys {
            let keyStr = attrKey as String
            if let val = subAttrs[keyStr] ?? parameters[keyStr] {
                dict[keyStr] = val
            }
        }
    }

    private static let generatedKeyMetadataKeys: [CFString] = [
        kSecAttrKeyType,
        kSecAttrKeyClass,
        kSecAttrApplicationLabel,
        kSecAttrKeySizeInBits,
        kSecAttrEffectiveKeySize,
        kSecAttrCanEncrypt,
        kSecAttrCanDecrypt,
        kSecAttrCanDerive,
        kSecAttrCanSign,
        kSecAttrCanVerify,
        kSecAttrCanWrap,
        kSecAttrCanUnwrap
    ]

    private static func mergeGeneratedKeyMetadata(from key: SecKey, into dict: inout [String: Any]) {
        guard let keyAttrs = SecKeyCopyAttributes(key) as? [String: Any] else {
            return
        }
        for attrKey in generatedKeyMetadataKeys {
            let keyStr = attrKey as String
            if dict[keyStr] == nil, let val = keyAttrs[keyStr] {
                dict[keyStr] = val
            }
        }
    }

    private static func sanitizedKeySubAttrs(_ raw: Any?, forceNonPermanent: Bool) -> [String: Any] {
        var sub = raw as? [String: Any] ?? [:]
        if forceNonPermanent {
            sub[kSecAttrIsPermanent as String] = false
        }
        sub.removeValue(forKey: kSecAttrTokenID as String)
        sub.removeValue(forKey: kSecAttrAccessControl as String)
        return sub
    }

    @objc static public func keyCreateRandomKey(_ parameters: NSDictionary,
                                                error: UnsafeMutablePointer<Unmanaged<CFError>?>?)
    -> Unmanaged<SecKey>? {
        // Check if kSecAttrIsPermanent is set to 1 in kSecPrivateKeyAttrs.
        // If it is, set it to 0 before forwarding the call to SecKeyCreateRandomKey,
        // and then add the key to the keychain db with the original attributes (with kSecAttrIsPermanent set to 1)
        let rawPrivateKeyAttrs = parameters[kSecPrivateKeyAttrs as String] as? [String: Any] ?? [:]
        let isSecureEnclave = PTPlayChainSecureEnclaveRegistry.parametersRequestSecureEnclave(parameters)
        let isPermanent = flag(rawPrivateKeyAttrs as NSDictionary, kSecAttrIsPermanent) ||
            flag(parameters, kSecAttrIsPermanent)
        let privateKeyAttrs = sanitizedKeySubAttrs(rawPrivateKeyAttrs, forceNonPermanent: isPermanent)

        var parametersCopy = parameters as? [String: Any] ?? [:]
        parametersCopy.removeValue(forKey: kSecAttrIsPermanent as String)
        parametersCopy.removeValue(forKey: kSecAttrTokenID as String)
        parametersCopy.removeValue(forKey: kSecAttrAccessControl as String)
        parametersCopy[kSecPrivateKeyAttrs as String] = privateKeyAttrs
        if parametersCopy[kSecPublicKeyAttrs as String] != nil {
            parametersCopy[kSecPublicKeyAttrs as String] = sanitizedKeySubAttrs(
                parametersCopy[kSecPublicKeyAttrs as String],
                forceNonPermanent: true
            )
        }

        var localError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(parametersCopy as CFDictionary, &localError) else {
            if let err = localError {
                if let errorPtr = error {
                    errorPtr.pointee = err
                } else {
                    debugLogger("Failed to create random key: \(err.takeRetainedValue())")
                }
            } else if let errorPtr = error {
                errorPtr.pointee = makeCFError(status: errSecParam)
            }
            return nil
        }
        if isPermanent {
            var exportError: Unmanaged<CFError>?
            guard let extData = SecKeyCopyExternalRepresentation(key, &exportError) as? Data else {
                if let err = exportError {
                    if let errorPtr = error {
                        errorPtr.pointee = err
                    } else {
                        debugLogger("Failed to export random key representation: \(err.takeRetainedValue())")
                    }
                } else {
                    debugLogger("Failed to export random key representation")
                    if let errorPtr = error {
                        errorPtr.pointee = makeCFError(status: errSecBadReq)
                    }
                }
                return nil
            }
            var keychainDict = [String: Any]()
            keychainDict[kSecClass as String] = kSecClassKey
            keychainDict[kSecAttrKeyType as String] = parameters[kSecAttrKeyType as String]
            keychainDict[kSecAttrKeyClass as String] =
                rawPrivateKeyAttrs[kSecAttrKeyClass as String]
                ?? parameters[kSecAttrKeyClass as String]
                ?? kSecAttrKeyClassPrivate
            keychainDict[kSecAttrIsPermanent as String] = true
            copyPersistedKeyAttributes(from: parameters, subAttrs: rawPrivateKeyAttrs, into: &keychainDict)
            mergeGeneratedKeyMetadata(from: key, into: &keychainDict)
            keychainDict["type"] = keychainDict[kSecAttrKeyType as String]
            keychainDict["kcls"] = keychainDict[kSecAttrKeyClass as String]
            keychainDict[kSecValueData as String] = extData
            if isSecureEnclave {
                keychainDict[PlayKeychainDB.internalTokenIDColumn] = kSecAttrTokenIDSecureEnclave as String
            }
            let (insertStatus, _) = playChainDB.insertWithStatus(keychainDict as NSDictionary)
            guard insertStatus == errSecSuccess else {
                debugLogger("Failed to write keychain file (status: \(insertStatus))")
                if let errorPtr = error {
                    errorPtr.pointee = makeCFError(status: insertStatus)
                }
                return nil
            }
        }
        if isSecureEnclave {
            PTPlayChainSecureEnclaveRegistry.markSecureEnclaveKey(key)
        }
        return Unmanaged.passRetained(key)
    }

    // swiftlint:disable:next function_body_length
    @objc static public func keyGeneratePair(_ parameters: NSDictionary,
                                             publicKey: UnsafeMutablePointer<Unmanaged<SecKey>?>?,
                                             privateKey: UnsafeMutablePointer<Unmanaged<SecKey>?>?) -> OSStatus {
        // Same as above but we need to disable kSecAttrIsPermanent for both the public and private key.
        let isSecureEnclave = PTPlayChainSecureEnclaveRegistry.parametersRequestSecureEnclave(parameters)
        var isPermanent = flag(parameters, kSecAttrIsPermanent)
        let rawPrivateKeyAttrs = parameters[kSecPrivateKeyAttrs as String] as? [String: Any] ?? [:]
        if flag(rawPrivateKeyAttrs as NSDictionary, kSecAttrIsPermanent) {
            isPermanent = true
        }
        let rawPublicKeyAttrs = parameters[kSecPublicKeyAttrs as String] as? [String: Any] ?? [:]
        if flag(rawPublicKeyAttrs as NSDictionary, kSecAttrIsPermanent) {
            isPermanent = true
        }
        let privateKeyAttrs = sanitizedKeySubAttrs(rawPrivateKeyAttrs, forceNonPermanent: true)
        let publicKeyAttrs = sanitizedKeySubAttrs(rawPublicKeyAttrs, forceNonPermanent: true)

        var parametersCopy = parameters as? [String: Any] ?? [:]
        parametersCopy.removeValue(forKey: kSecAttrIsPermanent as String)
        parametersCopy.removeValue(forKey: kSecAttrTokenID as String)
        parametersCopy.removeValue(forKey: kSecAttrAccessControl as String)
        parametersCopy[kSecPrivateKeyAttrs as String] = privateKeyAttrs
        parametersCopy[kSecPublicKeyAttrs as String] = publicKeyAttrs
        var newPublicKey: SecKey?
        var newPrivateKey: SecKey?
        let genStatus = SecKeyGeneratePair(parametersCopy as CFDictionary, &newPublicKey, &newPrivateKey)
        guard genStatus == errSecSuccess else {
            debugLogger("Failed to generate key pair (status: \(genStatus)).")
            return genStatus
        }
        if isPermanent {
            guard let publicKeyRef = newPublicKey,
                  let privateKeyRef = newPrivateKey,
                  let pubData = SecKeyCopyExternalRepresentation(publicKeyRef, nil) as? Data,
                  let privData = SecKeyCopyExternalRepresentation(privateKeyRef, nil) as? Data else {
                return errSecBadReq
            }
            var publicKeyDict = [String: Any]()
            publicKeyDict[kSecClass as String] = kSecClassKey
            publicKeyDict[kSecAttrKeyType as String] = parameters[kSecAttrKeyType as String]
            publicKeyDict[kSecAttrKeyClass as String] = kSecAttrKeyClassPublic
            publicKeyDict[kSecAttrIsPermanent as String] = true
            copyPersistedKeyAttributes(from: parameters, subAttrs: rawPublicKeyAttrs, into: &publicKeyDict)
            mergeGeneratedKeyMetadata(from: publicKeyRef, into: &publicKeyDict)
            publicKeyDict["type"] = publicKeyDict[kSecAttrKeyType as String]
            publicKeyDict["kcls"] = kSecAttrKeyClassPublic
            publicKeyDict[kSecValueData as String] = pubData
            let (pubStatus, _) = playChainDB.insertWithStatus(publicKeyDict as NSDictionary)
            guard pubStatus == errSecSuccess else {
                debugLogger("Failed to write public key to keychain db (status: \(pubStatus))")
                return pubStatus
            }
            var privateKeyDict = [String: Any]()
            privateKeyDict[kSecClass as String] = kSecClassKey
            privateKeyDict[kSecAttrKeyType as String] = parameters[kSecAttrKeyType as String]
            privateKeyDict[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
            privateKeyDict[kSecAttrIsPermanent as String] = true
            copyPersistedKeyAttributes(from: parameters, subAttrs: rawPrivateKeyAttrs, into: &privateKeyDict)
            mergeGeneratedKeyMetadata(from: privateKeyRef, into: &privateKeyDict)
            privateKeyDict["type"] = privateKeyDict[kSecAttrKeyType as String]
            privateKeyDict["kcls"] = kSecAttrKeyClassPrivate
            privateKeyDict[kSecValueData as String] = privData
            if isSecureEnclave {
                privateKeyDict[PlayKeychainDB.internalTokenIDColumn] = kSecAttrTokenIDSecureEnclave as String
            }
            let (privStatus, _) = playChainDB.insertWithStatus(privateKeyDict as NSDictionary)
            guard privStatus == errSecSuccess else {
                debugLogger("Failed to write private key to keychain db (status: \(privStatus))")
                return privStatus
            }
        }
        if isSecureEnclave, let newPrivateKey {
            PTPlayChainSecureEnclaveRegistry.markSecureEnclaveKey(newPrivateKey)
        }
        if let newPublicKey = newPublicKey {
            publicKey?.pointee = Unmanaged.passRetained(newPublicKey)
        }
        if let newPrivateKey = newPrivateKey {
            privateKey?.pointee = Unmanaged.passRetained(newPrivateKey)
        }
        return errSecSuccess
    }
}

extension PlayKeychain {
    private static func makeSecKey(
        fromData vData: Data,
        attributes: NSDictionary,
        defaultKeyClass: CFString = kSecAttrKeyClassPublic
    ) -> SecKey? {
        var keyAttrs: [CFString: Any] = [
            kSecAttrKeyType: (attributes[kSecAttrKeyType] ?? attributes["type"]) ?? kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: (attributes[kSecAttrKeyClass] ?? attributes["kcls"]) ?? defaultKeyClass
        ]
        if let keySize = attributes[kSecAttrKeySizeInBits] {
            keyAttrs[kSecAttrKeySizeInBits] = keySize
        }
        return SecKeyCreateWithData(vData as CFData, keyAttrs as CFDictionary, nil)
    }

    private static func makeSecKey(from keychainDict: NSDictionary) -> SecKey? {
        let rawData: Data?
        if let vData = keychainDict[kSecValueData] as? Data {
            rawData = vData
        } else if let pRef = keychainDict[kSecValuePersistentRef] as? Data,
                  !PTPlayChainPersistentRef.isPersistentRef(pRef) {
            rawData = pRef
        } else {
            rawData = nil
        }
        guard let vData = rawData,
              let secKey = makeSecKey(fromData: vData, attributes: keychainDict) else {
            return nil
        }
        if isSecureEnclavePrivateKeyItem(keychainDict) {
            PTPlayChainSecureEnclaveRegistry.markSecureEnclaveKey(secKey)
        }
        return secKey
    }

    private static func makeSecCertificate(from dict: NSDictionary) -> SecCertificate? {
        guard let data = dict[kSecValueData] as? Data else {
            return nil
        }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    private static func makeSecIdentity(from dict: NSDictionary) -> SecIdentity? {
        guard let cert = makeSecCertificate(from: dict) else {
            return nil
        }
        if let privData = dict[PlayKeychainDB.internalPrivateKeyColumn] as? Data {
            if let privKey = makeSecKey(
                fromData: privData,
                attributes: dict,
                defaultKeyClass: kSecAttrKeyClassPrivate
            ), let identity = SecIdentityCreate(nil, cert, privKey) {
                return identity
            }
            if (dict[kSecAttrKeyType] ?? dict["type"]) == nil {
                var ecAttrs: [CFString: Any] = [
                    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeyClass: kSecAttrKeyClassPrivate
                ]
                if let keySize = dict[kSecAttrKeySizeInBits] {
                    ecAttrs[kSecAttrKeySizeInBits] = keySize
                }
                if let ecKey = SecKeyCreateWithData(privData as CFData, ecAttrs as CFDictionary, nil),
                   let identity = SecIdentityCreate(nil, cert, ecKey) {
                    return identity
                }
            }
        }
        var keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let appLabel = dict[kSecAttrApplicationLabel] ?? dict[kSecAttrPublicKeyHash] {
            keyQuery[kSecAttrApplicationLabel as String] = appLabel
        }
        if let agrp = dict[kSecAttrAccessGroup] {
            keyQuery[kSecAttrAccessGroup as String] = agrp
        }
        if keyQuery[kSecAttrApplicationLabel as String] != nil,
           let matchedKey = playChainDB.query(keyQuery as NSDictionary)?.first,
           let privKey = makeSecKey(from: matchedKey),
           let identity = SecIdentityCreate(nil, cert, privKey) {
            return identity
        }
        return nil
    }

    private static func materializeReference(for item: NSDictionary, queryClassType: String) -> CFTypeRef? {
        let effectiveClass = (item[kSecClass] as? String) ?? queryClassType
        if effectiveClass == (kSecClassKey as String) {
            return makeSecKey(from: item)
        }
        if effectiveClass == (kSecClassCertificate as String) {
            return makeSecCertificate(from: item)
        }
        if effectiveClass == (kSecClassIdentity as String) {
            return makeSecIdentity(from: item) ?? (item[kSecValueRef] as CFTypeRef?)
        }
        if let val = item[kSecValueRef] ?? item[kSecValuePersistentRef] ?? item[kSecValueData] {
            return val as CFTypeRef
        }
        return nil
    }

    // SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result)
    @objc static public func copyMatching(_ query: NSDictionary,
                                          result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        guard let keychainDicts = playChainDB.query(query),
              let keychainDict = keychainDicts.first else {
            debugLogger("Keychain item not found in db")
            return errSecItemNotFound
        }

        let wantsAttributes = flag(query, kSecReturnAttributes)
        let wantsData = flag(query, kSecReturnData)
        let wantsRef = flag(query, kSecReturnRef)
        let wantsPersistentRef = flag(query, kSecReturnPersistentRef)

        let matchLimit = query[kSecMatchLimit]
        let wantsMultiple = (matchLimit as? String == kSecMatchLimitAll as String) ||
            ((matchLimit as? NSNumber).map { $0.intValue > 1 } ?? false)
        if wantsMultiple {
            return copyAllMatches(keychainDicts, query: query, result: result)
        }

        // A query without return flags is an existence check.
        if !wantsAttributes && !wantsData && !wantsRef && !wantsPersistentRef {
            return errSecSuccess
        }

        guard let result else {
            return errSecSuccess
        }

        return buildSingleResult(query, keychainDict: keychainDict, result: result)
    }

    private static func copyAllMatches(_ keychainDicts: [NSMutableDictionary], query: NSDictionary,
                                       result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        let wantsData = flag(query, kSecReturnData)
        let wantsAttributes = flag(query, kSecReturnAttributes)
        let wantsRef = flag(query, kSecReturnRef)
        let wantsPersistentRef = flag(query, kSecReturnPersistentRef)

        if !wantsAttributes && !wantsData && !wantsRef && !wantsPersistentRef {
            return errSecSuccess
        }
        guard let result else {
            return errSecSuccess
        }

        let classType = query[kSecClass as String] as? String ?? ""
        if wantsData && !wantsAttributes && !wantsRef && !wantsPersistentRef {
            let values = keychainDicts.compactMap { item -> Any? in
                guard !isSecureEnclavePrivateKeyItem(item) else { return nil }
                return item[kSecValueData]
            }
            guard values.count == keychainDicts.count else {
                return errSecItemNotFound
            }
            result.pointee = Unmanaged.passRetained(values as CFTypeRef)
            return errSecSuccess
        }

        if wantsPersistentRef && !wantsAttributes && !wantsData && !wantsRef {
            let pRefs = keychainDicts.compactMap { $0[kSecValuePersistentRef] }
            guard pRefs.count == keychainDicts.count else {
                return errSecItemNotFound
            }
            result.pointee = Unmanaged.passRetained(pRefs as CFTypeRef)
            return errSecSuccess
        }

        if wantsRef && !wantsAttributes && !wantsData && !wantsPersistentRef {
            var refs: [Any] = []
            refs.reserveCapacity(keychainDicts.count)
            for item in keychainDicts {
                guard let refVal = materializeReference(for: item, queryClassType: classType) else {
                    return errSecItemNotFound
                }
                refs.append(refVal)
            }
            result.pointee = Unmanaged.passRetained(refs as CFTypeRef)
            return errSecSuccess
        }

        let dicts: [NSMutableDictionary] = keychainDicts.map { item in
            makeResultDictionary(
                from: item,
                queryClassType: classType,
                wantsAttributes: wantsAttributes,
                wantsData: wantsData,
                wantsRef: wantsRef,
                wantsPersistentRef: wantsPersistentRef
            )
        }
        if !wantsAttributes && dicts.contains(where: { $0.count == 0 }) {
            return errSecItemNotFound
        }
        result.pointee = Unmanaged.passRetained(dicts as CFTypeRef)
        return errSecSuccess
    }

    private static func copyReference(_ keychainDict: NSMutableDictionary,
                                      classType: String,
                                      result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> OSStatus {
        guard let ref = materializeReference(for: keychainDict, queryClassType: classType) else {
            debugLogger("Failed to materialize keychain item reference")
            return errSecItemNotFound
        }
        debugLogger("Read keychain item from db")
        result.pointee = Unmanaged.passRetained(ref)
        return errSecSuccess
    }
}
