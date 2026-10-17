import Foundation
public struct OSLogPrivacy: Sendable { public static let `public` = OSLogPrivacy(); public static let `private` = OSLogPrivacy(); public static let auto = OSLogPrivacy(); public static func `private`(mask: Int) -> OSLogPrivacy { .init() } }
public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
  public var text: String
  public init(stringLiteral v: String) { text = v }
  public init(stringInterpolation i: Interp) { text = i.s }
  public struct Interp: StringInterpolationProtocol {
    var s = ""
    public init(literalCapacity: Int, interpolationCount: Int) {}
    public mutating func appendLiteral(_ l: String) { s += l }
    public mutating func appendInterpolation<T>(_ v: T, privacy: OSLogPrivacy = .auto) { s += "\(v)" }
  }
}
public struct Logger: Sendable {
  public init(subsystem: String, category: String) {}
  public init() {}
  public func debug(_ m: OSLogMessage) {}
  public func info(_ m: OSLogMessage) {}
  public func notice(_ m: OSLogMessage) {}
  public func warning(_ m: OSLogMessage) {}
  public func error(_ m: OSLogMessage) {}
  public func fault(_ m: OSLogMessage) {}
  public func log(_ m: OSLogMessage) {}
}
