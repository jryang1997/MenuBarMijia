import Foundation
public typealias CFDictionary = [String: Any]
public typealias CFTypeRef = Any
public typealias OSStatus = Int32
public let errSecSuccess: OSStatus = 0
public let errSecItemNotFound: OSStatus = -25300
public let kSecClass = "class", kSecClassGenericPassword = "genp", kSecAttrService = "svce", kSecAttrAccount = "acct",
  kSecReturnData = "r_Data", kSecMatchLimit = "m_Limit", kSecMatchLimitOne = "m_LimitOne", kSecValueData = "v_Data",
  kSecAttrAccessible = "pdmn", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "cku"
nonisolated(unsafe) var store: [String: Data] = [:]
let lock = NSLock()
func key(_ q: [String: Any]) -> String { "\(q[kSecAttrService] ?? "")|\(q[kSecAttrAccount] ?? "")" }
public func SecItemAdd(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { lock.lock(); defer { lock.unlock() }; store[key(q)] = q[kSecValueData] as? Data; return errSecSuccess }
public func SecItemCopyMatching(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { lock.lock(); defer { lock.unlock() }; guard let d = store[key(q)] else { return errSecItemNotFound }; r?.pointee = d; return errSecSuccess }
public func SecItemDelete(_ q: CFDictionary) -> OSStatus { lock.lock(); defer { lock.unlock() }; store[key(q)] = nil; return errSecSuccess }
public func SecItemUpdate(_ q: CFDictionary, _ a: CFDictionary) -> OSStatus { lock.lock(); defer { lock.unlock() }; store[key(q)] = a[kSecValueData] as? Data; return errSecSuccess }
